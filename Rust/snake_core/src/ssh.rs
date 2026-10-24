//! SSH transport built on russh: one tokio runtime, host-key verification,
//! authentication, exec channels and the shared connection pool.
//!
//! UniFFI entry points stay synchronous. Swift already calls them from
//! background threads, so each call blocks on the shared runtime; long-lived
//! work (terminal IO, keepalive) runs as tasks on that runtime.

use super::*;
use russh::client;
use russh::keys::{HashAlg, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{cipher, compression, kex, mac, ChannelMsg, Disconnect};
use std::collections::HashMap;
use std::future::Future;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Unused pooled connections stay open this long for quick new tabs.
const POOL_IDLE_GRACE: Duration = Duration::from_secs(30);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);

pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .thread_name("snake-ssh")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Runs async SSH work from a synchronous FFI call. Never call this from a
/// runtime worker thread.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    runtime().block_on(future)
}

/// Transport or SFTP failure text, the replacement for `ssh2::Error`.
#[derive(Debug, Clone)]
pub(crate) struct SshError(pub(crate) String);

impl SshError {
    pub(crate) fn message(&self) -> &str {
        &self.0
    }
}

impl From<russh::Error> for SshError {
    fn from(error: russh::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<russh_sftp::client::error::Error> for SshError {
    fn from(error: russh_sftp::client::error::Error) -> Self {
        match error {
            russh_sftp::client::error::Error::Status(status) if !status.error_message.is_empty() => {
                Self(status.error_message)
            }
            other => Self(other.to_string()),
        }
    }
}

impl From<std::io::Error> for SshError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<SshError> for std::io::Error {
    fn from(error: SshError) -> Self {
        std::io::Error::other(error.0)
    }
}

fn client_config() -> Arc<client::Config> {
    static CONFIG: OnceLock<Arc<client::Config>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            // Defaults first, then algorithms libssh2 also offered so older
            // servers keep working. AES-GCM leads: it is hardware accelerated
            // on Apple Silicon. Compression stays off, as with libssh2.
            let mut kex = russh::Preferred::DEFAULT.kex.to_vec();
            kex.extend([kex::ECDH_SHA2_NISTP256, kex::ECDH_SHA2_NISTP384, kex::ECDH_SHA2_NISTP521, kex::DH_G14_SHA1]);
            let mut mac = russh::Preferred::DEFAULT.mac.to_vec();
            mac.extend([mac::HMAC_SHA1_ETM, mac::HMAC_SHA1]);
            Arc::new(client::Config {
                keepalive_interval: Some(KEEPALIVE_INTERVAL),
                keepalive_max: 3,
                nodelay: true,
                preferred: russh::Preferred {
                    kex: kex.into(),
                    cipher: vec![
                        cipher::AES_256_GCM,
                        cipher::AES_128_GCM,
                        cipher::CHACHA20_POLY1305,
                        cipher::AES_256_CTR,
                        cipher::AES_192_CTR,
                        cipher::AES_128_CTR,
                        cipher::AES_256_CBC,
                        cipher::AES_128_CBC,
                    ]
                    .into(),
                    mac: mac.into(),
                    compression: vec![compression::NONE].into(),
                    ..russh::Preferred::DEFAULT
                },
                ..Default::default()
            })
        })
        .clone()
}

#[derive(Default)]
struct HandshakeState {
    host_key: Option<Vec<u8>>,
    verdict: Option<CoreError>,
    names: Option<[String; 5]>,
}

pub(crate) struct ClientHandler {
    host: String,
    port: u16,
    /// `None` probes the key without trusting or storing anything.
    known_hosts_path: Option<String>,
    accept_fingerprint: Option<String>,
    state: Arc<Mutex<HandshakeState>>,
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let PublicKeyOrCertificate::PublicKey { key, .. } = key else {
            return Ok(false);
        };
        let blob = key.to_bytes().map_err(|_| russh::Error::KexInit)?;
        let algorithm = key.algorithm().as_str().to_owned();
        let verdict = self.known_hosts_path.as_deref().map(|path| {
            known_hosts::verify_host_key(&self.host, self.port, &blob, &algorithm, path, self.accept_fingerprint.as_deref())
        });
        let mut state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.host_key = Some(blob);
        match verdict {
            Some(Ok(())) => Ok(true),
            Some(Err(error)) => {
                state.verdict = Some(error);
                Ok(false)
            }
            None => Ok(false),
        }
    }

    async fn kex_done(
        &mut self,
        _shared_secret: Option<&[u8]>,
        names: &russh::Names,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let mut state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.names = Some([
            names.kex.as_ref().to_owned(),
            names.key.to_string(),
            names.cipher.as_ref().to_owned(),
            names.client_mac.as_ref().to_owned(),
            names.server_mac.as_ref().to_owned(),
        ]);
        Ok(())
    }
}

pub(crate) enum Credential {
    Password(Zeroizing<String>),
    PrivateKey { path: String, passphrase: Option<Zeroizing<String>> },
}

impl Credential {
    pub(crate) fn password(bytes: Vec<u8>) -> Result<Self, CoreError> {
        let password = Zeroizing::new(bytes);
        let text = std::str::from_utf8(&password).map_err(|_| CoreError::Authentication {
            message: String::new(),
            stage: Some("auth_password_encoding_invalid".to_owned()),
        })?;
        Ok(Self::Password(Zeroizing::new(text.to_owned())))
    }

    pub(crate) fn private_key(path: String, passphrase: Option<Vec<u8>>) -> Result<Self, CoreError> {
        let passphrase = passphrase
            .map(|bytes| {
                let bytes = Zeroizing::new(bytes);
                std::str::from_utf8(&bytes).map(|text| Zeroizing::new(text.to_owned()))
            })
            .transpose()
            .map_err(|_| CoreError::Authentication {
                message: String::new(),
                stage: Some("auth_private_key_passphrase_invalid".to_owned()),
            })?;
        Ok(Self::PrivateKey { path, passphrase })
    }

    /// Identifies the secret without storing it, so pooled connections are
    /// never shared between different credentials.
    fn digest(&self, username: &str) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(username.as_bytes());
        hasher.update([0]);
        match self {
            Self::Password(password) => {
                hasher.update(b"password\0");
                hasher.update(password.as_bytes());
            }
            Self::PrivateKey { path, passphrase } => {
                hasher.update(b"key\0");
                hasher.update(path.as_bytes());
                hasher.update([0]);
                hasher.update(passphrase.as_deref().map(String::as_bytes).unwrap_or_default());
            }
        }
        hasher.finalize().into()
    }
}

/// An authenticated SSH connection. Channels opened from it are independent;
/// it closes when the last owner drops it (pooled ones after a grace period).
pub(crate) struct Connection {
    /// Always `Some` until `Drop` takes it to disconnect in the background.
    handle: Option<client::Handle<ClientHandler>>,
    pub(crate) security: CoreConnectionSecurity,
    pub(crate) server_address: std::net::SocketAddr,
}

impl Connection {
    fn handle(&self) -> &client::Handle<ClientHandler> {
        self.handle.as_ref().expect("connection handle is present until drop")
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.handle().is_closed()
    }

    pub(crate) async fn open_session(&self) -> Result<russh::Channel<client::Msg>, CoreError> {
        self.handle()
            .channel_open_session()
            .await
            .map_err(|error| ssh_connection_stage_error("ssh_channel", error.into()))
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // Best effort: an orderly disconnect lets sshd clean up immediately.
        if let Some(handle) = self.handle.take().filter(|handle| !handle.is_closed()) {
            runtime().spawn(async move {
                let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
            });
        }
    }
}

struct Handshake {
    handle: client::Handle<ClientHandler>,
    host_key: Vec<u8>,
    names: Option<[String; 5]>,
    server_address: std::net::SocketAddr,
}

/// TCP connect, SSH handshake and host-key verification.
async fn handshake(
    host: &str,
    port: u16,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<Handshake, CoreError> {
    if host.trim().is_empty() || port == 0 {
        return Err(CoreError::InvalidInput { message: "host and port are required".to_owned() });
    }
    let (host_owned, connect_host) = (host.to_owned(), host.to_owned());
    let stream = tokio::task::spawn_blocking(move || connect_tcp(&connect_host, port))
        .await
        .map_err(|error| io_connection_stage_error("tcp_connect", std::io::Error::other(error)))??;
    tune_terminal_socket(&stream);
    let server_address = stream.peer_addr().map_err(|error| io_connection_stage_error("tcp_stream", error))?;
    stream.set_nonblocking(true).map_err(|error| io_connection_stage_error("tcp_stream", error))?;
    let stream = tokio::net::TcpStream::from_std(stream).map_err(|error| io_connection_stage_error("tcp_stream", error))?;

    let state = Arc::new(Mutex::new(HandshakeState::default()));
    let handler = ClientHandler {
        host: host_owned,
        port,
        known_hosts_path: Some(known_hosts_path.to_owned()),
        accept_fingerprint: accept_fingerprint.map(str::to_owned),
        state: Arc::clone(&state),
    };
    let result = tokio::time::timeout(Duration::from_secs(20), client::connect_stream(client_config(), stream, handler)).await;
    let mut state = std::mem::take(&mut *state.lock().unwrap_or_else(|poison| poison.into_inner()));
    if let Some(verdict) = state.verdict.take() {
        return Err(verdict);
    }
    let handle = match result {
        Ok(Ok(handle)) => handle,
        Ok(Err(error)) => return Err(ssh_connection_stage_error("ssh_handshake", error.into())),
        Err(_) => {
            return Err(ssh_connection_stage_error("ssh_handshake", SshError("handshake timed out".to_owned())))
        }
    };
    let host_key = state.host_key.take().ok_or_else(missing_host_key)?;
    Ok(Handshake { handle, host_key, names: state.names.take(), server_address })
}

fn missing_host_key() -> CoreError {
    CoreError::Connection { message: String::new(), stage: Some("ssh_host_key_missing".to_owned()) }
}

/// Connects only far enough to read the server's host key.
pub(crate) fn probe(host: &str, port: u16) -> Result<CoreHostKey, CoreError> {
    block_on(async {
        let (host_owned, connect_host) = (host.to_owned(), host.to_owned());
        if host.trim().is_empty() || port == 0 {
            return Err(CoreError::InvalidInput { message: "host and port are required".to_owned() });
        }
        let stream = tokio::task::spawn_blocking(move || connect_tcp(&connect_host, port))
            .await
            .map_err(|error| io_connection_stage_error("tcp_connect", std::io::Error::other(error)))??;
        stream.set_nonblocking(true).map_err(|error| io_connection_stage_error("tcp_stream", error))?;
        let stream = tokio::net::TcpStream::from_std(stream).map_err(|error| io_connection_stage_error("tcp_stream", error))?;
        let state = Arc::new(Mutex::new(HandshakeState::default()));
        let handler = ClientHandler {
            host: host_owned,
            port,
            known_hosts_path: None,
            accept_fingerprint: None,
            state: Arc::clone(&state),
        };
        let result = tokio::time::timeout(Duration::from_secs(20), client::connect_stream(client_config(), stream, handler)).await;
        let key = state.lock().unwrap_or_else(|poison| poison.into_inner()).host_key.take();
        match (key, result) {
            (Some(key), _) => Ok(known_hosts::host_key_record(host, port, &key)),
            (None, Ok(Err(error))) => Err(ssh_connection_stage_error("ssh_handshake", error.into())),
            (None, Err(_)) => Err(ssh_connection_stage_error("ssh_handshake", SshError("handshake timed out".to_owned()))),
            (None, Ok(Ok(_))) => Err(missing_host_key()),
        }
    })
}

async fn authenticate(handle: &mut client::Handle<ClientHandler>, username: &str, credential: &Credential) -> Result<(), CoreError> {
    let (result, stage) = match credential {
        Credential::Password(password) => (
            handle.authenticate_password(username, password.as_str()).await,
            "auth_password",
        ),
        Credential::PrivateKey { path, passphrase } => {
            let key = russh::keys::load_secret_key(path, passphrase.as_deref().map(String::as_str))
                .map_err(|error| CoreError::Authentication { message: error.to_string(), stage: Some("auth_private_key".to_owned()) })?;
            // Old servers without server-sig-algs only understand ssh-rsa (SHA-1).
            let hash: Option<HashAlg> = match handle.best_supported_rsa_hash().await {
                Ok(Some(hash)) => hash,
                _ => None,
            };
            (
                handle.authenticate_publickey(username, PrivateKeyWithHashAlg::new(Arc::new(key), hash)).await,
                "auth_private_key",
            )
        }
    };
    match result {
        Ok(outcome) if outcome.success() => Ok(()),
        Ok(_) => Err(CoreError::Authentication {
            message: "server rejected the supplied credential".to_owned(),
            stage: Some(stage.to_owned()),
        }),
        Err(error) => Err(CoreError::Authentication { message: error.to_string(), stage: Some(stage.to_owned()) }),
    }
}

/// Opens a new authenticated connection that is never shared.
pub(crate) fn connect(
    host: &str,
    port: u16,
    username: &str,
    credential: &Credential,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<Arc<Connection>, CoreError> {
    block_on(connect_async(host, port, username, credential, known_hosts_path, accept_fingerprint))
}

async fn connect_async(
    host: &str,
    port: u16,
    username: &str,
    credential: &Credential,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<Arc<Connection>, CoreError> {
    let Handshake { mut handle, host_key, names, server_address } =
        handshake(host, port, known_hosts_path, accept_fingerprint).await?;
    authenticate(&mut handle, username, credential).await?;
    let [kex, key, cipher, mut client_mac, mut server_mac] = names.unwrap_or_default();
    // AEAD ciphers authenticate themselves; the negotiated MAC is unused.
    if cipher.contains("gcm") || cipher.contains("poly1305") {
        (client_mac, server_mac) = (String::new(), String::new());
    }
    let security = connection_security_from_methods(
        &key,
        &known_hosts::host_key_fingerprint(&host_key),
        Some(&kex),
        Some(&cipher),
        Some(&cipher),
        Some(&client_mac),
        Some(&server_mac),
    );
    Ok(Arc::new(Connection { handle: Some(handle), security, server_address }))
}

// MARK: - Pool

#[derive(Clone, PartialEq, Eq, Hash)]
struct PoolKey {
    host: String,
    port: u16,
    credential: [u8; 32],
}

struct PoolEntry {
    connection: Arc<Connection>,
    last_in_use: Instant,
}

fn pool() -> &'static Mutex<HashMap<PoolKey, PoolEntry>> {
    static POOL: OnceLock<Mutex<HashMap<PoolKey, PoolEntry>>> = OnceLock::new();
    POOL.get_or_init(|| {
        runtime().spawn(async {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                sweep_pool(Instant::now());
            }
        });
        Mutex::new(HashMap::new())
    })
}

/// Drops connections that died or have had no other owner for the grace period.
fn sweep_pool(now: Instant) {
    let Ok(mut entries) = pool().lock() else { return };
    entries.retain(|_, entry| {
        if entry.connection.is_closed() {
            return false;
        }
        if Arc::strong_count(&entry.connection) > 1 {
            entry.last_in_use = now;
            return true;
        }
        now.duration_since(entry.last_in_use) < POOL_IDLE_GRACE
    });
}

/// Returns a live pooled connection for the same endpoint and credential, or
/// opens one. Host keys are only checked on the first connection; changing
/// trust (`accept_fingerprint`) always opens a fresh, unpooled connection.
pub(crate) fn shared(
    host: &str,
    port: u16,
    username: &str,
    credential: &Credential,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<Arc<Connection>, CoreError> {
    if accept_fingerprint.is_some() {
        return connect(host, port, username, credential, known_hosts_path, accept_fingerprint);
    }
    let key = PoolKey { host: host.to_ascii_lowercase(), port, credential: credential.digest(username) };
    if let Some(existing) = pool()
        .lock()
        .map_err(|_| CoreError::StorageLock)?
        .get_mut(&key)
        .filter(|entry| !entry.connection.is_closed())
    {
        existing.last_in_use = Instant::now();
        return Ok(Arc::clone(&existing.connection));
    }
    let connection = connect(host, port, username, credential, known_hosts_path, None)?;
    let mut entries = pool().lock().map_err(|_| CoreError::StorageLock)?;
    // Another caller may have connected meanwhile; keep the first live one.
    let entry = entries.entry(key).or_insert_with(|| PoolEntry { connection: Arc::clone(&connection), last_in_use: Instant::now() });
    if entry.connection.is_closed() {
        *entry = PoolEntry { connection: Arc::clone(&connection), last_in_use: Instant::now() };
    }
    Ok(Arc::clone(&entry.connection))
}

// MARK: - Exec

pub(crate) struct ExecOutput {
    pub(crate) exit_status: Option<u32>,
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) stdout_total: u64,
    pub(crate) stderr_total: u64,
    pub(crate) timed_out: bool,
    /// The server refused the exec request (for example an SFTP-only account).
    pub(crate) denied: bool,
}

pub(crate) struct ExecOptions<'a> {
    pub(crate) stdin: Option<&'a [u8]>,
    pub(crate) limit: usize,
    pub(crate) deadline: Option<Instant>,
    pub(crate) merge_stderr: bool,
    pub(crate) control: Option<&'a CoreTransferControl>,
}

impl Default for ExecOptions<'_> {
    fn default() -> Self {
        Self { stdin: None, limit: usize::MAX, deadline: None, merge_stderr: false, control: None }
    }
}

/// Pause/cancel without blocking a runtime worker.
pub(crate) async fn checkpoint(control: &CoreTransferControl) -> Result<(), CoreError> {
    loop {
        match control.state.load(Ordering::Acquire) {
            0 => return Ok(()),
            1 => tokio::time::sleep(Duration::from_millis(40)).await,
            _ => return Err(CoreError::TransferCancelled),
        }
    }
}

/// Runs one command on a new exec channel and collects its output. On a
/// deadline the channel is closed and `timed_out` is set; the caller decides
/// whether the remote process needs to be stopped explicitly.
pub(crate) async fn exec(connection: &Connection, command: &str, options: ExecOptions<'_>) -> Result<ExecOutput, CoreError> {
    let mut channel = connection.open_session().await?;
    channel
        .exec(true, command)
        .await
        .map_err(|error| ssh_connection_stage_error("ssh_exec", error.into()))?;
    let mut output = ExecOutput {
        exit_status: None,
        stdout: Vec::new(),
        stderr: Vec::new(),
        stdout_total: 0,
        stderr_total: 0,
        timed_out: false,
        denied: false,
    };
    // The first reply to `want_reply` says whether sshd accepted the request.
    let mut confirmed = false;
    let mut stdin_sent = options.stdin.is_none();
    loop {
        if confirmed && !stdin_sent {
            stdin_sent = true;
            if let Some(stdin) = options.stdin {
                channel.data_bytes(stdin.to_vec()).await.map_err(|error| connection_error(error.into()))?;
            }
            channel.eof().await.map_err(|error| connection_error(error.into()))?;
        }
        if let Some(control) = options.control {
            if let Err(error) = checkpoint(control).await {
                let _ = channel.close().await;
                return Err(error);
            }
        }
        let wait = async {
            match options.deadline {
                Some(deadline) => tokio::time::timeout_at(deadline.into(), channel.wait()).await.ok(),
                None => Some(channel.wait().await),
            }
        };
        // Wake periodically so pause/cancel stays responsive.
        let message = match tokio::time::timeout(Duration::from_millis(200), wait).await {
            Err(_) => continue,
            Ok(None) => {
                output.timed_out = true;
                let _ = channel.close().await;
                return Ok(output);
            }
            Ok(Some(message)) => message,
        };
        match message {
            Some(ChannelMsg::Success) => confirmed = true,
            Some(ChannelMsg::Failure) if !confirmed => {
                output.denied = true;
                return Ok(output);
            }
            Some(ChannelMsg::Data { data }) => {
                append(&mut output.stdout, &mut output.stdout_total, &data, options.limit);
                confirmed = true;
            }
            Some(ChannelMsg::ExtendedData { data, .. }) => {
                let (kept, total) = if options.merge_stderr {
                    (&mut output.stdout, &mut output.stdout_total)
                } else {
                    (&mut output.stderr, &mut output.stderr_total)
                };
                append(kept, total, &data, options.limit);
                confirmed = true;
            }
            Some(ChannelMsg::ExitStatus { exit_status }) => output.exit_status = Some(exit_status),
            Some(ChannelMsg::ExitSignal { .. }) => output.exit_status = output.exit_status.or(Some(255)),
            Some(ChannelMsg::Close) | None => return Ok(output),
            Some(_) => {}
        }
    }
}

fn append(kept: &mut Vec<u8>, total: &mut u64, data: &[u8], limit: usize) {
    *total += data.len() as u64;
    let room = limit.saturating_sub(kept.len());
    kept.extend_from_slice(&data[..data.len().min(room)]);
}
