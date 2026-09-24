//! 按 profile 类型建立会话

use std::sync::Arc;

use crate::config::{self, Config, Profile, ProfileKind};
use crate::session::{EventSink, Output, Session, TermOptions, WinSize};
use crate::{local, log, schemes, serial, ssh, telnet};

pub fn term_options(config: &Config) -> TermOptions {
    TermOptions {
        scrollback: config.terminal.scrollback_lines as usize,
        cursor: config.terminal.cursor.clone(),
        word_separators: config.terminal.word_separators.clone(),
        scroll_on_input: config.terminal.scroll_on_input,
        palette: schemes::palette_for(config),
        bold_is_bright: config.terminal.bold_is_bright,
    }
}

/// 打开会话。连接失败不返回错误，而是把原因显示在终端里并结束会话。
pub fn open(profile: &Profile, config: &Config, size: WinSize, sink: EventSink) -> Arc<Session> {
    let (session, tx) = Session::new(term_options(config), size, sink);
    let fail = |message: String| {
        log::warn(&format!("{} 会话打开失败：{message}", profile.kind.type_name()));
        let _ = tx.send(Output::Data(format!("\x1b[31m{message}\x1b[0m\r\n").into_bytes()));
        let _ = tx.send(Output::Closed(message));
    };
    match &profile.kind {
        ProfileKind::Local(options) => {
            log::info(&format!("启动本地 shell {}", options.command));
            match local::spawn(options, size, tx.clone()) {
                Ok(transport) => session.attach(Box::new(transport)),
                Err(err) => fail(trf!("无法启动 {command}：{err}", command = options.command, err = err)),
            }
        }
        ProfileKind::Ssh(_) => {
            let profiles = config::all_profiles(config);
            match ssh::connect(profile, &profiles, &config.ssh, size, tx.clone()) {
                Ok(transport) => session.attach(Box::new(transport)),
                Err(err) => fail(err),
            }
        }
        ProfileKind::Telnet(options) => {
            let connecting = trf!("正在连接 {host}:{port} …", host = options.host, port = options.port);
            let _ = tx.send(Output::Data(format!("\x1b[2m{connecting}\x1b[0m\r\n").into_bytes()));
            log::info(&format!("Telnet 连接 {}:{}", options.host, options.port));
            // 连接放到后台线程，避免 DNS / TCP 超时卡住调用方
            let session_for_connect = session.clone();
            let options = options.clone();
            let tx = tx.clone();
            std::thread::spawn(move || match telnet::connect(&options, size, tx.clone()) {
                Ok(transport) => {
                    log::info(&format!("Telnet {}:{} 已连接", options.host, options.port));
                    session_for_connect.attach(Box::new(transport));
                }
                Err(err) => {
                    log::warn(&format!("Telnet {}:{} 连接失败：{err}", options.host, options.port));
                    let message = trf!("连接 {host}:{port} 失败：{err}", host = options.host, port = options.port, err = err);
                    let _ = tx.send(Output::Data(format!("\x1b[31m{message}\x1b[0m\r\n").into_bytes()));
                    let _ = tx.send(Output::Closed(message));
                }
            });
        }
        ProfileKind::Serial(options) => {
            log::info(&format!("打开串口 {} {}bps", options.port, options.baudrate));
            match serial::open(options, tx.clone()) {
                Ok(transport) => session.attach(Box::new(transport)),
                Err(err) => fail(trf!("无法打开串口 {port}：{err}", port = options.port, err = err)),
            }
        }
    }
    session
}
