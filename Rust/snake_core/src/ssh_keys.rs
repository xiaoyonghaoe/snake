//! Private keys for Snake's key library: imported keys are checked, decrypted
//! with their passphrase and stored again in OpenSSH format (re-encrypted with
//! the same passphrase), so terminals, SFTP and the system `ssh` behind SSHFS
//! all read the one file Snake keeps.

use super::*;
use russh::keys::ssh_key::LineEnding;
use russh::keys::{Algorithm, HashAlg, PrivateKey};

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSshKey {
    /// OpenSSH private key text, encrypted when a passphrase was given.
    pub private_key: String,
    pub algorithm: String,
    /// `SHA256:…`, as `ssh-keygen -l` prints it.
    pub fingerprint: String,
    /// One `authorized_keys` line.
    pub public_key: String,
    pub encrypted: bool,
}

/// Stable codes the Swift layer turns into localized messages.
fn key_error(code: &str) -> CoreError {
    CoreError::InvalidInput { message: code.to_owned() }
}

fn describe(key: &PrivateKey, passphrase: Option<&str>) -> Result<CoreSshKey, CoreError> {
    let public_key = key.public_key().to_openssh().map_err(|_| key_error("unrecognized_key"))?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    let algorithm = key.algorithm().as_str().to_owned();
    let stored = match passphrase {
        Some(passphrase) => key
            .encrypt(&mut rand::rng(), passphrase)
            .map_err(|_| key_error("unrecognized_key"))?,
        None => key.clone(),
    };
    let private_key = stored.to_openssh(LineEnding::LF).map_err(|_| key_error("unrecognized_key"))?;
    Ok(CoreSshKey {
        private_key: private_key.to_string(),
        algorithm,
        fingerprint,
        public_key,
        encrypted: passphrase.is_some(),
    })
}

/// Accepts OpenSSH, PEM (PKCS#1/#8) and PuTTY keys. A passphrase given for an
/// unencrypted key is ignored rather than added.
#[uniffi::export]
pub fn import_private_key(content: String, passphrase: Option<String>) -> Result<CoreSshKey, CoreError> {
    let content = zeroize::Zeroizing::new(content);
    let passphrase = passphrase.filter(|value| !value.is_empty()).map(zeroize::Zeroizing::new);
    match russh::keys::decode_secret_key(&content, None) {
        Ok(key) => describe(&key, None),
        Err(russh::keys::Error::KeyIsEncrypted) => {
            let Some(passphrase) = passphrase else { return Err(key_error("passphrase_required")) };
            let key = russh::keys::decode_secret_key(&content, Some(passphrase.as_str()))
                .map_err(|_| key_error("passphrase_incorrect"))?;
            describe(&key, Some(passphrase.as_str()))
        }
        Err(_) => Err(key_error("unrecognized_key")),
    }
}

/// A new Ed25519 key pair, the default `ssh-keygen` now uses.
#[uniffi::export]
pub fn generate_ed25519_key(comment: String, passphrase: Option<String>) -> Result<CoreSshKey, CoreError> {
    let mut key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).map_err(|_| key_error("generation_failed"))?;
    key.set_comment(comment);
    let passphrase = passphrase.filter(|value| !value.is_empty()).map(zeroize::Zeroizing::new);
    describe(&key, passphrase.as_deref().map(String::as_str))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_keys_round_trip_with_and_without_passphrase() {
        let plain = generate_ed25519_key("snake@test".into(), None).unwrap();
        assert!(!plain.encrypted);
        assert_eq!(plain.algorithm, "ssh-ed25519");
        assert!(plain.fingerprint.starts_with("SHA256:"));
        assert!(plain.public_key.starts_with("ssh-ed25519 ") && plain.public_key.ends_with(" snake@test"));
        let reimported = import_private_key(plain.private_key.clone(), None).unwrap();
        assert_eq!(reimported.fingerprint, plain.fingerprint);

        let locked = generate_ed25519_key("locked".into(), Some("pass phrase".into())).unwrap();
        assert!(locked.encrypted);
        assert!(matches!(import_private_key(locked.private_key.clone(), None),
                         Err(CoreError::InvalidInput { message }) if message == "passphrase_required"));
        assert!(matches!(import_private_key(locked.private_key.clone(), Some("wrong".into())),
                         Err(CoreError::InvalidInput { message }) if message == "passphrase_incorrect"));
        let unlocked = import_private_key(locked.private_key.clone(), Some("pass phrase".into())).unwrap();
        assert_eq!(unlocked.fingerprint, locked.fingerprint);
        assert!(unlocked.encrypted, "re-stored with the same passphrase");
        // The stored text is what ssh and russh read from disk.
        assert!(russh::keys::decode_secret_key(&unlocked.private_key, Some("pass phrase")).is_ok());
    }

    #[test]
    fn rejects_text_that_is_not_a_private_key() {
        assert!(matches!(import_private_key("ssh-ed25519 AAAA not-a-private-key".into(), None),
                         Err(CoreError::InvalidInput { message }) if message == "unrecognized_key"));
    }
}
