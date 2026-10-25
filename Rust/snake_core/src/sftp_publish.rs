//! Atomic replacement of an upload target. Plain SFTP v3 rename fails when the
//! target exists, so publication uses OpenSSH's `posix-rename@openssh.com`
//! extension, advertised in the SFTP VERSION reply of the handle's session.
use super::sftp_client::Sftp;
use super::ssh::block_on;
use super::CoreError;
use russh_sftp::protocol::{Packet, StatusCode};

const POSIX_RENAME: &str = "posix-rename@openssh.com";

fn failure(message: &str) -> CoreError {
    CoreError::Connection {
        message: message.into(),
        stage: None,
    }
}

fn put_string(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u32).to_be_bytes());
    output.extend_from_slice(value);
}

fn request_payload(source: &str, target: &str) -> Vec<u8> {
    let mut payload = Vec::with_capacity(source.len() + target.len() + 8);
    put_string(&mut payload, source.as_bytes());
    put_string(&mut payload, target.as_bytes());
    payload
}

fn check_reply(reply: Packet) -> Result<(), CoreError> {
    match reply {
        // Never surface arbitrary remote diagnostic text.
        Packet::Status(status) if status.status_code == StatusCode::Ok => Ok(()),
        Packet::Status(status) => Err(failure(&format!(
            "Atomic SFTP rename failed (status {}); original target was not removed",
            status.status_code as u32
        ))),
        _ => Err(failure("Expected SFTP rename status")),
    }
}

pub(super) fn atomic_rename(sftp: &Sftp, source: &str, target: &str) -> Result<(), CoreError> {
    if !sftp.supports_posix_rename() {
        return Err(failure(
            "Server does not support atomic SFTP replacement; original target was not removed",
        ));
    }
    let reply = block_on(sftp.raw().extended(POSIX_RENAME, request_payload(source, target)))
        .map_err(|error| failure(&format!("Atomic SFTP rename failed: {error}; original target was not removed")))?;
    check_reply(reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh_sftp::protocol::Status;

    fn status(code: StatusCode) -> Packet {
        Packet::Status(Status { id: 1, status_code: code, error_message: "remote detail".into(), language_tag: String::new() })
    }

    #[test]
    fn encodes_both_paths_as_ssh_strings() {
        assert_eq!(request_payload("/a", "/bc"), b"\0\0\0\x02/a\0\0\0\x03/bc");
    }

    #[test]
    fn accepts_only_an_ok_status_and_hides_remote_text() {
        assert!(check_reply(status(StatusCode::Ok)).is_ok());
        let error = check_reply(status(StatusCode::PermissionDenied)).unwrap_err();
        assert!(!format!("{error:?}").contains("remote detail"));
        assert!(check_reply(Packet::Status(Status {
            id: 1, status_code: StatusCode::Failure, error_message: String::new(), language_tag: String::new()
        })).is_err());
    }
}
