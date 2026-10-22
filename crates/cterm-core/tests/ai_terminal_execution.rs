#![cfg(unix)]

use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cterm_core::frame::Palette;
use cterm_core::history::History;
use cterm_core::local::{self, LocalOptions};
use cterm_core::session::{EventSink, Session, SessionEvent, TermOptions, WinSize};

fn interactive_shell() -> Arc<Session> {
    let (event_tx, _event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event: SessionEvent| {
        let _ = event_tx.send(event);
    });
    let size = WinSize {
        cols: 80,
        rows: 24,
        cell_width: 8,
        cell_height: 16,
    };
    let options = TermOptions {
        scrollback: 100,
        cursor: "block".into(),
        word_separators: " ".into(),
        scroll_on_input: true,
        palette: Palette::default(),
        highlights: Vec::new(),
        bold_is_bright: true,
        history: Some(Arc::new(Mutex::new(History::default()))),
    };
    let (session, tx) = Session::new(options, size, sink);
    let shell = LocalOptions {
        command: "/bin/sh".into(),
        args: vec!["-i".into()],
        env: vec![("PS1".into(), "cterm-test$ ".into())],
        ..Default::default()
    };
    session.attach(Box::new(
        local::spawn(&shell, size, tx).expect("spawn shell"),
    ));

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if session.ai_capability().is_some() {
            return session;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("interactive shell did not reach its prompt");
}

fn wait_until_prompt(session: &Session) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match session.ai_execute("prompt-probe", "true") {
            Ok(_) => return,
            Err(error) if error.contains("不在可确认的 shell 提示符") => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("unexpected prompt probe failure: {error}"),
        }
    }
    panic!("shell did not return to prompt");
}

#[test]
fn executes_in_the_original_shell_captures_output_and_exit_status() {
    let session = interactive_shell();
    wait_until_prompt(&session);
    let result = session
        .ai_execute("call-1", "cd /tmp; printf 'same-shell\\n'; false")
        .expect("execute confirmed command");
    let result: serde_json::Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result["status"], "completed");
    assert_eq!(result["exitCode"], 1);
    assert_eq!(result["output"], "same-shell\n");
    assert!(session.cwd().unwrap().ends_with("/tmp"));
    session.close();
}

#[test]
fn refuses_unsubmitted_input_but_allows_ctrl_c_during_execution() {
    let session = interactive_shell();
    wait_until_prompt(&session);
    session.input(b"echo draft");
    assert!(session.ai_execute("draft", "echo should-not-run").is_err());
    session.input(&[0x03]);
    wait_until_prompt(&session);

    let cwd_before = session.cwd().unwrap();
    let command_session = session.clone();
    let started = Instant::now();
    let execution = thread::spawn(move || command_session.ai_execute("long", "sleep 10"));
    thread::sleep(Duration::from_millis(150));
    session.input(b"cd /; echo unsafe\r");
    session.input(&[0x03]);
    let result = execution
        .join()
        .expect("execution thread")
        .expect("cancel should return through shell marker");
    let result: serde_json::Value = serde_json::from_str(&result).unwrap();
    assert!(started.elapsed() < Duration::from_secs(2), "Ctrl-C must interrupt instead of waiting for sleep to finish");
    assert_eq!(result["status"], "completed");
    assert_ne!(result["exitCode"], 0);
    let after = session.ai_execute("after", "pwd").unwrap();
    let after: serde_json::Value = serde_json::from_str(&after).unwrap();
    assert_eq!(after["output"].as_str().unwrap().trim(), cwd_before);
    session.close();
}
