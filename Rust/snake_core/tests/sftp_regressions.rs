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
fn directory_copy_rejects_descendants_and_resolves_symlink_aliases() {
    let root = tempfile::tempdir().unwrap();
    let hosts = root.path().join("known_hosts");
    let source = connect(&hosts);
    let destination = connect(&hosts);
    let folder = root.path().join("source");
    fs::create_dir(&folder).unwrap();
    fs::write(folder.join("data"), b"content").unwrap();
    let alias = root.path().join("alias");
    std::os::unix::fs::symlink(&folder, &alias).unwrap();
    for path in [&folder, &alias] {
        let nested = path.join("child");
        let result = destination.copy_from_controlled(
            Arc::clone(&source),
            folder.display().to_string(),
            nested.display().to_string(),
            true,
            7,
            CoreTransferControl::new(),
            Box::new(Observer),
        );
        assert!(matches!(result, Err(CoreError::InvalidInput { .. })));
        assert!(!nested.exists());
        assert!(destination
            .copy_from(
                Arc::clone(&source),
                folder.display().to_string(),
                nested.display().to_string(),
                true
            )
            .is_err());
        assert!(!nested.exists());
    }
    let sibling = root.path().join("source2");
    destination
        .copy_from_controlled(
            source,
            folder.display().to_string(),
            sibling.display().to_string(),
            true,
            7,
            CoreTransferControl::new(),
            Box::new(Observer),
        )
        .unwrap();
    assert_eq!(fs::read(sibling.join("data")).unwrap(), b"content");
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
