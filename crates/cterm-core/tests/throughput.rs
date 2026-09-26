//! 吞吐：`cat` 大文件的场景。默认忽略，手动跑：cargo test --release --test throughput -- --ignored --nocapture
//! CI 每天跑一次（.github/workflows/throughput.yml）

use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use cterm_core::frame::Palette;
use cterm_core::session::{screen_text, Output, Session, SessionEvent, TermOptions, WinSize};

/// 本机 Apple Silicon release 实测 50–80MB/s（机器同时在编译时）；GitHub macOS 运行器（3 核 M1 虚拟机）
/// 更慢且有抖动，取约 1/5–1/8 当下限，挡数量级的退化
const MIN_SPEED: f64 = 10.0;
/// 解析线程单次持锁最多吞 64KB，本机最慢一帧 6–37ms（随负载）；去掉这个上限时一帧要等整批数据解析完（数百毫秒）
const MAX_FRAME: Duration = Duration::from_millis(200);

#[test]
#[ignore]
fn fifty_megabytes_of_colored_output() {
    let (event_tx, event_rx) = mpsc::channel();
    let sink = Arc::new(move |event: SessionEvent| {
        let _ = event_tx.send(event);
    });
    let options = TermOptions {
        scrollback: 25000,
        cursor: "block".into(),
        word_separators: " ".into(),
        scroll_on_input: true,
        palette: Palette::default(),
        highlights: Vec::new(),
        bold_is_bright: true,
    };
    let (session, tx) = Session::new(options, WinSize { cols: 200, rows: 60, cell_width: 8, cell_height: 16 }, sink);

    let mut chunk = Vec::new();
    for line in 0..2000 {
        chunk.extend_from_slice(format!("\x1b[3{}m{line:05}\x1b[0m 日志 some log text with 中文 and more words to fill up the line ....\r\n", line % 8).as_bytes());
    }
    let total = 50 * 1024 * 1024;
    let started = Instant::now();
    let mut sent = 0;
    while sent < total {
        tx.send(Output::Data(chunk.clone())).unwrap();
        sent += chunk.len();
    }
    tx.send(Output::Closed(String::new())).unwrap();

    // 模拟界面每 16ms 拉一帧，直到解析完
    let mut frames = 0;
    let mut slowest = Duration::ZERO;
    loop {
        match event_rx.recv_timeout(Duration::from_millis(16)) {
            Ok(SessionEvent::Exit(_)) => break,
            _ => {
                let begin = Instant::now();
                let _ = session.frame();
                slowest = slowest.max(begin.elapsed());
                frames += 1;
            }
        }
    }
    let elapsed = started.elapsed();
    let speed = 50.0 / elapsed.as_secs_f64();
    println!(
        "50MB 用时 {:.2}s（{speed:.0} MB/s），期间拉帧 {frames} 次，最慢一帧 {:.2}ms",
        elapsed.as_secs_f64(),
        slowest.as_secs_f64() * 1000.0
    );

    // 一个字节都没丢：最后一块的最后一行在屏幕上
    assert!(screen_text(&session.frame()).contains("01999"), "最后一行没有出现在屏幕上");
    // 阈值依据见 MIN_SPEED / MAX_FRAME 注释：挡数量级的退化，不挡 CI 机器的正常抖动
    assert!(speed >= MIN_SPEED, "吞吐 {speed:.1} MB/s 低于 {MIN_SPEED} MB/s");
    assert!(slowest <= MAX_FRAME, "最慢一帧 {slowest:?} 超过 {MAX_FRAME:?}");
}
