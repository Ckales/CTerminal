//! CTerminal 核心：终端引擎、各类连接、配置与凭据。零 UI 依赖。

#[macro_use]
pub mod i18n;
pub mod config;
pub mod connect;
pub mod frame;
pub mod highlight;
pub mod input;
pub mod local;
pub mod log;
pub mod paths;
pub mod schemes;
pub mod secrets;
pub mod serial;
pub mod session;
pub mod sftp;
pub mod shells;
pub mod ssh;
pub mod ssh_config;
pub mod telnet;
pub mod update;
pub mod zmodem;
