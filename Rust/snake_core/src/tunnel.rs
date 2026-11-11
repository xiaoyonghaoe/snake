//! Local port forwarding (`ssh -L`): a listener on 127.0.0.1 whose
//! connections are carried to `remote_host:remote_port` through one SSH
//! connection, plus the saved tunnel definitions.

use super::*;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

/// How often the forwarder checks whether the SSH connection is still alive.
const LIVENESS_INTERVAL: Duration = Duration::from_secs(1);

// MARK: - Saved tunnels

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSshTunnel {
    pub id: String,
    pub profile_id: Option<String>,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    pub note: String,
    pub auto_start: bool,
    pub sort_order: i64,
    /// Unix seconds; ignored when saving.
    pub created_at: i64,
    /// Unix seconds of the last edit; reordering does not count. Ignored when saving.
    pub updated_at: i64,
}

impl SnakeStore {
    fn tunnels(&self) -> Result<Vec<CoreSshTunnel>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, profile_id, local_port, remote_host, remote_port, note, auto_start, sort_order, created_at, updated_at
             FROM ssh_tunnels ORDER BY sort_order, created_at, id",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok(CoreSshTunnel {
                    id: row.get(0)?,
                    profile_id: row.get(1)?,
                    local_port: row.get(2)?,
                    remote_host: row.get(3)?,
                    remote_port: row.get(4)?,
                    note: row.get(5)?,
                    auto_start: row.get(6)?,
                    sort_order: row.get(7)?,
                    created_at: row.get(8)?,
                    updated_at: row.get(9)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn save_tunnel(&self, id: Uuid, profile_id: Option<Uuid>, tunnel: &CoreSshTunnel) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "INSERT INTO ssh_tunnels(id, profile_id, local_port, remote_host, remote_port, note, auto_start, sort_order)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET
                profile_id = excluded.profile_id, local_port = excluded.local_port,
                remote_host = excluded.remote_host, remote_port = excluded.remote_port,
                note = excluded.note, auto_start = excluded.auto_start, sort_order = excluded.sort_order,
                updated_at = CASE WHEN
                    profile_id IS NOT excluded.profile_id OR local_port IS NOT excluded.local_port
                    OR remote_host IS NOT excluded.remote_host OR remote_port IS NOT excluded.remote_port
                    OR note IS NOT excluded.note OR auto_start IS NOT excluded.auto_start
                THEN unixepoch() ELSE updated_at END",
            params![
                id.to_string(),
                profile_id.map(|id| id.to_string()),
                tunnel.local_port,
                tunnel.remote_host,
                tunnel.remote_port,
                tunnel.note,
                tunnel.auto_start,
                tunnel.sort_order,
            ],
        )?;
        Ok(())
    }

    fn delete_tunnel(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute("DELETE FROM ssh_tunnels WHERE id = ?1", params![id.to_string()])?;
        Ok(())
    }
}

#[uniffi::export]
impl CoreDatabase {
    pub fn tunnels(&self) -> Result<Vec<CoreSshTunnel>, CoreError> {
        self.with_store(|store| store.tunnels())
    }

    pub fn save_tunnel(&self, tunnel: CoreSshTunnel) -> Result<(), CoreError> {
        let id = parse_identifier(&tunnel.id)?;
        let profile_id = tunnel.profile_id.as_deref().map(parse_identifier).transpose()?;
        if tunnel.local_port == 0 || tunnel.remote_port == 0 || tunnel.remote_host.trim().is_empty() {
            return Err(CoreError::InvalidInput { message: "tunnel ports and remote host are required".to_owned() });
        }
        self.with_store(|store| store.save_tunnel(id, profile_id, &tunnel))
    }

    pub fn delete_tunnel(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_tunnel(id))
    }
}

// MARK: - Forwarding

#[uniffi::export(callback_interface)]
pub trait CoreTunnelObserver: Send + Sync {
    /// The SSH connection or the listener failed; not called after `stop()`.
    fn on_closed(&self, message: Option<String>);
}

#[derive(uniffi::Object)]
pub struct CoreTunnelHandle {
    stop: watch::Sender<bool>,
    active: Arc<AtomicU32>,
    closed: Arc<AtomicBool>,
    local_port: u16,
}

#[uniffi::export]
impl CoreTunnelHandle {
    /// Closes the listener, every forwarded connection and the SSH connection.
    pub fn stop(&self) {
        self.closed.store(true, Ordering::SeqCst);
        let _ = self.stop.send(true);
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Local connections currently being forwarded.
    pub fn active_connections(&self) -> u32 {
        self.active.load(Ordering::SeqCst)
    }

    /// The bound port; differs from the request only when it asked for 0.
    pub fn local_port(&self) -> u16 {
        self.local_port
    }
}

impl Drop for CoreTunnelHandle {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn start_local_forward_password(
    host: String,
    port: u16,
    username: String,
    password: Vec<u8>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
    observer: Box<dyn CoreTunnelObserver>,
) -> Result<Arc<CoreTunnelHandle>, CoreError> {
    let credential = ssh::Credential::password(password)?;
    start(&host, port, &username, &credential, &known_hosts_path, accept_fingerprint.as_deref(), local_port, remote_host, remote_port, observer)
}

#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn start_local_forward_private_key(
    host: String,
    port: u16,
    username: String,
    private_key_path: String,
    passphrase: Option<Vec<u8>>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
    observer: Box<dyn CoreTunnelObserver>,
) -> Result<Arc<CoreTunnelHandle>, CoreError> {
    let credential = ssh::Credential::private_key(private_key_path, passphrase)?;
    start(&host, port, &username, &credential, &known_hosts_path, accept_fingerprint.as_deref(), local_port, remote_host, remote_port, observer)
}

/// Binds first so a busy port fails without touching the server, then opens
/// a dedicated connection: tunnels outlive terminals and must not share their
/// TCP stream with bulk traffic.
#[allow(clippy::too_many_arguments)]
fn start(
    host: &str,
    port: u16,
    username: &str,
    credential: &ssh::Credential,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
    observer: Box<dyn CoreTunnelObserver>,
) -> Result<Arc<CoreTunnelHandle>, CoreError> {
    let remote_host = remote_host.trim().to_owned();
    if remote_host.is_empty() || remote_port == 0 {
        return Err(CoreError::InvalidInput { message: "tunnel remote host and port are required".to_owned() });
    }
    let listener = bind(local_port)?;
    let bound_port = listener.local_addr().map_err(|error| io_connection_stage_error("tunnel_listen", error))?.port();
    let connection = ssh::connect(host, port, username, credential, known_hosts_path, accept_fingerprint)?;

    let (stop, stop_signal) = watch::channel(false);
    let active = Arc::new(AtomicU32::new(0));
    let closed = Arc::new(AtomicBool::new(false));
    let handle = Arc::new(CoreTunnelHandle { stop, active: Arc::clone(&active), closed: Arc::clone(&closed), local_port: bound_port });
    ssh::runtime().spawn(serve(listener, connection, remote_host, remote_port, active, closed, stop_signal, observer));
    Ok(handle)
}

fn bind(local_port: u16) -> Result<TcpListener, CoreError> {
    ssh::block_on(async {
        // Loopback only: other machines on the network must not reach the server through us.
        TcpListener::bind(("127.0.0.1", local_port)).await
    })
    .map_err(|error| {
        let stage = if error.kind() == std::io::ErrorKind::AddrInUse { "tunnel_port_in_use" } else { "tunnel_listen" };
        io_connection_stage_error(stage, error)
    })
}

#[allow(clippy::too_many_arguments)]
async fn serve(
    listener: TcpListener,
    connection: Arc<ssh::Connection>,
    remote_host: String,
    remote_port: u16,
    active: Arc<AtomicU32>,
    closed: Arc<AtomicBool>,
    mut stop: watch::Receiver<bool>,
    observer: Box<dyn CoreTunnelObserver>,
) {
    let mut liveness = tokio::time::interval(LIVENESS_INTERVAL);
    let failure = loop {
        tokio::select! {
            changed = stop.changed() => {
                // A dropped handle counts as a stop.
                if changed.is_err() || *stop.borrow() { break None; }
            }
            _ = liveness.tick() => {
                if connection.is_closed() { break Some("SSH connection lost".to_owned()); }
            }
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    tokio::spawn(forward(
                        Arc::clone(&connection), stream, peer, remote_host.clone(), remote_port,
                        Arc::clone(&active), stop.clone(),
                    ));
                }
                Err(error) => break Some(error.to_string()),
            },
        }
    };
    drop(listener);
    let stopped = closed.swap(true, Ordering::SeqCst);
    if let Some(message) = failure.filter(|_| !stopped) {
        observer.on_closed(Some(message));
    }
}

async fn forward(
    connection: Arc<ssh::Connection>,
    mut stream: TcpStream,
    peer: SocketAddr,
    remote_host: String,
    remote_port: u16,
    active: Arc<AtomicU32>,
    mut stop: watch::Receiver<bool>,
) {
    let _ = stream.set_nodelay(true);
    // A refused remote port only closes this local connection.
    let Ok(channel) = connection.open_direct_tcpip(&remote_host, remote_port, peer.port()).await else { return };
    active.fetch_add(1, Ordering::SeqCst);
    let mut remote = channel.into_stream();
    tokio::select! {
        _ = tokio::io::copy_bidirectional(&mut stream, &mut remote) => {}
        _ = stop.wait_for(|stopped| *stopped) => {}
    }
    active.fetch_sub(1, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tunnel(port: u16) -> CoreSshTunnel {
        CoreSshTunnel {
            id: Uuid::new_v4().to_string(),
            profile_id: None,
            local_port: port,
            remote_host: "127.0.0.1".into(),
            remote_port: 3306,
            note: "MySQL".into(),
            auto_start: false,
            sort_order: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn tunnels_round_trip_and_updated_at_moves_only_on_real_edits() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let database = CoreDatabase::open(temp.path().to_string_lossy().into_owned()).unwrap();
        let mut saved = tunnel(13306);
        database.save_tunnel(saved.clone()).unwrap();
        let raw = rusqlite::Connection::open(temp.path()).unwrap();
        raw.execute("UPDATE ssh_tunnels SET created_at = 100, updated_at = 200", []).unwrap();
        let stamps = |database: &CoreDatabase| {
            let row = database.tunnels().unwrap().pop().unwrap();
            (row.created_at, row.updated_at)
        };
        saved.sort_order = 5;
        database.save_tunnel(saved.clone()).unwrap();
        assert_eq!(stamps(&database), (100, 200), "reordering is not an edit");
        saved.note = "生产库".into();
        database.save_tunnel(saved.clone()).unwrap();
        let (created, updated) = stamps(&database);
        assert_eq!(created, 100);
        assert!(updated > 200);
        let loaded = database.tunnels().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].note, "生产库");
        assert_eq!(loaded[0].local_port, 13306);
        database.delete_tunnel(saved.id).unwrap();
        assert!(database.tunnels().unwrap().is_empty());
    }

    #[test]
    fn local_ports_are_unique_and_deleting_a_session_unbinds_its_tunnels() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let database = CoreDatabase::open(temp.path().to_string_lossy().into_owned()).unwrap();
        let profile = CoreSshProfile {
            id: Uuid::new_v4().to_string(), group_id: None, name: "db".into(), host: "192.0.2.1".into(), port: 22,
            username: "root".into(), auth_method: CoreAuthMethod::Password, keychain_account: None,
            private_key_bookmark: None, tags: vec![], symbol_name: "server.rack".into(), sort_order: 0,
            saved_password_id: None,
        };
        database.save_profile(profile.clone()).unwrap();
        let bound = CoreSshTunnel { profile_id: Some(profile.id.clone()), ..tunnel(15432) };
        database.save_tunnel(bound.clone()).unwrap();
        assert!(database.save_tunnel(tunnel(15432)).is_err(), "two tunnels cannot share a local port");
        assert!(database.save_tunnel(tunnel(0)).is_err());
        database.delete_profile(profile.id).unwrap();
        let loaded = database.tunnels().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].profile_id, None);
    }

    #[test]
    fn busy_local_port_fails_before_connecting() {
        let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = held.local_addr().unwrap().port();
        match bind(port) {
            Err(CoreError::Connection { stage, .. }) => assert_eq!(stage.as_deref(), Some("tunnel_port_in_use")),
            other => panic!("expected port_in_use, got {:?}", other.map(|_| ())),
        }
    }

    #[test]
    fn saved_password_updated_at_moves_on_metadata_or_touch() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let database = CoreDatabase::open(temp.path().to_string_lossy().into_owned()).unwrap();
        let entry = CoreSavedPassword { id: Uuid::new_v4().to_string(), name: "team".into(), username: "root".into(), created_at: 0, updated_at: 0 };
        database.save_saved_password_and_sync(entry.clone(), vec![], false).unwrap();
        let raw = rusqlite::Connection::open(temp.path()).unwrap();
        let reset = || raw.execute("UPDATE saved_passwords SET created_at = 100, updated_at = 200", []).unwrap();
        let stamps = |database: &CoreDatabase| {
            let row = database.saved_passwords().unwrap().pop().unwrap();
            (row.created_at, row.updated_at)
        };
        reset();
        database.save_saved_password_and_sync(entry.clone(), vec![], false).unwrap();
        assert_eq!(stamps(&database), (100, 200), "saving unchanged metadata is not an edit");
        database.touch_saved_password(entry.id.clone()).unwrap();
        assert!(stamps(&database).1 > 200);
        reset();
        database.save_saved_password_and_sync(CoreSavedPassword { username: "admin".into(), ..entry }, vec![], false).unwrap();
        let (created, updated) = stamps(&database);
        assert_eq!(created, 100);
        assert!(updated > 200);
    }
}
