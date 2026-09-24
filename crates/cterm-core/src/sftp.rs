//! SFTP：在已认证的 SSH 连接上开 sftp 子系统，供界面的文件面板使用。
//! 所有方法都是阻塞的（内部在共享的 tokio 运行时上执行），由桥接层在工作线程调用。

use std::path::Path;
use std::time::UNIX_EPOCH;

use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::ssh::{SshShared, RUNTIME};
use crate::i18n::tr;

#[derive(Debug, Clone, PartialEq)]
pub struct SftpEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_link: bool,
    pub size: u64,
    /// Unix 秒，未知时为 0
    pub modified: i64,
    /// 权限位（如 0o755），未知时为 0
    pub permissions: u32,
}

pub struct Sftp {
    session: SftpSession,
}

fn fail(action: &str, err: impl std::fmt::Display + Sync) -> String {
    trf!("{action}失败：{err}", action = tr(action), err = err)
}

/// 远端路径拼接（SFTP 路径总是 / 分隔，与本机系统无关）
pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        return format!("{dir}{name}");
    }
    format!("{dir}/{name}")
}

pub fn parent(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".into(),
        Some(index) => trimmed[..index].into(),
    }
}

const CHUNK: usize = 256 * 1024;

impl Sftp {
    pub fn open(shared: &SshShared) -> Result<Sftp, String> {
        RUNTIME.block_on(async {
            let stream = shared.open_subsystem("sftp").await?;
            let session = SftpSession::new(stream).await.map_err(|err| fail("启动 SFTP", err))?;
            Ok(Sftp { session })
        })
    }

    pub fn home(&self) -> Result<String, String> {
        RUNTIME.block_on(self.session.canonicalize(".")).map_err(|err| fail("读取主目录", err))
    }

    /// 目录在前、按名称排序；不含 . 和 ..
    pub fn list(&self, path: &str) -> Result<Vec<SftpEntry>, String> {
        let entries = RUNTIME.block_on(self.session.read_dir(path)).map_err(|err| fail("读取目录", err))?;
        let mut result = Vec::new();
        for entry in entries {
            let name = entry.file_name();
            if name == "." || name == ".." {
                continue;
            }
            let metadata = entry.metadata();
            let file_type = entry.file_type();
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs() as i64)
                .unwrap_or(0);
            result.push(SftpEntry {
                name,
                is_dir: file_type.is_dir(),
                is_link: file_type.is_symlink(),
                size: metadata.len(),
                modified,
                permissions: metadata.permissions.unwrap_or(0) & 0o7777,
            });
        }
        result.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        Ok(result)
    }

    pub fn mkdir(&self, path: &str) -> Result<(), String> {
        RUNTIME.block_on(self.session.create_dir(path)).map_err(|err| fail("新建文件夹", err))
    }

    pub fn rename(&self, from: &str, to: &str) -> Result<(), String> {
        RUNTIME.block_on(self.session.rename(from, to)).map_err(|err| fail("重命名", err))
    }

    /// 删除文件或整个目录（递归）
    pub fn remove(&self, path: &str, is_dir: bool) -> Result<(), String> {
        if !is_dir {
            return RUNTIME.block_on(self.session.remove_file(path)).map_err(|err| fail("删除", err));
        }
        for entry in self.list(path)? {
            let child = join(path, &entry.name);
            // 符号链接当文件删，不跟进去
            self.remove(&child, entry.is_dir && !entry.is_link)?;
        }
        RUNTIME.block_on(self.session.remove_dir(path)).map_err(|err| fail("删除", err))
    }

    /// 下载单个文件；progress(已完成, 总大小)
    pub fn download(&self, remote: &str, local: &Path, progress: &dyn Fn(u64, u64)) -> Result<(), String> {
        RUNTIME.block_on(async {
            let total = self.session.metadata(remote).await.map(|metadata| metadata.len()).unwrap_or(0);
            let mut source = self.session.open(remote).await.map_err(|err| fail("打开远端文件", err))?;
            // 先写临时文件，完成后改名，避免中断时留下看似完整的半截文件
            let partial = std::path::PathBuf::from(format!("{}.part", local.display()));
            let mut target = tokio::fs::File::create(&partial).await.map_err(|err| fail("创建本地文件", err))?;
            let mut buffer = vec![0u8; CHUNK];
            let mut done = 0u64;
            loop {
                let count = source.read(&mut buffer).await.map_err(|err| fail("下载", err))?;
                if count == 0 {
                    break;
                }
                target.write_all(&buffer[..count]).await.map_err(|err| fail("写入本地文件", err))?;
                done += count as u64;
                progress(done, total);
            }
            target.flush().await.map_err(|err| fail("写入本地文件", err))?;
            drop(target);
            tokio::fs::rename(&partial, local).await.map_err(|err| fail("保存文件", err))?;
            Ok(())
        })
    }

    /// 上传文件或目录（目录递归）；progress(已完成字节, 总字节)
    pub fn upload(&self, local: &Path, remote: &str, progress: &dyn Fn(u64, u64)) -> Result<(), String> {
        let total = local_size(local);
        let mut done = 0u64;
        self.upload_inner(local, remote, &mut done, total, progress)
    }

    fn upload_inner(&self, local: &Path, remote: &str, done: &mut u64, total: u64, progress: &dyn Fn(u64, u64)) -> Result<(), String> {
        if local.is_dir() {
            let exists = RUNTIME.block_on(self.session.try_exists(remote)).unwrap_or(false);
            if !exists {
                self.mkdir(remote)?;
            }
            let entries = std::fs::read_dir(local).map_err(|err| fail("读取本地目录", err))?;
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                self.upload_inner(&entry.path(), &join(remote, &name), done, total, progress)?;
            }
            return Ok(());
        }
        RUNTIME.block_on(async {
            let mut source = tokio::fs::File::open(local).await.map_err(|err| fail("打开本地文件", err))?;
            let flags = OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE;
            let mut target = self.session.open_with_flags(remote, flags).await.map_err(|err| fail("创建远端文件", err))?;
            let mut buffer = vec![0u8; CHUNK];
            loop {
                let count = source.read(&mut buffer).await.map_err(|err| fail("读取本地文件", err))?;
                if count == 0 {
                    break;
                }
                target.write_all(&buffer[..count]).await.map_err(|err| fail("上传", err))?;
                *done += count as u64;
                progress(*done, total);
            }
            target.shutdown().await.map_err(|err| fail("上传", err))?;
            Ok(())
        })
    }

    pub fn close(&self) {
        let _ = RUNTIME.block_on(self.session.close());
    }
}

fn local_size(path: &Path) -> u64 {
    if path.is_dir() {
        let Ok(entries) = std::fs::read_dir(path) else { return 0 };
        return entries.flatten().map(|entry| local_size(&entry.path())).sum();
    }
    path.metadata().map(|metadata| metadata.len()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_paths() {
        assert_eq!(join("/home/me", "a.txt"), "/home/me/a.txt");
        assert_eq!(join("/", "etc"), "/etc");
        assert_eq!(parent("/home/me/a.txt"), "/home/me");
        assert_eq!(parent("/home"), "/");
        assert_eq!(parent("/"), "/");
        assert_eq!(parent("/home/me/"), "/home");
    }
}
