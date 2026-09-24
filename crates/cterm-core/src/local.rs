//! 本地 shell：portable-pty（Unix pty / Windows ConPTY）

use std::io::{self, Read, Write};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};

use crate::session::{Output, Transport, WinSize};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LocalOptions {
    pub command: String,
    pub args: Vec<String>,
    /// 空 = 用户主目录
    pub cwd: String,
    pub env: Vec<(String, String)>,
}

pub struct LocalTransport {
    master: Arc<Mutex<Option<Box<dyn MasterPty + Send>>>>,
    writer: Box<dyn Write + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    pid: Option<u32>,
}

fn pty_size(size: WinSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: size.cols.saturating_mul(size.cell_width),
        pixel_height: size.rows.saturating_mul(size.cell_height),
    }
}

pub fn spawn(options: &LocalOptions, size: WinSize, tx: Sender<Output>) -> io::Result<LocalTransport> {
    let system = native_pty_system();
    let pair = system.openpty(pty_size(size)).map_err(io::Error::other)?;

    let mut command = CommandBuilder::new(&options.command);
    command.args(&options.args);
    let cwd = if options.cwd.is_empty() { crate::paths::home_dir() } else { options.cwd.clone().into() };
    if cwd.is_dir() {
        command.cwd(cwd);
    }
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command.env("TERM_PROGRAM", "CTerminal");
    // 从 Finder / 程序坞启动的 App 没有 LANG，zsh 会把中文显示成 <0080> 之类
    if std::env::var_os("LANG").is_none() {
        command.env("LANG", "en_US.UTF-8");
    }
    for (key, value) in &options.env {
        command.env(key, value);
    }

    let mut child = pair.slave.spawn_command(command).map_err(io::Error::other)?;
    // Unix 下必须关掉父进程这边的 slave，子进程退出后 reader 才能读到 EOF
    drop(pair.slave);

    let pid = child.process_id();
    let killer = child.clone_killer();
    let mut reader = pair.master.try_clone_reader().map_err(io::Error::other)?;
    let writer = pair.master.take_writer().map_err(io::Error::other)?;
    let master = Arc::new(Mutex::new(Some(pair.master)));
    let exit_status: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    let waiter_master = master.clone();
    let waiter_status = exit_status.clone();
    let waiter_tx = tx.clone();
    thread::Builder::new().name("cterm-pty-wait".into()).spawn(move || {
        let message = match child.wait() {
            Ok(status) if status.success() => String::new(),
            Ok(status) => trf!("进程已退出，退出码 {code}", code = status.exit_code()),
            Err(err) => trf!("进程异常结束：{err}", err = err),
        };
        *waiter_status.lock().unwrap() = Some(message.clone());
        // ConPTY 在子进程退出后不会自己关管道，要关掉伪控制台 reader 才会结束
        if cfg!(windows) {
            waiter_master.lock().unwrap().take();
            let _ = waiter_tx.send(Output::Closed(message));
        }
    })?;

    thread::Builder::new().name("cterm-pty-read".into()).spawn(move || {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => {
                    if tx.send(Output::Data(buffer[..count].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
        if cfg!(windows) {
            return;
        }
        // Unix：EOF 之后子进程马上就会被回收，稍等拿到退出码
        let mut message = None;
        for _ in 0..50 {
            message = exit_status.lock().unwrap().clone();
            if message.is_some() {
                break;
            }
            thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = tx.send(Output::Closed(message.unwrap_or_default()));
    })?;

    Ok(LocalTransport { master, writer, killer, pid })
}

#[cfg(target_os = "macos")]
pub fn process_cwd(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let written = unsafe {
        libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size)
    };
    if written != size {
        return None;
    }
    let path = unsafe { std::ffi::CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) };
    Some(path.to_string_lossy().into_owned())
}

#[cfg(all(unix, not(target_os = "macos")))]
pub fn process_cwd(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok().map(|path| path.display().to_string())
}

/// Windows 要读目标进程 PEB 才能拿到 cwd，暂不支持，新标签页回落到用户目录
#[cfg(windows)]
pub fn process_cwd(_pid: u32) -> Option<String> {
    None
}

impl Transport for LocalTransport {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.writer.write_all(data)?;
        self.writer.flush()
    }

    fn resize(&mut self, size: WinSize) {
        if let Some(master) = self.master.lock().unwrap().as_ref() {
            let _ = master.resize(pty_size(size));
        }
    }

    fn close(&mut self) {
        let _ = self.killer.kill();
    }

    fn pid(&self) -> Option<u32> {
        self.pid
    }
}
