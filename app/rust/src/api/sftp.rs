//! SFTP 文件面板的桥接

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use cterm_core::sftp::Sftp;

use crate::api::terminal::session_by_id;
use crate::frb_generated::StreamSink;

static CLIENTS: LazyLock<Mutex<HashMap<u32, Arc<Sftp>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_ID: AtomicU32 = AtomicU32::new(1);

fn client(id: u32) -> Result<Arc<Sftp>, String> {
    CLIENTS.lock().unwrap().get(&id).cloned().ok_or_else(|| "SFTP 已断开".to_string())
}

pub struct SftpFileEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_link: bool,
    pub size: i64,
    pub modified: i64,
    pub permissions: u32,
}

/// 传输进度；finished=true 时 error 为空表示成功
pub struct SftpProgress {
    pub done: i64,
    pub total: i64,
    pub finished: bool,
    pub error: String,
}

/// 在终端会话的 SSH 连接上打开 SFTP，返回 SFTP 句柄 id
pub fn sftp_open(term_id: u32) -> Result<u32, String> {
    let session = session_by_id(term_id).ok_or("会话已关闭")?;
    let shared = session.ssh().ok_or("只有 SSH 连接支持 SFTP")?;
    let sftp = Sftp::open(&shared)?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    CLIENTS.lock().unwrap().insert(id, Arc::new(sftp));
    Ok(id)
}

pub fn sftp_home(id: u32) -> Result<String, String> {
    client(id)?.home()
}

pub fn sftp_list(id: u32, path: String) -> Result<Vec<SftpFileEntry>, String> {
    let entries = client(id)?.list(&path)?;
    let mut result = Vec::with_capacity(entries.len());
    for entry in entries {
        result.push(SftpFileEntry {
            name: entry.name,
            is_dir: entry.is_dir,
            is_link: entry.is_link,
            size: entry.size as i64,
            modified: entry.modified,
            permissions: entry.permissions,
        });
    }
    Ok(result)
}

pub fn sftp_mkdir(id: u32, path: String) -> Result<(), String> {
    client(id)?.mkdir(&path)
}

pub fn sftp_rename(id: u32, from: String, to: String) -> Result<(), String> {
    client(id)?.rename(&from, &to)
}

pub fn sftp_remove(id: u32, path: String, is_dir: bool) -> Result<(), String> {
    client(id)?.remove(&path, is_dir)
}

fn report(sink: &StreamSink<SftpProgress>, result: Result<(), String>) {
    let error = result.err().unwrap_or_default();
    let _ = sink.add(SftpProgress { done: 0, total: 0, finished: true, error });
}

pub fn sftp_download(id: u32, remote: String, local: String, sink: StreamSink<SftpProgress>) -> Result<(), String> {
    let sftp = client(id)?;
    let result = sftp.download(&remote, &PathBuf::from(local), &|done, total| {
        let _ = sink.add(SftpProgress { done: done as i64, total: total as i64, finished: false, error: String::new() });
    });
    report(&sink, result);
    Ok(())
}

pub fn sftp_upload(id: u32, local: String, remote: String, sink: StreamSink<SftpProgress>) -> Result<(), String> {
    let sftp = client(id)?;
    let result = sftp.upload(&PathBuf::from(local), &remote, &|done, total| {
        let _ = sink.add(SftpProgress { done: done as i64, total: total as i64, finished: false, error: String::new() });
    });
    report(&sink, result);
    Ok(())
}

pub fn sftp_close(id: u32) {
    let removed = CLIENTS.lock().unwrap().remove(&id);
    if let Some(sftp) = removed {
        sftp.close();
    }
}

/// 下载默认存到“下载”文件夹
#[flutter_rust_bridge::frb(sync)]
pub fn downloads_dir() -> String {
    cterm_core::paths::downloads_dir().display().to_string()
}
