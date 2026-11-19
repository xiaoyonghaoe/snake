//! Real port-forwarding regressions for a disposable sshd on the same machine.
//! Run with SNAKE_SFTP_TEST_PORT, SNAKE_SFTP_TEST_USER and SNAKE_SFTP_TEST_KEY,
//! then `cargo test --test tunnel_regressions -- --ignored`.
use snake_core::*;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Records every observer call as a short event name.
struct Observer(Arc<Mutex<Vec<String>>>);
impl Observer {
    fn push(&self, event: &str) {
        self.0.lock().unwrap().push(event.to_owned());
    }
}
impl CoreTunnelObserver for Observer {
    fn on_closed(&self, _message: Option<String>) { self.push("closed"); }
    fn on_disconnected(&self, _message: String) { self.push("disconnected"); }
    fn on_reconnecting(&self) { self.push("reconnecting"); }
    fn on_reconnected(&self) { self.push("reconnected"); }
    fn on_reconnect_failed(&self, _message: String, _stage: Option<String>) { self.push("reconnect_failed"); }
}

/// Echoes every connection back until the peer closes it.
fn echo_server() -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut stream = stream;
                let mut buffer = [0u8; 4096];
                while let Ok(read) = stream.read(&mut buffer) {
                    if read == 0 || stream.write_all(&buffer[..read]).is_err() { break; }
                }
            });
        }
    });
    port
}

fn start(remote_port: u16, events: Arc<Mutex<Vec<String>>>) -> Arc<CoreTunnelHandle> {
    let port = std::env::var("SNAKE_SFTP_TEST_PORT").expect("disposable sshd port").parse().unwrap();
    let user = std::env::var("SNAKE_SFTP_TEST_USER").expect("fixture username");
    let key = std::env::var("SNAKE_SFTP_TEST_KEY").expect("fixture private-key path");
    let hosts = tempfile::tempdir().unwrap().keep().join("known_hosts");
    let fingerprint = probe_host_key("127.0.0.1".into(), port).unwrap().fingerprint;
    start_local_forward_private_key(
        "127.0.0.1".into(), port, user, key, None, hosts.display().to_string(), Some(fingerprint),
        0, "127.0.0.1".into(), remote_port, Box::new(Observer(events)),
    )
    .unwrap()
}

fn round_trip(port: u16, payload: &[u8]) -> Vec<u8> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    stream.write_all(payload).unwrap();
    let mut received = vec![0u8; payload.len()];
    stream.read_exact(&mut received).unwrap();
    received
}

#[test]
#[ignore = "requires a disposable loopback sshd"]
fn forwards_concurrent_connections_and_stops_cleanly() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let handle = start(echo_server(), Arc::clone(&events));
    let port = handle.local_port();
    assert_ne!(port, 0);

    let large: Vec<u8> = (0..2_000_000u32).map(|value| (value % 251) as u8).collect();
    let threads: Vec<_> = (0..4)
        .map(|index| {
            let payload = if index == 0 { large.clone() } else { format!("ping {index}").into_bytes() };
            std::thread::spawn(move || assert_eq!(round_trip(port, &payload), payload))
        })
        .collect();
    for thread in threads { thread.join().unwrap(); }

    let mut open = TcpStream::connect(("127.0.0.1", port)).unwrap();
    open.write_all(b"x").unwrap();
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(handle.active_connections(), 1);

    handle.stop();
    assert!(handle.is_closed());
    std::thread::sleep(Duration::from_millis(300));
    assert!(TcpStream::connect(("127.0.0.1", port)).is_err(), "listener closes on stop");
    open.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut rest = Vec::new();
    let _ = open.read_to_end(&mut rest);
    assert!(events.lock().unwrap().is_empty(), "a requested stop is not reported as a failure");
}

#[test]
#[ignore = "requires a disposable loopback sshd"]
fn refused_remote_port_closes_only_that_connection() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let closed_port = TcpListener::bind(("127.0.0.1", 0)).unwrap().local_addr().unwrap().port();
    let handle = start(closed_port, Arc::clone(&events));
    let mut stream = TcpStream::connect(("127.0.0.1", handle.local_port())).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut buffer = [0u8; 1];
    assert_eq!(stream.read(&mut buffer).unwrap_or(0), 0);
    assert!(!handle.is_closed());
    handle.stop();
}

/// Also needs SNAKE_SSHD_PID: the test kills that sshd's session children to
/// drop the connection the way a network failure would.
#[test]
#[ignore = "requires a disposable loopback sshd"]
fn lost_connection_keeps_listening_and_reconnects_on_access() {
    let pid = std::env::var("SNAKE_SSHD_PID").expect("disposable sshd pid");
    let events = Arc::new(Mutex::new(Vec::new()));
    let handle = start(echo_server(), Arc::clone(&events));
    let port = handle.local_port();
    assert_eq!(round_trip(port, b"before"), b"before");
    std::process::Command::new("pkill").args(["-P", &pid]).status().unwrap();
    for _ in 0..100 {
        if events.lock().unwrap().iter().any(|event| event == "disconnected") { break; }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(*events.lock().unwrap(), ["disconnected"], "the drop is reported once");
    assert!(!handle.is_closed(), "the tunnel stays up");

    // The next local connection reopens SSH and is forwarded normally.
    assert_eq!(round_trip(port, b"after"), b"after");
    assert_eq!(*events.lock().unwrap(), ["disconnected", "reconnecting", "reconnected"]);
    handle.stop();
}

/// Destroys the fixture: kills the whole sshd named by SNAKE_SSHD_PID, so run
/// it on its own and last.
#[test]
#[ignore = "requires a disposable loopback sshd it may kill"]
fn failed_reconnect_is_reported_once_and_the_port_stays_open() {
    let pid = std::env::var("SNAKE_SSHD_PID").expect("disposable sshd pid");
    let events = Arc::new(Mutex::new(Vec::new()));
    let handle = start(echo_server(), Arc::clone(&events));
    let port = handle.local_port();
    std::process::Command::new("pkill").args(["-P", &pid]).status().unwrap();
    std::process::Command::new("kill").arg(&pid).status().unwrap();
    for _ in 0..100 {
        if !events.lock().unwrap().is_empty() { break; }
        std::thread::sleep(Duration::from_millis(100));
    }

    let closed_at_once = |port: u16| {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("the port stays open");
        stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        let mut buffer = [0u8; 1];
        assert_eq!(stream.read(&mut buffer).unwrap_or(0), 0, "the client sees the connection close");
    };
    closed_at_once(port);
    assert_eq!(*events.lock().unwrap(), ["disconnected", "reconnecting", "reconnect_failed"]);
    // Within the cooldown the next access is refused without another attempt.
    closed_at_once(port);
    assert_eq!(events.lock().unwrap().len(), 3);
    assert!(!handle.is_closed());
    handle.stop();
}
