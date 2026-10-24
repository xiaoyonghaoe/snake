//! OpenSSH `known_hosts` handling for Snake's own trust file.
//!
//! The key blob is treated as opaque bytes, so verification behaves the same
//! for every algorithm. Entries are matched by the exact endpoint label
//! (`host` for port 22, `[host]:port` otherwise), including hashed `|1|`
//! entries written by OpenSSH. Unrelated lines, comments and markers are kept
//! byte for byte when the file is rewritten.

use super::*;
use hmac::{Hmac, Mac};
use sha1::Sha1;

// Serialize read/modify/write across simultaneous terminal and SFTP connections.
static KNOWN_HOSTS_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn endpoint_label(host: &str, port: u16) -> String {
    if port == 22 { host.to_owned() } else { format!("[{host}]:{port}") }
}

struct Entry<'a> {
    hosts: &'a str,
    key: Vec<u8>,
}

/// `None` for comments, blank lines, `@cert-authority`/`@revoked` markers and
/// anything that does not parse; those lines are preserved but never match.
fn parse(line: &str) -> Option<Entry<'_>> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('@') {
        return None;
    }
    let mut fields = trimmed.split_ascii_whitespace();
    let hosts = fields.next()?;
    let _algorithm = fields.next()?;
    let key = STANDARD.decode(fields.next()?).ok()?;
    Some(Entry { hosts, key })
}

fn host_pattern_matches(pattern: &str, label: &str) -> bool {
    if let Some(hashed) = pattern.strip_prefix("|1|") {
        let Some((salt, digest)) = hashed.split_once('|') else { return false };
        let (Ok(salt), Ok(digest)) = (STANDARD.decode(salt), STANDARD.decode(digest)) else { return false };
        let Ok(mut mac) = Hmac::<Sha1>::new_from_slice(&salt) else { return false };
        mac.update(label.as_bytes());
        return mac.verify_slice(&digest).is_ok();
    }
    pattern.split(',').any(|candidate| candidate == label)
}

/// The algorithm name embedded at the start of an SSH public key blob.
pub(crate) fn blob_algorithm(key: &[u8]) -> Option<&str> {
    let length = u32::from_be_bytes(key.get(..4)?.try_into().ok()?) as usize;
    std::str::from_utf8(key.get(4..4 + length)?).ok()
}

/// Checks `key` for the endpoint and, only when `accept_fingerprint` names this
/// exact key, replaces every stored key for the endpoint with it.
pub(crate) fn verify_host_key(
    host: &str,
    port: u16,
    key: &[u8],
    algorithm_name: &str,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<(), CoreError> {
    let _guard = KNOWN_HOSTS_LOCK.lock().map_err(|_| CoreError::StorageLock)?;
    let record = host_key_record(host, port, key);
    let label = endpoint_label(host, port);
    let file = PathBuf::from(known_hosts_path);
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent).map_err(io_error)?;
    }
    let contents = match std::fs::read_to_string(&file) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(io_error(error)),
    };

    let mut matched = false;
    let mut previous_fingerprints = Vec::new();
    let mut retained = Vec::new();
    for line in contents.lines() {
        match parse(line) {
            Some(entry) if host_pattern_matches(entry.hosts, &label) => {
                if entry.key == key {
                    matched = true;
                } else {
                    previous_fingerprints.push(host_key_fingerprint(&entry.key));
                }
            }
            _ => retained.push(line),
        }
    }
    // OpenSSH semantics: any stored key for the endpoint that equals the
    // offered key is a match, even if other algorithms are also recorded.
    if matched {
        return Ok(());
    }
    if accept_fingerprint != Some(record.fingerprint.as_str()) {
        if !previous_fingerprints.is_empty() {
            return Err(CoreError::HostKeyMismatch {
                host: record.host,
                port: record.port,
                algorithm: record.algorithm,
                fingerprint: record.fingerprint,
                previous_fingerprints,
            });
        }
        return Err(CoreError::HostKeyUnknown {
            host: record.host,
            port: record.port,
            algorithm: record.algorithm,
            fingerprint: record.fingerprint,
        });
    }
    let mut output = retained.join("\n");
    if !output.is_empty() {
        output.push('\n');
    }
    output.push_str(&format!("{label} {algorithm_name} {} Snake\n", STANDARD.encode(key)));
    persist(&file, &output)
}

fn persist(file: &Path, contents: &str) -> Result<(), CoreError> {
    let temporary = file.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut output = options.open(&temporary).map_err(io_error)?;
    let result = (|| {
        output.write_all(contents.as_bytes()).map_err(io_error)?;
        output.sync_all().map_err(io_error)?;
        std::fs::rename(&temporary, file).map_err(io_error)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

pub(crate) fn host_key_record(host: &str, port: u16, key: &[u8]) -> CoreHostKey {
    CoreHostKey {
        host: host.to_owned(),
        port,
        algorithm: host_key_label(blob_algorithm(key).unwrap_or_default()).to_owned(),
        fingerprint: host_key_fingerprint(key),
    }
}

/// Short labels shown in Snake's trust prompt; unchanged from the libssh2 era.
fn host_key_label(algorithm: &str) -> &'static str {
    match algorithm {
        "ssh-rsa" | "rsa-sha2-256" | "rsa-sha2-512" => "RSA",
        "ssh-dss" => "DSA",
        "ecdsa-sha2-nistp256" => "ECDSA-256",
        "ecdsa-sha2-nistp384" => "ECDSA-384",
        "ecdsa-sha2-nistp521" => "ECDSA-521",
        "ssh-ed25519" => "ED25519",
        _ => "UNKNOWN",
    }
}

pub(crate) fn host_key_fingerprint(key: &[u8]) -> String {
    let fingerprint = Sha256::digest(key)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":");
    format!("SHA256 {fingerprint}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blob(name: &str, body: &[u8]) -> Vec<u8> {
        let mut key = (name.len() as u32).to_be_bytes().to_vec();
        key.extend_from_slice(name.as_bytes());
        key.extend_from_slice(body);
        key
    }

    #[test]
    fn host_key_fingerprint_is_stable_and_algorithm_labeled() {
        let record = host_key_record("host.example", 2222, &blob("ssh-ed25519", b"server-public-key"));
        assert_eq!((record.host.as_str(), record.port, record.algorithm.as_str()), ("host.example", 2222, "ED25519"));
        assert!(record.fingerprint.starts_with("SHA256 "));
        assert_eq!(record.fingerprint.matches(':').count(), 31);
        assert_eq!(host_key_record("h", 22, b"junk").algorithm, "UNKNOWN");
    }

    #[test]
    fn changed_host_key_requires_exact_confirmation_and_preserves_other_endpoints() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("known_hosts");
        let path = file.to_str().unwrap();
        let (old, new, third, another) = (blob("ssh-ed25519", b"old"), blob("ssh-ed25519", b"new"),
            blob("ssh-ed25519", b"third"), blob("ssh-ed25519", b"another"));
        let verify = |host, port, key: &[u8], accepted: Option<&str>| {
            verify_host_key(host, port, key, "ssh-ed25519", path, accepted)
        };
        for (host, port) in [("127.0.0.1", 49326), ("127.0.0.1", 22), ("other.example", 49326)] {
            verify(host, port, &old, Some(&host_key_fingerprint(&old))).unwrap();
        }
        let original = std::fs::read(&file).unwrap();
        for accepted in [None, Some(host_key_fingerprint(&old)), Some(host_key_fingerprint(&another))] {
            match verify("127.0.0.1", 49326, &new, accepted.as_deref()).unwrap_err() {
                CoreError::HostKeyMismatch { previous_fingerprints, fingerprint, .. } => {
                    assert_eq!(previous_fingerprints, vec![host_key_fingerprint(&old)]);
                    assert_eq!(fingerprint, host_key_fingerprint(&new));
                }
                error => panic!("unexpected error: {error:?}"),
            }
            assert_eq!(std::fs::read(&file).unwrap(), original);
        }
        // A server changing again between prompt and reconnect must be rejected.
        assert!(matches!(
            verify("127.0.0.1", 49326, &third, Some(&host_key_fingerprint(&new))),
            Err(CoreError::HostKeyMismatch { .. })
        ));
        assert_eq!(std::fs::read(&file).unwrap(), original);

        verify("127.0.0.1", 49326, &new, Some(&host_key_fingerprint(&new))).unwrap();
        verify("127.0.0.1", 49326, &new, None).unwrap();
        verify("127.0.0.1", 22, &old, None).unwrap();
        verify("other.example", 49326, &old, None).unwrap();
        assert!(matches!(verify("127.0.0.1", 49326, &old, None), Err(CoreError::HostKeyMismatch { .. })));
        let contents = std::fs::read_to_string(&file).unwrap();
        assert_eq!(contents.lines().count(), 3);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn unknown_host_key_is_not_saved_without_confirmation() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("known_hosts");
        let key = blob("ssh-ed25519", b"new");
        let result = verify_host_key("test.example", 22, &key, "ssh-ed25519", file.to_str().unwrap(), None);
        assert!(matches!(result, Err(CoreError::HostKeyUnknown { .. })));
        assert!(!file.exists());
    }

    #[test]
    fn reads_openssh_hashed_and_multi_host_entries_and_keeps_other_lines() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("known_hosts");
        let key = blob("ssh-ed25519", b"server");
        let encoded = STANDARD.encode(&key);
        // `ssh-keygen -H` style entry for [example.com]:2222, salt chosen by hand.
        let salt = b"0123456789abcdefghij";
        let mut mac = Hmac::<Sha1>::new_from_slice(salt).unwrap();
        mac.update(b"[example.com]:2222");
        let hashed = format!("|1|{}|{}", STANDARD.encode(salt), STANDARD.encode(mac.finalize().into_bytes()));
        std::fs::write(&file, format!(
            "# comment kept\n{hashed} ssh-ed25519 {encoded}\nalias,plain.example\tssh-ed25519  {encoded} c\n@revoked * ssh-ed25519 {encoded}\n"
        )).unwrap();
        let path = file.to_str().unwrap();
        verify_host_key("example.com", 2222, &key, "ssh-ed25519", path, None).unwrap();
        verify_host_key("plain.example", 22, &key, "ssh-ed25519", path, None).unwrap();
        assert!(matches!(
            verify_host_key("example.com", 22, &key, "ssh-ed25519", path, None),
            Err(CoreError::HostKeyUnknown { .. })
        ));
        let other = blob("ssh-ed25519", b"rotated");
        verify_host_key("plain.example", 22, &other, "ssh-ed25519", path, Some(&host_key_fingerprint(&other))).unwrap();
        let contents = std::fs::read_to_string(&file).unwrap();
        assert!(contents.starts_with("# comment kept\n"));
        assert!(contents.contains("@revoked"));
        assert!(contents.contains(&hashed));
        assert!(!contents.contains("alias,plain.example"));
        assert!(contents.ends_with(&format!("plain.example ssh-ed25519 {} Snake\n", STANDARD.encode(&other))));
    }
}
