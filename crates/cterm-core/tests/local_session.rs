// 用 /bin/sh 驱动真实 PTY；Windows 的 ConPTY 由 CI 上的构建和手工冒烟覆盖
#![cfg(unix)]

use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use cterm_core::frame::{Palette, RUN_DEFAULT_BG};
use cterm_core::local::{self, LocalOptions};
use cterm_core::session::{screen_text, Session, SessionEvent, TermOptions, WinSize};

fn run(command: &str) -> (Arc<Session>, String) {
    let (event_tx, event_rx) = mpsc::channel();
    let sink = Arc::new(move |event: SessionEvent| {
        let _ = event_tx.send(event);
    });
    let size = WinSize { cols: 40, rows: 5, cell_width: 8, cell_height: 16 };
    let options = TermOptions { scrollback: 100, cursor: "block".into(), word_separators: " ".into(), scroll_on_input: true, palette: Palette::default(), highlights: Vec::new(), bold_is_bright: true };
    let (session, tx) = Session::new(options, size, sink);
    let local = LocalOptions { command: "/bin/sh".into(), args: vec!["-c".into(), command.into()], ..Default::default() };
    let transport = local::spawn(&local, size, tx).expect("spawn");
    session.attach(Box::new(transport));
    loop {
        match event_rx.recv_timeout(Duration::from_secs(5)).expect("session should exit") {
            SessionEvent::Exit(reason) => return (session, reason),
            _ => continue,
        }
    }
}

#[test]
fn shell_output_reaches_frame_with_colors() {
    let (session, reason) = run(r#"printf 'hello \033[31mred\033[0m 中'"#);
    assert_eq!(reason, "");
    let frame = session.frame();
    assert_eq!(screen_text(&frame).lines().next().unwrap(), "hello red 中");
    let first = &frame.lines[0].runs;
    let red = first.iter().find(|run| run.text == "red").expect("red run");
    assert_eq!(red.fg, Palette::default().ansi[1]);
    let wide = first.iter().find(|run| run.text == "中").expect("wide run");
    assert_eq!(wide.width, 2);
    assert!(red.flags & RUN_DEFAULT_BG != 0);
}

#[test]
fn exit_code_is_reported() {
    let (_, reason) = run("exit 3");
    assert!(reason.contains('3'), "{reason}");
}

#[test]
fn scrollback_selection_and_search() {
    let (session, _) = run("for i in 1 2 3 4 5 6 7 8 9; do echo line$i; done");
    let frame = session.frame();
    assert!(frame.history_size > 0);
    assert!(session.search("line2", true).unwrap());
    let frame = session.frame();
    assert!(frame.display_offset > 0, "search should scroll to the match");
    session.select_all();
    let text = session.selection_text().unwrap();
    assert!(text.contains("line1") && text.contains("line9"));
}

#[test]
fn cwd_of_running_shell() {
    let (event_tx, _event_rx) = mpsc::channel();
    let sink = Arc::new(move |event: SessionEvent| {
        let _ = event_tx.send(event);
    });
    let size = WinSize { cols: 40, rows: 5, cell_width: 8, cell_height: 16 };
    let options = TermOptions { scrollback: 100, cursor: "block".into(), word_separators: " ".into(), scroll_on_input: true, palette: Palette::default(), highlights: Vec::new(), bold_is_bright: true };
    let (session, tx) = Session::new(options, size, sink);
    let local = LocalOptions { command: "/bin/sleep".into(), args: vec!["2".into()], cwd: "/tmp".into(), ..Default::default() };
    session.attach(Box::new(local::spawn(&local, size, tx).unwrap()));
    let cwd = session.cwd().unwrap();
    assert!(cwd.ends_with("/tmp"), "{cwd}");
    session.close();
}
