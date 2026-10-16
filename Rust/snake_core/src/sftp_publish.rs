//! ssh2 0.9's rename flags are not sent to SFTP v3 servers. OpenSSH's atomic
//! replacement is a separate extension which that wrapper does not expose.
//! Negotiate it on a short-lived subsystem channel on the verified session.
use super::{connection_error, io_error, CoreError, Session};
use std::io::{Read, Write};

const POSIX_RENAME: &[u8] = b"posix-rename@openssh.com";
const MAX_PACKET: usize = 64 * 1024;

fn failure(message: &str) -> CoreError {
    CoreError::Connection {
        message: message.into(),
        stage: None,
    }
}

fn write_packet(output: &mut impl Write, packet: &[u8]) -> Result<(), CoreError> {
    if packet.len() > MAX_PACKET {
        return Err(failure("SFTP rename request is too large"));
    }
    output
        .write_all(&(packet.len() as u32).to_be_bytes())
        .map_err(io_error)?;
    output.write_all(packet).map_err(io_error)?;
    output.flush().map_err(io_error)
}

fn read_packet(input: &mut impl Read) -> Result<Vec<u8>, CoreError> {
    let mut length = [0; 4];
    input.read_exact(&mut length).map_err(io_error)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_PACKET {
        return Err(failure("Invalid SFTP rename response length"));
    }
    let mut packet = vec![0; length];
    input.read_exact(&mut packet).map_err(io_error)?;
    Ok(packet)
}

fn take_u32(input: &mut &[u8]) -> Result<u32, CoreError> {
    if input.len() < 4 {
        return Err(failure("Truncated SFTP rename response"));
    }
    let (value, rest) = input.split_at(4);
    *input = rest;
    Ok(u32::from_be_bytes(value.try_into().unwrap()))
}

fn take_string<'a>(input: &mut &'a [u8]) -> Result<&'a [u8], CoreError> {
    let length = take_u32(input)? as usize;
    if input.len() < length {
        return Err(failure("Truncated SFTP extension field"));
    }
    let (value, rest) = input.split_at(length);
    *input = rest;
    Ok(value)
}

fn put_string(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u32).to_be_bytes());
    output.extend_from_slice(value);
}

fn supports_atomic_rename(packet: &[u8]) -> Result<bool, CoreError> {
    if packet.first() != Some(&2) {
        return Err(failure("Expected SFTP version response"));
    }
    let mut fields = &packet[1..];
    if take_u32(&mut fields)? != 3 {
        return Err(failure("Unsupported SFTP version for atomic rename"));
    }
    let mut supported = false;
    while !fields.is_empty() {
        let name = take_string(&mut fields)?;
        let version = take_string(&mut fields)?;
        supported |= name == POSIX_RENAME && version == b"1";
    }
    Ok(supported)
}

fn check_status(packet: &[u8]) -> Result<(), CoreError> {
    if packet.first() != Some(&101) {
        return Err(failure("Expected SFTP rename status"));
    }
    let mut fields = &packet[1..];
    if take_u32(&mut fields)? != 1 {
        return Err(failure("Unexpected SFTP rename response ID"));
    }
    let status = take_u32(&mut fields)?;
    // Validate the framing, but never surface arbitrary remote diagnostic text.
    take_string(&mut fields)?;
    take_string(&mut fields)?;
    if !fields.is_empty() {
        return Err(failure("Invalid SFTP rename status fields"));
    }
    if status != 0 {
        return Err(failure(&format!(
            "Atomic SFTP rename failed (status {status}); original target was not removed"
        )));
    }
    Ok(())
}

pub(super) fn atomic_rename(
    session: &Session,
    source: &str,
    target: &str,
) -> Result<(), CoreError> {
    let mut channel = session.channel_session().map_err(connection_error)?;
    channel.subsystem("sftp").map_err(connection_error)?;
    let mut init = vec![1];
    init.extend_from_slice(&3_u32.to_be_bytes());
    write_packet(&mut channel, &init)?;
    if !supports_atomic_rename(&read_packet(&mut channel)?)? {
        return Err(failure(
            "Server does not support atomic SFTP replacement; original target was not removed",
        ));
    }
    let mut request = vec![200];
    request.extend_from_slice(&1_u32.to_be_bytes());
    put_string(&mut request, POSIX_RENAME);
    put_string(&mut request, source.as_bytes());
    put_string(&mut request, target.as_bytes());
    write_packet(&mut channel, &request)?;
    check_status(&read_packet(&mut channel)?)?;
    // Publication has committed. A channel teardown error must not turn a
    // completed transfer into a failed upload or trigger a destructive retry.
    let _ = channel.send_eof();
    let _ = channel.close();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiates_explicit_extension_and_rejects_malformed_fields() {
        let mut version = vec![2, 0, 0, 0, 3];
        assert!(!supports_atomic_rename(&version).unwrap());
        put_string(&mut version, POSIX_RENAME);
        put_string(&mut version, b"1");
        assert!(supports_atomic_rename(&version).unwrap());
        version.pop();
        assert!(supports_atomic_rename(&version).is_err());
        assert!(supports_atomic_rename(&[]).is_err());
    }

    #[test]
    fn validates_status_and_bounds_packets_before_allocating() {
        let mut status = vec![101, 0, 0, 0, 1, 0, 0, 0, 0];
        put_string(&mut status, b"");
        put_string(&mut status, b"");
        assert!(check_status(&status).is_ok());
        status[8] = 4;
        assert!(check_status(&status).is_err());
        status[8] = 0;
        status[4] = 2;
        assert!(check_status(&status).is_err());
        for bytes in [vec![0, 0, 0, 0], vec![0, 1, 0, 1], vec![0, 0, 0, 4, 1]] {
            assert!(read_packet(&mut bytes.as_slice()).is_err());
        }
    }
}
