//! Telnet：TCP + 最小 IAC 协商（ECHO / SGA / TTYPE / NAWS）

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::config::TelnetOptions;
use crate::session::{Output, Transport, WinSize};
use crate::i18n::tr;

const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const SE: u8 = 240;
const OPT_ECHO: u8 = 1;
const OPT_SGA: u8 = 3;
const OPT_TTYPE: u8 = 24;
const OPT_NAWS: u8 = 31;

#[derive(Default)]
enum State {
    #[default]
    Data,
    Iac,
    Command(u8),
    Sub,
    SubIac,
}

/// 协议状态机：输入网络字节，分离出终端数据和需要回写的协商应答
#[derive(Default)]
pub struct Negotiator {
    state: State,
    sub: Vec<u8>,
    pub naws_enabled: bool,
}

pub struct Parsed {
    pub data: Vec<u8>,
    pub replies: Vec<u8>,
}

impl Negotiator {
    pub fn feed(&mut self, input: &[u8], size: WinSize) -> Parsed {
        let mut data = Vec::with_capacity(input.len());
        let mut replies = Vec::new();
        for &byte in input {
            match self.state {
                State::Data => {
                    if byte == IAC {
                        self.state = State::Iac;
                    } else {
                        data.push(byte);
                    }
                }
                State::Iac => {
                    self.state = State::Data;
                    match byte {
                        IAC => data.push(IAC),
                        DO | DONT | WILL | WONT => self.state = State::Command(byte),
                        SB => {
                            self.sub.clear();
                            self.state = State::Sub;
                        }
                        _ => {}
                    }
                }
                State::Command(command) => {
                    self.state = State::Data;
                    self.answer(command, byte, size, &mut replies);
                }
                State::Sub => {
                    if byte == IAC {
                        self.state = State::SubIac;
                    } else {
                        self.sub.push(byte);
                    }
                }
                State::SubIac => {
                    if byte == SE {
                        self.state = State::Data;
                        // TTYPE SEND → IS xterm-256color
                        if self.sub.first() == Some(&OPT_TTYPE) && self.sub.get(1) == Some(&1) {
                            replies.extend_from_slice(&[IAC, SB, OPT_TTYPE, 0]);
                            replies.extend_from_slice(b"xterm-256color");
                            replies.extend_from_slice(&[IAC, SE]);
                        }
                    } else {
                        self.sub.push(byte);
                        self.state = State::Sub;
                    }
                }
            }
        }
        Parsed { data, replies }
    }

    fn answer(&mut self, command: u8, option: u8, size: WinSize, replies: &mut Vec<u8>) {
        match (command, option) {
            (DO, OPT_TTYPE) => replies.extend_from_slice(&[IAC, WILL, OPT_TTYPE]),
            (DO, OPT_NAWS) => {
                replies.extend_from_slice(&[IAC, WILL, OPT_NAWS]);
                self.naws_enabled = true;
                replies.extend_from_slice(&naws(size));
            }
            (DO, OPT_SGA) => replies.extend_from_slice(&[IAC, WILL, OPT_SGA]),
            (DO, other) => replies.extend_from_slice(&[IAC, WONT, other]),
            (WILL, OPT_ECHO) | (WILL, OPT_SGA) => replies.extend_from_slice(&[IAC, DO, option]),
            (WILL, other) => replies.extend_from_slice(&[IAC, DONT, other]),
            // DONT / WONT：对方拒绝，不用回应
            _ => {}
        }
    }
}

pub fn naws(size: WinSize) -> Vec<u8> {
    let mut out = vec![IAC, SB, OPT_NAWS];
    for value in [size.cols, size.rows] {
        for byte in value.to_be_bytes() {
            out.push(byte);
            if byte == IAC {
                out.push(IAC);
            }
        }
    }
    out.extend_from_slice(&[IAC, SE]);
    out
}

/// 发送：0xFF 转义；CR 后补 NUL（NVT 规定裸 CR 必须跟 NUL 或 LF）
pub fn escape_output(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    for &byte in data {
        out.push(byte);
        if byte == IAC {
            out.push(IAC);
        }
        if byte == b'\r' {
            out.push(0);
        }
    }
    out
}

pub struct TelnetTransport {
    stream: TcpStream,
    negotiator: Arc<Mutex<Negotiator>>,
    size: Arc<Mutex<WinSize>>,
}

pub fn connect(options: &TelnetOptions, size: WinSize, tx: Sender<Output>) -> io::Result<TelnetTransport> {
    let address = (options.host.as_str(), options.port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::other(tr("无法解析主机名")))?;
    let stream = TcpStream::connect_timeout(&address, Duration::from_secs(15))?;
    stream.set_nodelay(true)?;
    let negotiator = Arc::new(Mutex::new(Negotiator::default()));

    let mut reader = stream.try_clone()?;
    let mut replier = stream.try_clone()?;
    let reader_negotiator = negotiator.clone();
    let shared_size = Arc::new(Mutex::new(size));
    let size_for_reader = shared_size.clone();
    thread::Builder::new().name("cterm-telnet".into()).spawn(move || {
        let mut buffer = vec![0u8; 16 * 1024];
        let reason = loop {
            match reader.read(&mut buffer) {
                Ok(0) => break tr("连接已被远端关闭"),
                Err(err) => break trf!("连接中断：{err}", err = err),
                Ok(count) => {
                    let current = *size_for_reader.lock().unwrap();
                    let parsed = reader_negotiator.lock().unwrap().feed(&buffer[..count], current);
                    if !parsed.replies.is_empty() {
                        let _ = replier.write_all(&parsed.replies);
                    }
                    if !parsed.data.is_empty() && tx.send(Output::Data(parsed.data)).is_err() {
                        return;
                    }
                }
            }
        };
        let _ = tx.send(Output::Closed(reason));
    })?;
    Ok(TelnetTransport { stream, negotiator, size: shared_size })
}

impl Transport for TelnetTransport {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.stream.write_all(&escape_output(data))
    }

    fn resize(&mut self, size: WinSize) {
        *self.size.lock().unwrap() = size;
        if self.negotiator.lock().unwrap().naws_enabled {
            let _ = self.stream.write_all(&naws(size));
        }
    }

    fn close(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIZE: WinSize = WinSize { cols: 80, rows: 24, cell_width: 8, cell_height: 16 };

    #[test]
    fn negotiation_and_data_split() {
        let mut negotiator = Negotiator::default();
        let input = [b'h', IAC, DO, OPT_NAWS, b'i', IAC, IAC, IAC, WILL, OPT_ECHO, IAC, DO, 99];
        let parsed = negotiator.feed(&input, SIZE);
        assert_eq!(parsed.data, [b'h', b'i', IAC]);
        let mut expected = vec![IAC, WILL, OPT_NAWS];
        expected.extend(naws(SIZE));
        expected.extend([IAC, DO, OPT_ECHO, IAC, WONT, 99]);
        assert_eq!(parsed.replies, expected);
        assert!(negotiator.naws_enabled);
    }

    #[test]
    fn ttype_subnegotiation_split_across_reads() {
        let mut negotiator = Negotiator::default();
        let first = negotiator.feed(&[IAC, SB, OPT_TTYPE], SIZE);
        assert!(first.replies.is_empty());
        let second = negotiator.feed(&[1, IAC, SE, b'x'], SIZE);
        assert_eq!(second.data, b"x");
        assert!(second.replies.windows(14).any(|window| window == b"xterm-256color"));
    }

    #[test]
    fn output_escaping() {
        assert_eq!(escape_output(&[b'a', IAC, b'\r']), [b'a', IAC, IAC, b'\r', 0]);
        assert_eq!(naws(WinSize { cols: 255, rows: 1, ..SIZE }), [IAC, SB, OPT_NAWS, 0, 255, 255, 0, 1, IAC, SE]);
    }
}
