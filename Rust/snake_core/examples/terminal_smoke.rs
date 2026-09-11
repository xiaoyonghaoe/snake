use snake_core::{open_terminal_password, CoreTerminalObserver};
use std::io::Read;
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};

enum TerminalEvent {
    Output(Vec<u8>),
    Closed(i32, Option<String>),
}

struct SmokeObserver {
    sender: Mutex<mpsc::Sender<TerminalEvent>>,
}

impl CoreTerminalObserver for SmokeObserver {
    fn on_output(&self, data: Vec<u8>) {
        if let Ok(sender) = self.sender.lock() {
            let _ = sender.send(TerminalEvent::Output(data));
        }
    }

    fn on_closed(&self, exit_status: i32, message: Option<String>) {
        if let Ok(sender) = self.sender.lock() {
            let _ = sender.send(TerminalEvent::Closed(exit_status, message));
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = std::env::args().collect::<Vec<_>>();
    if arguments.len() != 5 {
        return Err("usage: terminal_smoke <host> <port> <username> <known-hosts-path>".into());
    }
    let host = arguments[1].clone();
    let port = arguments[2].parse::<u16>()?;
    let username = arguments[3].clone();
    let known_hosts_path = arguments[4].clone();

    let mut password = Vec::new();
    std::io::stdin().read_to_end(&mut password)?;
    while matches!(password.last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    if password.is_empty() {
        return Err("password input is empty".into());
    }

    let (sender, receiver) = mpsc::channel();
    let observer = SmokeObserver {
        sender: Mutex::new(sender),
    };
    let terminal = open_terminal_password(
        host,
        port,
        username,
        password,
        known_hosts_path,
        None,
        100,
        30,
        Box::new(observer),
    )?;

    // This deliberately exceeds the former 15-second idle failure threshold.
    std::thread::sleep(Duration::from_secs(20));
    terminal.resize(120, 40, 1200, 800)?;
    std::thread::sleep(Duration::from_millis(200));
    terminal.write(b"printf 'SNAKE_PTY_OK\\n'; stty size; uname -srm; exit\n".to_vec())?;

    let deadline = Instant::now() + Duration::from_secs(15);
    let mut output = Vec::new();
    let mut closed = None;
    while Instant::now() < deadline {
        match receiver.recv_timeout(Duration::from_millis(250)) {
            Ok(TerminalEvent::Output(data)) => output.extend_from_slice(&data),
            Ok(TerminalEvent::Closed(status, message)) => {
                closed = Some((status, message));
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    terminal.close();

    let text = String::from_utf8_lossy(&output);
    if !text.contains("SNAKE_PTY_OK") {
        return Err(format!("PTY marker missing; output was: {text}").into());
    }
    if !text.lines().any(|line| line.trim() == "40 120") {
        return Err(format!("PTY resize was not applied; output was: {text}").into());
    }
    let Some((exit_status, message)) = closed else {
        return Err("remote shell did not close after exit".into());
    };
    if let Some(message) = message {
        return Err(format!("terminal closed with error: {message}").into());
    }
    if exit_status != 0 {
        return Err(format!("remote shell exited with status {exit_status}").into());
    }

    println!("Snake PTY smoke test passed after 20 seconds idle.");
    for line in text.lines().filter(|line| {
        line.contains("SNAKE_PTY_OK")
            || line.trim() == "40 120"
            || line.starts_with("Linux")
            || line.starts_with("Darwin")
    }) {
        println!("{line}");
    }
    Ok(())
}
