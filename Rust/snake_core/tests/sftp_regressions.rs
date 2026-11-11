//! Real SFTP regressions for a disposable sshd on the same machine.
//! Run with SNAKE_SFTP_TEST_PORT, SNAKE_SFTP_TEST_USER and SNAKE_SFTP_TEST_KEY,
//! then `cargo test --test sftp_regressions -- --ignored`.
use snake_core::*;
use std::{fs, path::Path, sync::Arc};

struct Observer;
impl CoreTransferObserver for Observer {
    fn on_progress(&self, _: u64, _: u64) {}
}

fn connect(hosts: &Path) -> Arc<CoreSftpHandle> {
    let port = std::env::var("SNAKE_SFTP_TEST_PORT")
        .expect("disposable sshd port")
        .parse()
        .unwrap();
    let user = std::env::var("SNAKE_SFTP_TEST_USER").expect("fixture username");
    let key = std::env::var("SNAKE_SFTP_TEST_KEY").expect("fixture private-key path");
    let fingerprint = probe_host_key("127.0.0.1".into(), port)
        .unwrap()
        .fingerprint;
    open_sftp_private_key(
        "127.0.0.1".into(),
        port,
        user,
        key,
        None,
        hosts.display().to_string(),
        Some(fingerprint),
        false,
    )
    .unwrap()
}

#[test]
#[ignore = "requires a disposable loopback sshd"]
fn publication_uses_exact_target_and_preserves_conflicting_directories() {
    let root = tempfile::tempdir().unwrap();
    let handle = connect(&root.path().join("known_hosts"));
    let staging = root.path().join(".snake-upload-test.staging");
    let target = root.path().join("target");
    fs::create_dir(&target).unwrap();
    fs::write(&staging, b"new").unwrap();
    assert!(handle
        .publish_upload(
            staging.display().to_string(),
            target.display().to_string(),
            vec![],
            true,
            CoreTransferControl::new()
        )
        .is_err());
    assert!(staging.exists());
    assert_eq!(fs::read_dir(&target).unwrap().count(), 0);

    let alias = root.path().join("directory-link");
    std::os::unix::fs::symlink(&target, &alias).unwrap();
    assert!(handle
        .publish_upload(
            staging.display().to_string(),
            alias.display().to_string(),
            vec![],
            true,
            CoreTransferControl::new()
        )
        .is_err());
    assert!(staging.exists());
    assert_eq!(fs::read_dir(&target).unwrap().count(), 0);

    let part = root.path().join(".snake-upload-test.part.0");
    fs::write(&part, b"legacy").unwrap();
    assert!(handle
        .finalize_resumable_upload(
            vec![part.display().to_string()],
            staging.display().to_string(),
            target.display().to_string(),
            true
        )
        .is_err());
    assert!(part.exists());
    assert_eq!(fs::read_dir(&target).unwrap().count(), 0);

    fs::remove_dir(&target).unwrap();
    fs::write(&target, b"old").unwrap();
    fs::write(&staging, b"new").unwrap();
    assert!(handle
        .publish_upload(
            staging.display().to_string(),
            target.display().to_string(),
            vec![],
            false,
            CoreTransferControl::new()
        )
        .is_err());
    assert_eq!(fs::read(&target).unwrap(), b"old");
    handle
        .publish_upload(
            staging.display().to_string(),
            target.display().to_string(),
            vec![],
            true,
            CoreTransferControl::new(),
        )
        .unwrap();
    assert_eq!(fs::read(&target).unwrap(), b"new");
    assert!(!staging.exists());
}

#[test]
#[ignore = "requires a disposable loopback sshd"]
fn resumable_upload_keeps_verified_prefix_and_new_jobs_use_separate_parts() {
    let root = tempfile::tempdir().unwrap();
    let handle = connect(&root.path().join("known_hosts"));
    let local = root.path().join("local");
    fs::write(&local, b"BBBBBBBBBBBBBBBB").unwrap();
    let stale = root.path().join(".snake-upload-old-job.part.0");
    fs::write(&stale, b"AAAAAAAA").unwrap();
    let part = root.path().join(".snake-upload-current-job.part.0");
    fs::write(&part, b"BBBBBBBB").unwrap();
    let control = CoreTransferControl::new();
    handle
        .upload_part_resumable(
            local.display().to_string(),
            part.display().to_string(),
            0,
            16,
            Arc::clone(&control),
            Box::new(Observer),
        )
        .unwrap();
    let staging = root.path().join(".snake-upload-current-job.staging");
    handle
        .assemble_upload(
            vec![part.display().to_string()],
            staging.display().to_string(),
            Arc::clone(&control),
        )
        .unwrap();
    let target = root.path().join("result");
    handle
        .publish_upload(
            staging.display().to_string(),
            target.display().to_string(),
            vec![part.display().to_string()],
            false,
            control,
        )
        .unwrap();
    assert_eq!(fs::read(target).unwrap(), fs::read(local).unwrap());
    assert_eq!(fs::read(stale).unwrap(), b"AAAAAAAA");
}

#[test]
#[ignore = "requires a disposable loopback sshd"]
fn listing_resolves_links_without_following_them_as_entries() {
    let root = tempfile::tempdir().unwrap();
    let handle = connect(&root.path().join("known_hosts"));
    let base = root.path().join("listing");
    fs::create_dir(&base).unwrap();
    fs::write(base.join("file.txt"), b"12345").unwrap();
    fs::create_dir(base.join("folder")).unwrap();
    std::os::unix::fs::symlink(base.join("folder"), base.join("to-folder")).unwrap();
    std::os::unix::fs::symlink(base.join("file.txt"), base.join("to-file")).unwrap();
    std::os::unix::fs::symlink(base.join("missing"), base.join("broken")).unwrap();

    let entries = handle.list(base.display().to_string()).unwrap();
    let entry = |name: &str| entries.iter().find(|entry| entry.name == name).unwrap();
    assert_eq!(entries.len(), 5);
    assert!(entry("folder").is_directory && !entry("folder").is_symbolic_link);
    assert!(!entry("file.txt").is_directory && entry("file.txt").size == 5);
    assert!(entry("to-folder").is_symbolic_link && entry("to-folder").is_directory);
    assert_eq!(entry("to-folder").link_target.as_deref(), Some(base.join("folder").to_str().unwrap()));
    assert!(entry("to-file").is_symbolic_link && !entry("to-file").is_directory && entry("to-file").size == 5);
    assert!(entry("broken").is_symbolic_link && !entry("broken").is_directory);
    // Directories, then names: links to folders sort with folders.
    assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(),
               ["folder", "to-folder", "broken", "file.txt", "to-file"]);
}

/// Also needs SNAKE_SSHD_PID: killing that sshd's session children drops the
/// connection the way a network failure would.
#[test]
#[ignore = "requires a disposable loopback sshd"]
fn handle_reports_closed_after_the_connection_drops() {
    let pid = std::env::var("SNAKE_SSHD_PID").expect("disposable sshd pid");
    let root = tempfile::tempdir().unwrap();
    let handle = connect(&root.path().join("known_hosts"));
    assert!(!handle.is_closed());
    handle.home_directory().unwrap();
    std::process::Command::new("pkill").args(["-P", &pid]).status().unwrap();
    for _ in 0..200 {
        if handle.is_closed() { break; }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    assert!(handle.is_closed(), "a dropped connection must be visible so the tab can reconnect");
    assert!(handle.list("/".into()).is_err());
}
