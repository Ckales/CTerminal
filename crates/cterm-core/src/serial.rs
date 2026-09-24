//! 串口

use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use serialport::{DataBits, FlowControl, Parity, SerialPort, StopBits};

use crate::config::SerialOptions;
use crate::session::{Output, Transport, WinSize};

/// 可用串口列表（macOS 上同一设备有 tty.* 和 cu.*，都列出来由用户选）
pub fn list_ports() -> Vec<String> {
    match serialport::available_ports() {
        Ok(ports) => ports.into_iter().map(|port| port.port_name).collect(),
        Err(_) => Vec::new(),
    }
}

pub struct SerialTransport {
    port: Box<dyn SerialPort>,
    newline: Vec<u8>,
    local_echo: Option<Sender<Output>>,
    closed: Arc<AtomicBool>,
}

pub fn open(options: &SerialOptions, tx: Sender<Output>) -> io::Result<SerialTransport> {
    let data_bits = match options.databits {
        5 => DataBits::Five,
        6 => DataBits::Six,
        7 => DataBits::Seven,
        _ => DataBits::Eight,
    };
    let stop_bits = if options.stopbits == 2 { StopBits::Two } else { StopBits::One };
    let parity = match options.parity.as_str() {
        "odd" => Parity::Odd,
        "even" => Parity::Even,
        _ => Parity::None,
    };
    let flow = match options.flowcontrol.as_str() {
        "software" => FlowControl::Software,
        "hardware" => FlowControl::Hardware,
        _ => FlowControl::None,
    };
    let port = serialport::new(&options.port, options.baudrate)
        .data_bits(data_bits)
        .stop_bits(stop_bits)
        .parity(parity)
        .flow_control(flow)
        .timeout(Duration::from_millis(200))
        .open()
        .map_err(io::Error::other)?;

    let mut reader = port.try_clone().map_err(io::Error::other)?;
    let reader_tx = tx.clone();
    let closed = Arc::new(AtomicBool::new(false));
    let reader_closed = closed.clone();
    let port_name = options.port.clone();
    thread::Builder::new().name("cterm-serial".into()).spawn(move || {
        let mut buffer = vec![0u8; 4096];
        let reason = loop {
            match reader.read(&mut buffer) {
                Ok(0) => continue,
                Ok(count) => {
                    if reader_tx.send(Output::Data(buffer[..count].to_vec())).is_err() {
                        return;
                    }
                }
                Err(err) if err.kind() == io::ErrorKind::TimedOut => {
                    // 读线程持有克隆的句柄，只能靠标志位退出，端口才会真正释放
                    if reader_closed.load(Ordering::Acquire) {
                        break String::new();
                    }
                }
                Err(err) => break trf!("串口已断开：{err}", err = err),
            }
        };
        crate::log::info(&format!("串口 {port_name} 会话结束：{}", if reason.is_empty() { "正常关闭" } else { &reason }));
        let _ = reader_tx.send(Output::Closed(reason));
    })?;

    let newline = match options.output_newlines.as_str() {
        "lf" => b"\n".to_vec(),
        "crlf" => b"\r\n".to_vec(),
        _ => b"\r".to_vec(),
    };
    let local_echo = if options.local_echo { Some(tx) } else { None };
    Ok(SerialTransport { port, newline, local_echo, closed })
}

pub fn convert_newlines(data: &[u8], newline: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    for &byte in data {
        if byte == b'\r' {
            out.extend_from_slice(newline);
        } else {
            out.push(byte);
        }
    }
    out
}

impl Transport for SerialTransport {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        let converted = convert_newlines(data, &self.newline);
        if let Some(echo) = &self.local_echo {
            let _ = echo.send(Output::Data(convert_newlines(data, b"\r\n")));
        }
        self.port.write_all(&converted)
    }

    fn resize(&mut self, _size: WinSize) {}

    fn close(&mut self) {
        self.closed.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newline_conversion() {
        assert_eq!(convert_newlines(b"ls\r", b"\r\n"), b"ls\r\n");
        assert_eq!(convert_newlines(b"a\rb", b"\n"), b"a\nb");
    }

    #[test]
    fn newline_conversion_leaves_lf_and_repeats_cr() {
        // 只转换 Enter 发出的 CR；LF 原样发送，连续 CR 各自转换
        assert_eq!(convert_newlines(b"a\nb", b"\r\n"), b"a\nb");
        assert_eq!(convert_newlines(b"\r\r", b"\r\n"), b"\r\n\r\n");
        assert_eq!(convert_newlines(b"x\r", b"\r"), b"x\r");
        assert!(convert_newlines(b"", b"\r\n").is_empty());
    }
}
