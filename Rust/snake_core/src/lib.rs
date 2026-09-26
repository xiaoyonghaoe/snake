//! Snake core owns durable, non-secret configuration. Credentials remain in macOS Keychain.

use base64::{engine::general_purpose::STANDARD, Engine};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ssh2::{
    Channel, CheckResult, ErrorCode, ExtendedData, FileStat, HostKeyType, KnownHostFileKind,
    MethodType, OpenFlags, OpenType, Session, Sftp,
};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

uniffi::setup_scaffolding!("snake_core");

mod transfer_integrity;
pub use transfer_integrity::*;

#[derive(Debug, Error)]
pub enum SnakeCoreError {
    #[error("storage error: {0}")]
    Storage(#[from] rusqlite::Error),
    #[error("invalid SSH port: {0}")]
    InvalidPort(u16),
    #[error("profile field `{0}` cannot be empty")]
    EmptyField(&'static str),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuthMethod {
    Password,
    PrivateKey,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionGroup {
    pub id: Uuid,
    pub name: String,
    pub sort_order: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshProfile {
    pub id: Uuid,
    pub group_id: Option<Uuid>,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: AuthMethod,
    /// Account/reference only; never secret bytes.
    pub keychain_account: Option<String>,
    /// Security-scoped bookmark bytes, not private-key contents.
    pub private_key_bookmark: Option<Vec<u8>>,
    pub tags_json: String,
    pub symbol_name: String,
    pub sort_order: i64,
    /// Optional metadata link; the copied password lives in the profile's own account.
    pub saved_password_id: Option<Uuid>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedPasswordRecord {
    pub id: Uuid,
    pub name: String,
    pub username: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransferJobRecord {
    pub id: Uuid,
    pub source_profile_snapshot: String,
    pub target_profile_snapshot: String,
    pub source_path: String,
    pub target_path: String,
    pub total_bytes: i64,
    pub completed_bytes: i64,
    pub state: String,
    pub error_message: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MountMappingRecord {
    pub id: Uuid,
    pub profile_id: Option<Uuid>,
    pub profile_snapshot: String,
    pub name: String,
    pub remote_path: String,
    pub user_access_path: String,
    pub managed_mount_path: String,
    pub auto_mount: bool,
    pub enabled: bool,
    pub last_error: Option<String>,
}

impl SshProfile {
    pub fn validate(&self) -> Result<(), SnakeCoreError> {
        for (name, value) in [
            ("name", self.name.trim()),
            ("host", self.host.trim()),
            ("username", self.username.trim()),
        ] {
            if value.is_empty() {
                return Err(SnakeCoreError::EmptyField(name));
            }
        }
        if self.port == 0 {
            return Err(SnakeCoreError::InvalidPort(self.port));
        }
        Ok(())
    }
}

pub struct SnakeStore {
    connection: Connection,
}

impl SnakeStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SnakeCoreError> {
        let connection = Connection::open(path)?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<(), SnakeCoreError> {
        self.connection.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS session_groups (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS ssh_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                group_id TEXT REFERENCES session_groups(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL CHECK(port BETWEEN 1 AND 65535),
                username TEXT NOT NULL,
                auth_method TEXT NOT NULL CHECK(auth_method IN ('password', 'private_key')),
                keychain_account TEXT,
                private_key_bookmark BLOB,
                tags_json TEXT NOT NULL DEFAULT '[]',
                symbol_name TEXT NOT NULL DEFAULT 'server.rack',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS known_hosts (
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                algorithm TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                public_key BLOB NOT NULL,
                accepted_at INTEGER NOT NULL DEFAULT (unixepoch()),
                PRIMARY KEY(host, port)
            );
            CREATE TABLE IF NOT EXISTS transfer_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                source_profile_id TEXT,
                target_profile_id TEXT,
                source_profile_snapshot TEXT NOT NULL,
                target_profile_snapshot TEXT NOT NULL,
                source_path TEXT NOT NULL,
                target_path TEXT NOT NULL,
                entry_kind TEXT NOT NULL,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                completed_bytes INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                conflict_policy TEXT NOT NULL DEFAULT 'ask',
                error_message TEXT,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS transfer_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                job_id TEXT NOT NULL REFERENCES transfer_jobs(id) ON DELETE CASCADE,
                state TEXT NOT NULL,
                message TEXT,
                created_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS mount_mappings (
                id TEXT PRIMARY KEY NOT NULL,
                profile_id TEXT,
                profile_snapshot TEXT NOT NULL,
                name TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                user_access_path TEXT NOT NULL,
                managed_mount_path TEXT NOT NULL,
                auto_mount INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                last_error TEXT,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS saved_passwords (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                username TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
            UPDATE transfer_jobs SET state = 'interrupted', updated_at = unixepoch()
            WHERE state IN ('queued', 'scanning', 'running');
            ",
        )?;
        let has_saved_password_id = self.connection
            .prepare("PRAGMA table_info(ssh_profiles)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .any(|name| name.as_deref() == Ok("saved_password_id"));
        if !has_saved_password_id {
            self.connection.execute_batch("ALTER TABLE ssh_profiles ADD COLUMN saved_password_id TEXT REFERENCES saved_passwords(id) ON DELETE SET NULL")?;
        }
        self.connection.execute("INSERT OR IGNORE INTO schema_migrations(version) VALUES (2)", [])?;
        Ok(())
    }

    pub fn save_group(&self, group: &SessionGroup) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "INSERT INTO session_groups(id, name, sort_order) VALUES(?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, sort_order = excluded.sort_order, updated_at = unixepoch()",
            params![group.id.to_string(), group.name, group.sort_order],
        )?;
        Ok(())
    }

    pub fn groups(&self) -> Result<Vec<SessionGroup>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, name, sort_order FROM session_groups ORDER BY sort_order, name COLLATE NOCASE",
        )?;
        let groups = statement
            .query_map([], |row| {
                Ok(SessionGroup {
                    id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                    name: row.get(1)?,
                    sort_order: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(groups)
    }

    pub fn save_profile(&self, profile: &SshProfile) -> Result<(), SnakeCoreError> {
        profile.validate()?;
        let auth_method = match profile.auth_method {
            AuthMethod::Password => "password",
            AuthMethod::PrivateKey => "private_key",
        };
        self.connection.execute(
            "INSERT INTO ssh_profiles(id, group_id, name, host, port, username, auth_method, keychain_account, private_key_bookmark, tags_json, symbol_name, sort_order, saved_password_id)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(id) DO UPDATE SET
                group_id = excluded.group_id, name = excluded.name, host = excluded.host, port = excluded.port,
                username = excluded.username, auth_method = excluded.auth_method, keychain_account = excluded.keychain_account,
                private_key_bookmark = excluded.private_key_bookmark, tags_json = excluded.tags_json,
                symbol_name = excluded.symbol_name, sort_order = excluded.sort_order,
                saved_password_id = excluded.saved_password_id,
                updated_at = unixepoch()",
            params![
                profile.id.to_string(),
                profile.group_id.map(|id| id.to_string()),
                profile.name,
                profile.host,
                profile.port,
                profile.username,
                auth_method,
                profile.keychain_account,
                profile.private_key_bookmark,
                profile.tags_json,
                profile.symbol_name,
                profile.sort_order,
                profile.saved_password_id.map(|id| id.to_string()),
            ],
        )?;
        Ok(())
    }

    pub fn profile(&self, id: Uuid) -> Result<Option<SshProfile>, SnakeCoreError> {
        self.connection.query_row(
            "SELECT id, group_id, name, host, port, username, auth_method, keychain_account, private_key_bookmark, tags_json, symbol_name, sort_order, saved_password_id
             FROM ssh_profiles WHERE id = ?1",
            params![id.to_string()],
            |row| {
                let method: String = row.get(6)?;
                Ok(SshProfile {
                    id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                    group_id: row.get::<_, Option<String>>(1)?.and_then(|value| Uuid::parse_str(&value).ok()),
                    name: row.get(2)?,
                    host: row.get(3)?,
                    port: row.get(4)?,
                    username: row.get(5)?,
                    auth_method: if method == "private_key" { AuthMethod::PrivateKey } else { AuthMethod::Password },
                    keychain_account: row.get(7)?,
                    private_key_bookmark: row.get(8)?,
                    tags_json: row.get(9)?,
                    symbol_name: row.get(10)?,
                    sort_order: row.get(11)?,
                    saved_password_id: row.get::<_, Option<String>>(12)?.and_then(|value| Uuid::parse_str(&value).ok()),
                })
            },
        ).optional().map_err(Into::into)
    }

    pub fn profiles(&self) -> Result<Vec<SshProfile>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, group_id, name, host, port, username, auth_method, keychain_account, private_key_bookmark, tags_json, symbol_name, sort_order, saved_password_id
             FROM ssh_profiles ORDER BY sort_order, name COLLATE NOCASE",
        )?;
        let profiles = statement
            .query_map([], |row| {
                let method: String = row.get(6)?;
                Ok(SshProfile {
                    id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                    group_id: row
                        .get::<_, Option<String>>(1)?
                        .and_then(|value| Uuid::parse_str(&value).ok()),
                    name: row.get(2)?,
                    host: row.get(3)?,
                    port: row.get(4)?,
                    username: row.get(5)?,
                    auth_method: if method == "private_key" {
                        AuthMethod::PrivateKey
                    } else {
                        AuthMethod::Password
                    },
                    keychain_account: row.get(7)?,
                    private_key_bookmark: row.get(8)?,
                    tags_json: row.get(9)?,
                    symbol_name: row.get(10)?,
                    sort_order: row.get(11)?,
                    saved_password_id: row.get::<_, Option<String>>(12)?.and_then(|value| Uuid::parse_str(&value).ok()),
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(profiles)
    }

    pub fn delete_group(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "DELETE FROM session_groups WHERE id = ?1",
            params![id.to_string()],
        )?;
        Ok(())
    }

    pub fn delete_profile(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "DELETE FROM ssh_profiles WHERE id = ?1",
            params![id.to_string()],
        )?;
        Ok(())
    }

    pub fn saved_passwords(&self) -> Result<Vec<SavedPasswordRecord>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, name, username FROM saved_passwords ORDER BY name COLLATE NOCASE, id",
        )?;
        let records = statement.query_map([], |row| {
            Ok(SavedPasswordRecord {
                id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                name: row.get(1)?,
                username: row.get(2)?,
            })
        })?.collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    /// One SQLite transaction for metadata and selected, still-linked profiles.
    /// Credentials are coordinated by Swift and are never passed to this method.
    pub fn save_saved_password_and_sync(
        &self,
        record: &SavedPasswordRecord,
        selected: &[Uuid],
        sync_username: bool,
    ) -> Result<Vec<Uuid>, SnakeCoreError> {
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO saved_passwords(id, name, username) VALUES(?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, username=excluded.username, updated_at=unixepoch()",
            params![record.id.to_string(), record.name, record.username],
        )?;
        let mut updated = Vec::new();
        for id in selected {
            let changed = transaction.execute(
                "UPDATE ssh_profiles SET username = CASE WHEN ?3 THEN ?4 ELSE username END, updated_at=unixepoch()
                 WHERE id=?1 AND saved_password_id=?2 AND auth_method='password'",
                params![id.to_string(), record.id.to_string(), sync_username, record.username],
            )?;
            if changed != 1 {
                return Err(SnakeCoreError::Storage(rusqlite::Error::QueryReturnedNoRows));
            }
            updated.push(*id);
        }
        transaction.commit()?;
        Ok(updated)
    }

    pub fn delete_saved_password(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute("DELETE FROM saved_passwords WHERE id=?1", params![id.to_string()])?;
        Ok(())
    }

    pub fn save_transfer_job(&self, job: &TransferJobRecord) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "INSERT INTO transfer_jobs(id, source_profile_snapshot, target_profile_snapshot, source_path, target_path, entry_kind, total_bytes, completed_bytes, state, error_message, created_at)
             VALUES(?1, ?2, ?3, ?4, ?5, 'file', ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(id) DO UPDATE SET completed_bytes = excluded.completed_bytes,
                state = excluded.state, error_message = excluded.error_message, updated_at = unixepoch()",
            params![
                job.id.to_string(), job.source_profile_snapshot, job.target_profile_snapshot,
                job.source_path, job.target_path, job.total_bytes, job.completed_bytes,
                job.state, job.error_message, job.created_at
            ],
        )?;
        Ok(())
    }

    pub fn transfer_jobs(&self) -> Result<Vec<TransferJobRecord>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, source_profile_snapshot, target_profile_snapshot, source_path, target_path,
                    total_bytes, completed_bytes, state, error_message, created_at
             FROM transfer_jobs ORDER BY created_at DESC",
        )?;
        let records = statement
            .query_map([], |row| {
                Ok(TransferJobRecord {
                    id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                    source_profile_snapshot: row.get(1)?,
                    target_profile_snapshot: row.get(2)?,
                    source_path: row.get(3)?,
                    target_path: row.get(4)?,
                    total_bytes: row.get(5)?,
                    completed_bytes: row.get(6)?,
                    state: row.get(7)?,
                    error_message: row.get(8)?,
                    created_at: row.get(9)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn delete_transfer_job(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "DELETE FROM transfer_jobs WHERE id = ?1",
            params![id.to_string()],
        )?;
        Ok(())
    }

    pub fn save_mount_mapping(&self, mapping: &MountMappingRecord) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "INSERT INTO mount_mappings(id, profile_id, profile_snapshot, name, remote_path, user_access_path, managed_mount_path, auto_mount, enabled, last_error)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(id) DO UPDATE SET profile_id = excluded.profile_id,
                profile_snapshot = excluded.profile_snapshot, name = excluded.name,
                remote_path = excluded.remote_path, user_access_path = excluded.user_access_path,
                managed_mount_path = excluded.managed_mount_path, auto_mount = excluded.auto_mount,
                enabled = excluded.enabled, last_error = excluded.last_error, updated_at = unixepoch()",
            params![
                mapping.id.to_string(), mapping.profile_id.map(|id| id.to_string()),
                mapping.profile_snapshot, mapping.name, mapping.remote_path,
                mapping.user_access_path, mapping.managed_mount_path,
                mapping.auto_mount, mapping.enabled, mapping.last_error
            ],
        )?;
        Ok(())
    }

    pub fn mount_mappings(&self) -> Result<Vec<MountMappingRecord>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, profile_id, profile_snapshot, name, remote_path, user_access_path,
                    managed_mount_path, auto_mount, enabled, last_error
             FROM mount_mappings ORDER BY name COLLATE NOCASE",
        )?;
        let records = statement
            .query_map([], |row| {
                Ok(MountMappingRecord {
                    id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_else(|_| Uuid::nil()),
                    profile_id: row
                        .get::<_, Option<String>>(1)?
                        .and_then(|value| Uuid::parse_str(&value).ok()),
                    profile_snapshot: row.get(2)?,
                    name: row.get(3)?,
                    remote_path: row.get(4)?,
                    user_access_path: row.get(5)?,
                    managed_mount_path: row.get(6)?,
                    auto_mount: row.get(7)?,
                    enabled: row.get(8)?,
                    last_error: row.get(9)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn delete_mount_mapping(&self, id: Uuid) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "DELETE FROM mount_mappings WHERE id = ?1",
            params![id.to_string()],
        )?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreAuthMethod {
    Password,
    PrivateKey,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSessionGroup {
    pub id: String,
    pub name: String,
    pub sort_order: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSshProfile {
    pub id: String,
    pub group_id: Option<String>,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: CoreAuthMethod,
    pub keychain_account: Option<String>,
    pub private_key_bookmark: Option<Vec<u8>>,
    pub tags: Vec<String>,
    pub symbol_name: String,
    pub sort_order: i64,
    pub saved_password_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSavedPassword {
    pub id: String,
    pub name: String,
    pub username: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreTransferJob {
    pub id: String,
    pub source_profile_name: String,
    pub target_profile_name: String,
    pub source_path: String,
    pub target_path: String,
    pub total_bytes: i64,
    pub completed_bytes: i64,
    pub state: String,
    pub error_message: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreMountMapping {
    pub id: String,
    pub profile_id: Option<String>,
    pub profile_snapshot: String,
    pub name: String,
    pub remote_path: String,
    pub user_access_path: String,
    pub managed_mount_path: String,
    pub auto_mount: bool,
    pub enabled: bool,
    pub last_error: Option<String>,
}

#[derive(Debug, Error, uniffi::Error)]
pub enum CoreError {
    #[error("storage error: {message}")]
    Storage { message: String },
    #[error("invalid identifier: {value}")]
    InvalidIdentifier { value: String },
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
    #[error("storage lock is unavailable")]
    StorageLock,
    #[error("connection error: {message}")]
    Connection {
        message: String,
        /// Stable ASCII stage code (for example `ssh_handshake`) that the
        /// Swift layer maps onto a localized stage name. `None` means the
        /// message is already a complete technical detail.
        stage: Option<String>,
    },
    #[error("unknown host key for {host}:{port}: {fingerprint}")]
    HostKeyUnknown {
        host: String,
        port: u16,
        algorithm: String,
        fingerprint: String,
    },
    #[error("host key changed for {host}:{port}: {fingerprint}")]
    HostKeyMismatch {
        host: String,
        port: u16,
        algorithm: String,
        fingerprint: String,
        previous_fingerprints: Vec<String>,
    },
    #[error("authentication failed: {message}")]
    Authentication {
        message: String,
        stage: Option<String>,
    },
    #[error("terminal is closed")]
    TerminalClosed,
    #[error("transfer cancelled")]
    TransferCancelled,
    #[error("destination already exists: {path}")]
    Conflict { path: String },
}

impl From<SnakeCoreError> for CoreError {
    fn from(value: SnakeCoreError) -> Self {
        match value {
            SnakeCoreError::Storage(error) => CoreError::Storage {
                message: error.to_string(),
            },
            SnakeCoreError::InvalidPort(port) => CoreError::InvalidInput {
                message: format!("invalid SSH port: {port}"),
            },
            SnakeCoreError::EmptyField(field) => CoreError::InvalidInput {
                message: format!("profile field `{field}` cannot be empty"),
            },
        }
    }
}

impl From<SessionGroup> for CoreSessionGroup {
    fn from(value: SessionGroup) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name,
            sort_order: value.sort_order,
        }
    }
}

impl From<SshProfile> for CoreSshProfile {
    fn from(value: SshProfile) -> Self {
        Self {
            id: value.id.to_string(),
            group_id: value.group_id.map(|id| id.to_string()),
            name: value.name,
            host: value.host,
            port: value.port,
            username: value.username,
            auth_method: match value.auth_method {
                AuthMethod::Password => CoreAuthMethod::Password,
                AuthMethod::PrivateKey => CoreAuthMethod::PrivateKey,
            },
            keychain_account: value.keychain_account,
            private_key_bookmark: value.private_key_bookmark,
            tags: serde_json::from_str(&value.tags_json).unwrap_or_default(),
            symbol_name: value.symbol_name,
            sort_order: value.sort_order,
            saved_password_id: value.saved_password_id.map(|id| id.to_string()),
        }
    }
}

#[derive(uniffi::Object)]
pub struct CoreDatabase {
    store: Mutex<SnakeStore>,
}

impl CoreDatabase {
    fn with_store<T>(
        &self,
        operation: impl FnOnce(&SnakeStore) -> Result<T, SnakeCoreError>,
    ) -> Result<T, CoreError> {
        let store = self.store.lock().map_err(|_| CoreError::StorageLock)?;
        operation(&store).map_err(Into::into)
    }
}

#[uniffi::export]
impl CoreDatabase {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let store = SnakeStore::open(path).map_err(CoreError::from)?;
        Ok(Arc::new(Self {
            store: Mutex::new(store),
        }))
    }

    pub fn groups(&self) -> Result<Vec<CoreSessionGroup>, CoreError> {
        self.with_store(|store| store.groups())
            .map(|groups| groups.into_iter().map(Into::into).collect())
    }

    pub fn profiles(&self) -> Result<Vec<CoreSshProfile>, CoreError> {
        self.with_store(|store| store.profiles())
            .map(|profiles| profiles.into_iter().map(Into::into).collect())
    }

    pub fn saved_passwords(&self) -> Result<Vec<CoreSavedPassword>, CoreError> {
        self.with_store(|store| store.saved_passwords()).map(|records| records.into_iter().map(|record| CoreSavedPassword {
            id: record.id.to_string(), name: record.name, username: record.username,
        }).collect())
    }

    pub fn save_saved_password_and_sync(&self, record: CoreSavedPassword, selected_profile_ids: Vec<String>, sync_username: bool) -> Result<Vec<String>, CoreError> {
        let id = parse_identifier(&record.id)?;
        let selected = selected_profile_ids.iter().map(|value| parse_identifier(value)).collect::<Result<Vec<_>, _>>()?;
        if record.name.trim().is_empty() || record.username.trim().is_empty() {
            return Err(CoreError::InvalidInput { message: "saved password name and username cannot be empty".to_owned() });
        }
        let record = SavedPasswordRecord { id, name: record.name, username: record.username };
        self.with_store(|store| store.save_saved_password_and_sync(&record, &selected, sync_username))
            .map(|ids| ids.into_iter().map(|id| id.to_string()).collect())
    }

    pub fn delete_saved_password(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_saved_password(id))
    }

    pub fn save_group(&self, group: CoreSessionGroup) -> Result<(), CoreError> {
        let id = parse_identifier(&group.id)?;
        let name = group.name.trim();
        if name.is_empty() {
            return Err(CoreError::InvalidInput {
                message: "group name cannot be empty".to_owned(),
            });
        }
        self.with_store(|store| {
            store.save_group(&SessionGroup {
                id,
                name: name.to_owned(),
                sort_order: group.sort_order,
            })
        })
    }

    pub fn delete_group(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_group(id))
    }

    pub fn save_profile(&self, profile: CoreSshProfile) -> Result<(), CoreError> {
        let id = parse_identifier(&profile.id)?;
        let group_id = profile
            .group_id
            .as_deref()
            .map(parse_identifier)
            .transpose()?;
        let tags_json =
            serde_json::to_string(&profile.tags).map_err(|error| CoreError::InvalidInput {
                message: error.to_string(),
            })?;
        let profile = SshProfile {
            id,
            group_id,
            name: profile.name,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            auth_method: match profile.auth_method {
                CoreAuthMethod::Password => AuthMethod::Password,
                CoreAuthMethod::PrivateKey => AuthMethod::PrivateKey,
            },
            keychain_account: profile.keychain_account,
            private_key_bookmark: profile.private_key_bookmark,
            tags_json,
            symbol_name: profile.symbol_name,
            sort_order: profile.sort_order,
            saved_password_id: profile.saved_password_id.as_deref().map(parse_identifier).transpose()?,
        };
        self.with_store(|store| store.save_profile(&profile))
    }

    pub fn delete_profile(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_profile(id))
    }

    pub fn transfer_jobs(&self) -> Result<Vec<CoreTransferJob>, CoreError> {
        self.with_store(|store| store.transfer_jobs()).map(|jobs| {
            jobs.into_iter()
                .map(|job| CoreTransferJob {
                    id: job.id.to_string(),
                    source_profile_name: job.source_profile_snapshot,
                    target_profile_name: job.target_profile_snapshot,
                    source_path: job.source_path,
                    target_path: job.target_path,
                    total_bytes: job.total_bytes,
                    completed_bytes: job.completed_bytes,
                    state: job.state,
                    error_message: job.error_message,
                    created_at: job.created_at,
                })
                .collect()
        })
    }

    pub fn save_transfer_job(&self, job: CoreTransferJob) -> Result<(), CoreError> {
        let id = parse_identifier(&job.id)?;
        if job.total_bytes < 0 || job.completed_bytes < 0 {
            return Err(CoreError::InvalidInput {
                message: "transfer byte counts cannot be negative".to_owned(),
            });
        }
        self.with_store(|store| {
            store.save_transfer_job(&TransferJobRecord {
                id,
                source_profile_snapshot: job.source_profile_name,
                target_profile_snapshot: job.target_profile_name,
                source_path: job.source_path,
                target_path: job.target_path,
                total_bytes: job.total_bytes,
                completed_bytes: job.completed_bytes.min(job.total_bytes),
                state: job.state,
                error_message: job.error_message,
                created_at: job.created_at,
            })
        })
    }

    pub fn delete_transfer_job(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_transfer_job(id))
    }

    pub fn mount_mappings(&self) -> Result<Vec<CoreMountMapping>, CoreError> {
        self.with_store(|store| store.mount_mappings())
            .map(|mappings| {
                mappings
                    .into_iter()
                    .map(|mapping| CoreMountMapping {
                        id: mapping.id.to_string(),
                        profile_id: mapping.profile_id.map(|id| id.to_string()),
                        profile_snapshot: mapping.profile_snapshot,
                        name: mapping.name,
                        remote_path: mapping.remote_path,
                        user_access_path: mapping.user_access_path,
                        managed_mount_path: mapping.managed_mount_path,
                        auto_mount: mapping.auto_mount,
                        enabled: mapping.enabled,
                        last_error: mapping.last_error,
                    })
                    .collect()
            })
    }

    pub fn save_mount_mapping(&self, mapping: CoreMountMapping) -> Result<(), CoreError> {
        let id = parse_identifier(&mapping.id)?;
        let profile_id = mapping
            .profile_id
            .as_deref()
            .map(parse_identifier)
            .transpose()?;
        for (field, value) in [
            ("name", mapping.name.trim()),
            ("remote_path", mapping.remote_path.trim()),
            ("user_access_path", mapping.user_access_path.trim()),
            ("managed_mount_path", mapping.managed_mount_path.trim()),
        ] {
            if value.is_empty() {
                return Err(CoreError::InvalidInput {
                    message: format!("mount field `{field}` cannot be empty"),
                });
            }
        }
        self.with_store(|store| {
            store.save_mount_mapping(&MountMappingRecord {
                id,
                profile_id,
                profile_snapshot: mapping.profile_snapshot,
                name: mapping.name,
                remote_path: mapping.remote_path,
                user_access_path: mapping.user_access_path,
                managed_mount_path: mapping.managed_mount_path,
                auto_mount: mapping.auto_mount,
                enabled: mapping.enabled,
                last_error: mapping.last_error,
            })
        })
    }

    pub fn delete_mount_mapping(&self, id: String) -> Result<(), CoreError> {
        let id = parse_identifier(&id)?;
        self.with_store(|store| store.delete_mount_mapping(id))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreHostKey {
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    pub fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreConnectionSecurity {
    pub host_key_algorithm: String,
    pub host_key_fingerprint: String,
    pub key_exchange_algorithm: String,
    pub client_to_server_cipher: String,
    pub server_to_client_cipher: String,
    pub client_to_server_mac: Option<String>,
    pub server_to_client_mac: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreRemoteEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub is_symbolic_link: bool,
    pub link_target: Option<String>,
    pub size: i64,
    pub modified_at: i64,
    pub permissions: String,
}

#[derive(uniffi::Object)]
pub struct CoreSftpHandle {
    _session: Session,
    sftp: Sftp,
}

#[uniffi::export(callback_interface)]
pub trait CoreTerminalObserver: Send + Sync {
    fn on_output(&self, data: Vec<u8>);
    fn on_closed(&self, exit_status: i32, message: Option<String>);
}

#[derive(uniffi::Object)]
pub struct CoreTerminalHandle {
    commands: Mutex<mpsc::Sender<TerminalCommand>>,
    closed: Arc<AtomicBool>,
    security: CoreConnectionSecurity,
    shell_name: String,
}

enum TerminalCommand {
    Write(Vec<u8>),
    Resize {
        columns: u32,
        rows: u32,
        pixel_width: u32,
        pixel_height: u32,
    },
    Close,
}

#[uniffi::export]
impl CoreTerminalHandle {
    pub fn security_info(&self) -> CoreConnectionSecurity {
        self.security.clone()
    }

    pub fn shell_name(&self) -> String {
        self.shell_name.clone()
    }

    pub fn write(&self, data: Vec<u8>) -> Result<(), CoreError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(CoreError::TerminalClosed);
        }
        self.commands
            .lock()
            .map_err(|_| CoreError::StorageLock)?
            .send(TerminalCommand::Write(data))
            .map_err(|_| CoreError::TerminalClosed)
    }

    pub fn resize(
        &self,
        columns: u32,
        rows: u32,
        pixel_width: u32,
        pixel_height: u32,
    ) -> Result<(), CoreError> {
        if columns == 0 || rows == 0 {
            return Err(CoreError::InvalidInput {
                message: "terminal dimensions must be positive".to_owned(),
            });
        }
        if self.closed.load(Ordering::Acquire) {
            return Err(CoreError::TerminalClosed);
        }
        self.commands
            .lock()
            .map_err(|_| CoreError::StorageLock)?
            .send(TerminalCommand::Resize {
                columns,
                rows,
                pixel_width,
                pixel_height,
            })
            .map_err(|_| CoreError::TerminalClosed)
    }

    pub fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Ok(commands) = self.commands.lock() {
            let _ = commands.send(TerminalCommand::Close);
        }
    }
}

impl Drop for CoreTerminalHandle {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Release);
        if let Ok(commands) = self.commands.get_mut() {
            let _ = commands.send(TerminalCommand::Close);
        }
    }
}

#[uniffi::export(callback_interface)]
pub trait CoreTransferObserver: Send + Sync {
    fn on_progress(&self, completed_bytes: u64, total_bytes: u64);
}

#[derive(uniffi::Object)]
pub struct CoreTransferControl {
    state: AtomicU8,
}

#[uniffi::export]
impl CoreTransferControl {
    pub fn checkpoint(&self) -> Result<(), CoreError> {
        self.wait_if_paused()
    }

    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: AtomicU8::new(0),
        })
    }

    pub fn pause(&self) {
        self.state.store(1, Ordering::Release);
    }

    pub fn resume(&self) {
        self.state.store(0, Ordering::Release);
    }

    pub fn cancel(&self) {
        self.state.store(2, Ordering::Release);
    }
}

impl CoreTransferControl {
    fn wait_if_paused(&self) -> Result<(), CoreError> {
        loop {
            match self.state.load(Ordering::Acquire) {
                0 => return Ok(()),
                1 => std::thread::sleep(std::time::Duration::from_millis(40)),
                _ => return Err(CoreError::TransferCancelled),
            }
        }
    }
}

#[uniffi::export]
impl CoreSftpHandle {
    pub fn copy_from(
        &self,
        source: Arc<CoreSftpHandle>,
        source_path: String,
        destination_path: String,
        is_directory: bool,
    ) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&destination_path))?;
        copy_remote_entry(
            &source.sftp,
            &self.sftp,
            Path::new(&source_path),
            Path::new(&destination_path),
            is_directory,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn copy_from_controlled(
        &self,
        source: Arc<CoreSftpHandle>,
        source_path: String,
        destination_path: String,
        is_directory: bool,
        total_bytes: u64,
        control: Arc<CoreTransferControl>,
        observer: Box<dyn CoreTransferObserver>,
    ) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&destination_path))?;
        let mut completed = 0_u64;
        let result = copy_remote_entry_controlled(
            &source.sftp,
            &self.sftp,
            Path::new(&source_path),
            Path::new(&destination_path),
            is_directory,
            total_bytes,
            &mut completed,
            &control,
            observer.as_ref(),
        );
        if matches!(&result, Err(CoreError::TransferCancelled)) {
            let _ = if is_directory {
                self.sftp.rmdir(Path::new(&destination_path))
            } else {
                self.sftp.unlink(Path::new(&destination_path))
            };
        }
        result
    }

    pub fn home_directory(&self) -> Result<String, CoreError> {
        self.sftp
            .realpath(Path::new("."))
            .map(|path| path.to_string_lossy().into_owned())
            .map_err(connection_error)
    }

    pub fn list(&self, path: String) -> Result<Vec<CoreRemoteEntry>, CoreError> {
        let entries = self
            .sftp
            .readdir(Path::new(&path))
            .map_err(connection_error)?;
        let mut entries = entries
            .into_iter()
            .map(|(path, stat)| {
                let stat = self.sftp.lstat(&path).unwrap_or(stat);
                let is_symbolic_link = stat.file_type().is_symlink();
                let link_target = is_symbolic_link
                    .then(|| self.sftp.readlink(&path).ok())
                    .flatten()
                    .map(|target| target.to_string_lossy().into_owned());
                let target_stat = is_symbolic_link
                    .then(|| self.sftp.stat(&path).ok())
                    .flatten();
                CoreRemoteEntry {
                    name: path
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    path: path.to_string_lossy().into_owned(),
                    is_directory: target_stat
                        .as_ref()
                        .map(FileStat::is_dir)
                        .unwrap_or_else(|| stat.is_dir()),
                    is_symbolic_link,
                    link_target,
                    size: i64::try_from(
                        target_stat
                            .as_ref()
                            .and_then(|value| value.size)
                            .or(stat.size)
                            .unwrap_or_default(),
                    )
                    .unwrap_or(i64::MAX),
                    modified_at: i64::try_from(stat.mtime.unwrap_or_default()).unwrap_or(i64::MAX),
                    permissions: format!(
                        "{:04o}",
                        target_stat
                            .as_ref()
                            .and_then(|value| value.perm)
                            .or(stat.perm)
                            .unwrap_or_default()
                            & 0o7777
                    ),
                }
            })
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| {
            right
                .is_directory
                .cmp(&left.is_directory)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        });
        Ok(entries)
    }

    pub fn upload(&self, local_path: String, remote_path: String) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&remote_path))?;
        let mut source = std::fs::File::open(local_path).map_err(io_error)?;
        let mut destination = self
            .sftp
            .create(Path::new(&remote_path))
            .map_err(connection_error)?;
        copy_with_fixed_buffer(&mut source, &mut destination)?;
        Ok(())
    }

    pub fn upload_controlled(
        &self,
        local_path: String,
        remote_path: String,
        control: Arc<CoreTransferControl>,
        observer: Box<dyn CoreTransferObserver>,
    ) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&remote_path))?;
        let mut source = std::fs::File::open(&local_path).map_err(io_error)?;
        let total = source.metadata().map_err(io_error)?.len();
        let mut destination = self
            .sftp
            .create(Path::new(&remote_path))
            .map_err(connection_error)?;
        let result = copy_with_control(
            &mut source,
            &mut destination,
            total,
            &control,
            observer.as_ref(),
        );
        if matches!(&result, Err(CoreError::TransferCancelled)) {
            drop(destination);
            let _ = self.sftp.unlink(Path::new(&remote_path));
        }
        result
    }

    /// Uploads one deterministic part file. Existing bytes are kept and the
    /// transfer continues at the remote part's current size. The caller uses
    /// independent SFTP handles for parallel parts, avoiding shared-session
    /// serialization and concurrent random writes to one remote file.
    #[allow(clippy::too_many_arguments)]
    pub fn upload_part_resumable(
        &self,
        local_path: String,
        remote_part_path: String,
        local_offset: u64,
        part_length: u64,
        control: Arc<CoreTransferControl>,
        observer: Box<dyn CoreTransferObserver>,
    ) -> Result<(), CoreError> {
        let remote_part_path = validated_remote_upload_path(&remote_part_path)?;
        let mut source = std::fs::File::open(&local_path).map_err(io_error)?;
        let local_length = source.metadata().map_err(io_error)?.len();
        let part_end =
            local_offset
                .checked_add(part_length)
                .ok_or_else(|| CoreError::InvalidInput {
                    message: "upload part range overflows".to_owned(),
                })?;
        // Empty Finder files still need a real empty part, followed by the
        // same staged finalization as non-empty uploads (including overwrite).
        if (part_length == 0 && local_length != 0) || part_end > local_length {
            return Err(CoreError::InvalidInput {
                message: "upload part range is outside the local file".to_owned(),
            });
        }

        let remote_size = self
            .sftp
            .stat(Path::new(&remote_part_path))
            .ok()
            .and_then(|stat| stat.size)
            .unwrap_or(0);
        let resume_at = if remote_size <= part_length {
            remote_size
        } else {
            0
        };
        source
            .seek(SeekFrom::Start(local_offset + resume_at))
            .map_err(io_error)?;

        let flags = if resume_at == 0 {
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE
        } else {
            OpenFlags::WRITE | OpenFlags::CREATE
        };
        let mut destination = self
            .sftp
            .open_mode(Path::new(&remote_part_path), flags, 0o600, OpenType::File)
            .map_err(connection_error)?;
        if resume_at > 0 {
            destination
                .seek(SeekFrom::Start(resume_at))
                .map_err(io_error)?;
        }
        observer.on_progress(resume_at, part_length);
        copy_exact_range_with_control(
            &mut source,
            &mut destination,
            resume_at,
            part_length,
            &control,
            observer.as_ref(),
        )
    }

    pub fn path_exists(&self, path: String) -> bool {
        self.sftp.stat(Path::new(&path)).is_ok()
    }

    /// Concatenates completed part files into a staging file and then moves
    /// that staging file into place. `mv -f` is deliberately the final step:
    /// an interrupted upload never truncates the user's existing target.
    pub fn finalize_resumable_upload(
        &self,
        remote_part_paths: Vec<String>,
        remote_staging_path: String,
        remote_target_path: String,
        overwrite: bool,
    ) -> Result<(), CoreError> {
        if remote_part_paths.is_empty() {
            return Err(CoreError::InvalidInput {
                message: "upload requires at least one part".to_owned(),
            });
        }
        let parts = remote_part_paths
            .iter()
            .map(|path| validated_remote_upload_path(path))
            .collect::<Result<Vec<_>, _>>()?;
        let staging = validated_remote_upload_path(&remote_staging_path)?;
        let target = validated_remote_upload_path(&remote_target_path)?;
        if !overwrite {
            ensure_destination_absent(&self.sftp, Path::new(&target))?;
        }

        let quoted_parts = parts
            .iter()
            .map(|path| shell_single_quote(path))
            .collect::<Vec<_>>()
            .join(" ");
        let move_flag = if overwrite { "-f" } else { "-n" };
        let command = format!(
            "cat -- {quoted_parts} > {} && mv {move_flag} -- {} {} && rm -f -- {quoted_parts}",
            shell_single_quote(&staging),
            shell_single_quote(&staging),
            shell_single_quote(&target),
        );
        run_remote_command(&self._session, &command, "finalize upload")
    }

    pub fn download(&self, remote_path: String, local_path: String) -> Result<(), CoreError> {
        let mut source = self
            .sftp
            .open(Path::new(&remote_path))
            .map_err(connection_error)?;
        let mut destination = std::fs::File::create(local_path).map_err(io_error)?;
        copy_with_fixed_buffer(&mut source, &mut destination)?;
        Ok(())
    }

    pub fn create_directory(&self, path: String) -> Result<(), CoreError> {
        self.sftp
            .mkdir(Path::new(&path), 0o755)
            .map_err(connection_error)
    }

    pub fn create_file(&self, path: String) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&path))?;
        let file = self
            .sftp
            .create(Path::new(&path))
            .map_err(connection_error)?;
        drop(file);
        Ok(())
    }

    pub fn set_permissions(&self, path: String, mode: u32) -> Result<(), CoreError> {
        let mode = validated_sftp_mode(mode)?;
        self.sftp
            .setstat(
                Path::new(&path),
                FileStat {
                    size: None,
                    uid: None,
                    gid: None,
                    perm: Some(mode),
                    atime: None,
                    mtime: None,
                },
            )
            .map_err(connection_error)
    }

    pub fn set_permissions_recursive(&self, path: String, mode: u32) -> Result<(), CoreError> {
        let command = recursive_chmod_command(&path, mode)?;
        run_remote_command(&self._session, &command, "chmod -R")
    }

    pub fn copy_symbolic_link_from(
        &self,
        source: Arc<CoreSftpHandle>,
        source_path: String,
        destination_path: String,
    ) -> Result<(), CoreError> {
        ensure_destination_absent(&self.sftp, Path::new(&destination_path))?;
        let target = source
            .sftp
            .readlink(Path::new(&source_path))
            .map_err(connection_error)?;
        self.sftp
            .symlink(&target, Path::new(&destination_path))
            .map_err(connection_error)
    }

    pub fn rename(&self, source: String, destination: String) -> Result<(), CoreError> {
        self.sftp
            .rename(Path::new(&source), Path::new(&destination), None)
            .map_err(connection_error)
    }

    pub fn remove_file(&self, path: String) -> Result<(), CoreError> {
        self.sftp.unlink(Path::new(&path)).map_err(connection_error)
    }

    pub fn remove_directory(&self, path: String) -> Result<(), CoreError> {
        self.sftp.rmdir(Path::new(&path)).map_err(connection_error)
    }

    pub fn remove_directory_recursive(&self, path: String) -> Result<(), CoreError> {
        let path = validated_recursive_delete_path(&path)?;
        let command = format!("rm -rf -- {}", shell_single_quote(&path));
        run_remote_command(&self._session, &command, "rm -rf")
    }
}

fn validated_sftp_mode(mode: u32) -> Result<u32, CoreError> {
    if mode > 0o7777 {
        return Err(CoreError::InvalidInput {
            message: "permissions must be an octal mode between 0000 and 7777".to_owned(),
        });
    }
    Ok(mode)
}

fn recursive_chmod_command(path: &str, mode: u32) -> Result<String, CoreError> {
    let path = validated_remote_upload_path(path)?;
    let mode = validated_sftp_mode(mode)?;
    Ok(format!(
        "chmod -R {:04o} -- {}",
        mode,
        shell_single_quote(&path)
    ))
}

fn validated_recursive_delete_path(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    let mut saw_root = false;
    let mut saw_name = false;

    if value.is_empty() || value != value.trim() || value.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput {
            message: "recursive delete path is empty or contains unsafe whitespace".to_owned(),
        });
    }

    for component in path.components() {
        match component {
            Component::RootDir if !saw_root && !saw_name => saw_root = true,
            Component::Normal(_) if saw_root => saw_name = true,
            _ => {
                return Err(CoreError::InvalidInput {
                    message: "recursive delete requires an absolute path without parent traversal"
                        .to_owned(),
                });
            }
        }
    }

    if !saw_root || !saw_name {
        return Err(CoreError::InvalidInput {
            message: "refusing to recursively delete the remote root directory".to_owned(),
        });
    }
    Ok(value.to_owned())
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn validated_remote_upload_path(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    let mut saw_root = false;
    let mut saw_name = false;
    if value.is_empty() || value != value.trim() || value.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput {
            message: "remote upload path is empty or contains unsafe whitespace".to_owned(),
        });
    }
    for component in path.components() {
        match component {
            Component::RootDir if !saw_root && !saw_name => saw_root = true,
            Component::Normal(_) if saw_root => saw_name = true,
            _ => {
                return Err(CoreError::InvalidInput {
                    message: "remote upload requires an absolute normalized path".to_owned(),
                });
            }
        }
    }
    if !saw_root || !saw_name {
        return Err(CoreError::InvalidInput {
            message: "remote upload path cannot be the root directory".to_owned(),
        });
    }
    Ok(value.to_owned())
}

fn run_remote_command(session: &Session, command: &str, operation: &str) -> Result<(), CoreError> {
    let mut channel = session.channel_session().map_err(connection_error)?;
    channel.exec(command).map_err(connection_error)?;
    let mut stdout = Vec::new();
    channel.read_to_end(&mut stdout).map_err(io_error)?;
    let mut stderr = String::new();
    channel
        .stderr()
        .read_to_string(&mut stderr)
        .map_err(io_error)?;
    channel.wait_close().map_err(connection_error)?;
    let exit_status = channel.exit_status().map_err(connection_error)?;
    if exit_status != 0 {
        let detail = stderr.trim();
        return Err(CoreError::Connection {
            message: if detail.is_empty() {
                format!("{operation} exited with status {exit_status}")
            } else {
                format!("{operation} failed: {detail}")
            },
            stage: None,
        });
    }
    Ok(())
}

#[uniffi::export]
pub fn probe_host_key(host: String, port: u16) -> Result<CoreHostKey, CoreError> {
    let (_, key, kind, _) = handshake(&host, port)?;
    Ok(host_key_record(&host, port, &key, kind))
}

#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn open_terminal_password(
    host: String,
    port: u16,
    username: String,
    password: Vec<u8>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
    columns: u32,
    rows: u32,
    observer: Box<dyn CoreTerminalObserver>,
) -> Result<Arc<CoreTerminalHandle>, CoreError> {
    let (session, key, kind, stream) = handshake(&host, port)?;
    verify_host_key(
        &session,
        &host,
        port,
        &key,
        kind,
        &known_hosts_path,
        accept_fingerprint.as_deref(),
    )?;
    let password =
        Zeroizing::new(
            String::from_utf8(password).map_err(|_| CoreError::Authentication {
                message: String::new(),
                stage: Some("auth_password_encoding_invalid".to_owned()),
            })?,
        );
    session
        .userauth_password(&username, password.as_str())
        .map_err(|error| authentication_stage_error("auth_password", error))?;
    let security = connection_security(&session, &key, kind);
    finish_terminal(session, stream, columns, rows, observer, security)
}

#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn open_terminal_private_key(
    host: String,
    port: u16,
    username: String,
    private_key_path: String,
    passphrase: Option<Vec<u8>>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
    columns: u32,
    rows: u32,
    observer: Box<dyn CoreTerminalObserver>,
) -> Result<Arc<CoreTerminalHandle>, CoreError> {
    let (session, key, kind, stream) = handshake(&host, port)?;
    verify_host_key(
        &session,
        &host,
        port,
        &key,
        kind,
        &known_hosts_path,
        accept_fingerprint.as_deref(),
    )?;
    let passphrase = passphrase
        .map(|bytes| String::from_utf8(bytes).map(Zeroizing::new))
        .transpose()
        .map_err(|_| CoreError::Authentication {
            message: String::new(),
            stage: Some("auth_private_key_passphrase_invalid".to_owned()),
        })?;
    session
        .userauth_pubkey_file(
            &username,
            None,
            Path::new(&private_key_path),
            passphrase.as_deref().map(String::as_str),
        )
        .map_err(|error| authentication_stage_error("auth_private_key", error))?;
    let security = connection_security(&session, &key, kind);
    finish_terminal(session, stream, columns, rows, observer, security)
}

#[uniffi::export]
pub fn open_sftp_password(
    host: String,
    port: u16,
    username: String,
    password: Vec<u8>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
) -> Result<Arc<CoreSftpHandle>, CoreError> {
    let (session, key, kind, _) = handshake(&host, port)?;
    verify_host_key(
        &session,
        &host,
        port,
        &key,
        kind,
        &known_hosts_path,
        accept_fingerprint.as_deref(),
    )?;
    let password =
        Zeroizing::new(
            String::from_utf8(password).map_err(|_| CoreError::Authentication {
                message: "password is not valid UTF-8".to_owned(),
                stage: None,
            })?,
        );
    session
        .userauth_password(&username, password.as_str())
        .map_err(authentication_error)?;
    finish_sftp(session)
}

#[uniffi::export]
pub fn open_sftp_private_key(
    host: String,
    port: u16,
    username: String,
    private_key_path: String,
    passphrase: Option<Vec<u8>>,
    known_hosts_path: String,
    accept_fingerprint: Option<String>,
) -> Result<Arc<CoreSftpHandle>, CoreError> {
    let (session, key, kind, _) = handshake(&host, port)?;
    verify_host_key(
        &session,
        &host,
        port,
        &key,
        kind,
        &known_hosts_path,
        accept_fingerprint.as_deref(),
    )?;
    let passphrase = passphrase
        .map(|bytes| String::from_utf8(bytes).map(Zeroizing::new))
        .transpose()
        .map_err(|_| CoreError::Authentication {
            message: "key passphrase is not valid UTF-8".to_owned(),
            stage: None,
        })?;
    session
        .userauth_pubkey_file(
            &username,
            None,
            Path::new(&private_key_path),
            passphrase.as_deref().map(String::as_str),
        )
        .map_err(authentication_error)?;
    finish_sftp(session)
}

fn handshake(
    host: &str,
    port: u16,
) -> Result<(Session, Vec<u8>, HostKeyType, TcpStream), CoreError> {
    if host.trim().is_empty() || port == 0 {
        return Err(CoreError::InvalidInput {
            message: "host and port are required".to_owned(),
        });
    }
    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|error| io_connection_stage_error("tcp_resolve", error))?;
    let mut last_error = None;
    let mut stream = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, std::time::Duration::from_secs(15)) {
            Ok(candidate) => {
                stream = Some(candidate);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let stream = stream.ok_or_else(|| {
        io_connection_stage_error(
            "tcp_connect",
            last_error.unwrap_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "host resolved to no addresses",
                )
            }),
        )
    })?;
    let session_stream = stream
        .try_clone()
        .map_err(|error| io_connection_stage_error("tcp_stream", error))?;
    let mut session =
        Session::new().map_err(|error| ssh_connection_stage_error("ssh_session_init", error))?;
    session.set_timeout(15_000);
    session.set_tcp_stream(stream);
    session
        .handshake()
        .map_err(|error| ssh_connection_stage_error("ssh_handshake", error))?;
    let (key, kind) = {
        let (key, kind) = session.host_key().ok_or_else(|| CoreError::Connection {
            message: String::new(),
            stage: Some("ssh_host_key_missing".to_owned()),
        })?;
        (key.to_vec(), kind)
    };
    Ok((session, key, kind, session_stream))
}

// Serialize read/modify/write across simultaneous terminal and SFTP connections.
static KNOWN_HOSTS_LOCK: Mutex<()> = Mutex::new(());

fn verify_host_key(
    session: &Session,
    host: &str,
    port: u16,
    key: &[u8],
    kind: HostKeyType,
    known_hosts_path: &str,
    accept_fingerprint: Option<&str>,
) -> Result<(), CoreError> {
    let _guard = KNOWN_HOSTS_LOCK.lock().map_err(|_| CoreError::StorageLock)?;
    let record = host_key_record(host, port, key, kind);
    let label = if port == 22 { host.to_owned() } else { format!("[{host}]:{port}") };
    let file = PathBuf::from(known_hosts_path);
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent).map_err(io_error)?;
    }
    let mut known_hosts = session.known_hosts().map_err(connection_error)?;
    if file.exists() {
        known_hosts
            .read_file(&file, KnownHostFileKind::OpenSSH)
            .map_err(connection_error)?;
    }
    // Use the exact endpoint so trusting a non-default port never alters port 22.
    match known_hosts.check(&label, key) {
        CheckResult::Match => Ok(()),
        result @ (CheckResult::Mismatch | CheckResult::NotFound) => {
            let mut previous_fingerprints = Vec::new();
            let mut retained = session.known_hosts().map_err(connection_error)?;
            for entry in known_hosts.hosts().map_err(connection_error)? {
                let line = known_hosts.write_string(&entry, KnownHostFileKind::OpenSSH)
                    .map_err(connection_error)?;
                let mut single = session.known_hosts().map_err(connection_error)?;
                single.read_str(&line, KnownHostFileKind::OpenSSH).map_err(connection_error)?;
                match single.check(&label, key) {
                    CheckResult::Match | CheckResult::Mismatch => {
                        let old_key = STANDARD.decode(entry.key()).map_err(|_| CoreError::Connection {
                            message: "invalid stored host key".to_owned(),
                            stage: None,
                        })?;
                        previous_fingerprints.push(host_key_fingerprint(&old_key));
                    }
                    CheckResult::NotFound => {
                        retained.read_str(&line, KnownHostFileKind::OpenSSH).map_err(connection_error)?;
                    }
                    CheckResult::Failure => return Err(CoreError::Connection {
                        message: "unable to evaluate stored host key".to_owned(),
                        stage: None,
                    }),
                }
            }
            if accept_fingerprint != Some(record.fingerprint.as_str()) {
                if matches!(result, CheckResult::Mismatch) {
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
            retained
                .add(&label, key, "Snake", kind.into())
                .map_err(connection_error)?;
            persist_known_hosts(&retained, &file)
        }
        CheckResult::Failure => Err(CoreError::Connection {
            message: "unable to evaluate known_hosts".to_owned(),
            stage: None,
        }),
    }
}

fn persist_known_hosts(hosts: &ssh2::KnownHosts, file: &Path) -> Result<(), CoreError> {
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
        for entry in hosts.hosts().map_err(connection_error)? {
            let line = hosts.write_string(&entry, KnownHostFileKind::OpenSSH).map_err(connection_error)?;
            output.write_all(line.as_bytes()).map_err(io_error)?;
        }
        output.sync_all().map_err(io_error)?;
        std::fs::rename(&temporary, file).map_err(io_error)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn finish_sftp(session: Session) -> Result<Arc<CoreSftpHandle>, CoreError> {
    if !session.authenticated() {
        return Err(CoreError::Authentication {
            message: "server rejected the supplied credential".to_owned(),
            stage: None,
        });
    }
    let sftp = session.sftp().map_err(connection_error)?;
    Ok(Arc::new(CoreSftpHandle {
        _session: session,
        sftp,
    }))
}

fn finish_terminal(
    session: Session,
    stream: TcpStream,
    columns: u32,
    rows: u32,
    observer: Box<dyn CoreTerminalObserver>,
    security: CoreConnectionSecurity,
) -> Result<Arc<CoreTerminalHandle>, CoreError> {
    if !session.authenticated() {
        return Err(CoreError::Authentication {
            message: "server rejected the supplied credential".to_owned(),
            stage: None,
        });
    }
    if columns == 0 || rows == 0 {
        return Err(CoreError::InvalidInput {
            message: "terminal dimensions must be positive".to_owned(),
        });
    }

    let shell_name = detect_remote_shell(&session);
    session.set_keepalive(true, 30);
    let mut channel = session
        .channel_session()
        .map_err(|error| ssh_connection_stage_error("ssh_channel", error))?;
    channel
        .request_pty("xterm-256color", None, Some((columns, rows, 0, 0)))
        .map_err(|error| ssh_connection_stage_error("ssh_pty", error))?;
    channel
        .handle_extended_data(ExtendedData::Merge)
        .map_err(|error| ssh_connection_stage_error("ssh_output", error))?;
    channel
        .shell()
        .map_err(|error| ssh_connection_stage_error("ssh_shell", error))?;
    stream
        .set_nonblocking(true)
        .map_err(|error| io_connection_stage_error("ssh_net_stream", error))?;
    session.set_blocking(false);

    let (command_sender, command_receiver) = mpsc::channel();
    let closed = Arc::new(AtomicBool::new(false));
    let worker_closed = Arc::clone(&closed);
    std::thread::Builder::new()
        .name("snake-terminal-io".to_owned())
        .spawn(move || {
            terminal_io_loop(session, channel, command_receiver, worker_closed, observer)
        })
        .map_err(io_error)?;

    Ok(Arc::new(CoreTerminalHandle {
        commands: Mutex::new(command_sender),
        closed,
        security,
        shell_name,
    }))
}

fn detect_remote_shell(session: &Session) -> String {
    let result = (|| -> Option<String> {
        let mut channel = session.channel_session().ok()?;
        channel.exec("printf '%s' \"${SHELL:-}\"").ok()?;
        let mut output = String::new();
        channel.read_to_string(&mut output).ok()?;
        channel.wait_close().ok()?;
        Some(output)
    })();

    result
        .and_then(|value| {
            Path::new(value.trim())
                .file_name()
                .map(|name| name.to_string_lossy().to_lowercase())
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "sh".to_owned())
}

fn terminal_io_loop(
    session: Session,
    mut channel: Channel,
    commands: mpsc::Receiver<TerminalCommand>,
    closed: Arc<AtomicBool>,
    observer: Box<dyn CoreTerminalObserver>,
) {
    let mut buffer = vec![0_u8; 32 * 1024];
    let mut pending_writes = std::collections::VecDeque::<(Vec<u8>, usize)>::new();
    let mut pending_resize = None;
    let mut needs_flush = false;
    let mut next_keepalive = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut failure = None;
    let mut should_close = false;

    loop {
        let mut progressed = false;
        loop {
            match commands.try_recv() {
                Ok(TerminalCommand::Write(data)) => {
                    if !data.is_empty() {
                        pending_writes.push_back((data, 0));
                    }
                    progressed = true;
                }
                Ok(TerminalCommand::Resize {
                    columns,
                    rows,
                    pixel_width,
                    pixel_height,
                }) => {
                    pending_resize = Some((columns, rows, pixel_width, pixel_height));
                    progressed = true;
                }
                Ok(TerminalCommand::Close) | Err(mpsc::TryRecvError::Disconnected) => {
                    should_close = true;
                    break;
                }
                Err(mpsc::TryRecvError::Empty) => break,
            }
        }

        if should_close {
            let _ = channel.send_eof();
            let _ = channel.close();
            break;
        }

        if let Some((columns, rows, pixel_width, pixel_height)) = pending_resize {
            match channel.request_pty_size(columns, rows, Some(pixel_width), Some(pixel_height)) {
                Ok(()) => {
                    pending_resize = None;
                    progressed = true;
                }
                Err(error) if error.code() == ErrorCode::Session(-37) => {}
                Err(error) => {
                    failure = Some(format!("PTY resize failed: {}", error.message()));
                    break;
                }
            }
        }

        if let Some((data, offset)) = pending_writes.front_mut() {
            match channel.write(&data[*offset..]) {
                Ok(0) => {}
                Ok(count) => {
                    *offset += count;
                    progressed = true;
                    needs_flush = true;
                    if *offset == data.len() {
                        pending_writes.pop_front();
                    }
                }
                Err(error) if terminal_io_would_block(&error) => {}
                Err(error) => {
                    failure = Some(format!("terminal write failed: {error}"));
                    break;
                }
            }
        }

        if pending_writes.is_empty() && needs_flush {
            match channel.flush() {
                Ok(()) => {
                    needs_flush = false;
                    progressed = true;
                }
                Err(error) if terminal_io_would_block(&error) => {}
                Err(error) => {
                    failure = Some(format!("terminal flush failed: {error}"));
                    break;
                }
            }
        }

        match channel.read(&mut buffer) {
            Ok(0) if channel.eof() => break,
            Ok(0) => {}
            Ok(count) => {
                observer.on_output(buffer[..count].to_vec());
                progressed = true;
            }
            Err(error) if terminal_io_would_block(&error) => {}
            Err(error) => {
                failure = Some(error.to_string());
                break;
            }
        }

        if std::time::Instant::now() >= next_keepalive {
            match session.keepalive_send() {
                Ok(seconds) => {
                    next_keepalive = std::time::Instant::now()
                        + std::time::Duration::from_secs(u64::from(seconds.max(1)));
                    progressed = true;
                }
                Err(error) if error.code() == ErrorCode::Session(-37) => {}
                Err(error) => {
                    failure = Some(format!("SSH keepalive failed: {}", error.message()));
                    break;
                }
            }
        }

        if !progressed {
            std::thread::sleep(std::time::Duration::from_millis(4));
        }
    }
    let exit_status = channel.exit_status().unwrap_or_default();
    closed.store(true, Ordering::Release);
    observer.on_closed(exit_status, failure);
}

fn terminal_io_would_block(error: &std::io::Error) -> bool {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        return true;
    }
    let message = error.to_string().to_ascii_lowercase();
    message.contains("would block")
        || message.contains("session(-37)")
        || message.contains("failure while draining incoming flow")
        || message == "transport read"
}

fn host_key_record(host: &str, port: u16, key: &[u8], kind: HostKeyType) -> CoreHostKey {
    CoreHostKey {
        host: host.to_owned(),
        port,
        algorithm: host_key_algorithm(kind).to_owned(),
        fingerprint: host_key_fingerprint(key),
    }
}

fn connection_security(
    session: &Session,
    host_key: &[u8],
    host_key_type: HostKeyType,
) -> CoreConnectionSecurity {
    connection_security_from_methods(
        session
            .methods(MethodType::HostKey)
            .unwrap_or_else(|| host_key_algorithm(host_key_type)),
        &host_key_fingerprint(host_key),
        session.methods(MethodType::Kex),
        session.methods(MethodType::CryptCs),
        session.methods(MethodType::CryptSc),
        session.methods(MethodType::MacCs),
        session.methods(MethodType::MacSc),
    )
}

fn connection_security_from_methods(
    host_key_algorithm: &str,
    host_key_fingerprint: &str,
    key_exchange_algorithm: Option<&str>,
    client_to_server_cipher: Option<&str>,
    server_to_client_cipher: Option<&str>,
    client_to_server_mac: Option<&str>,
    server_to_client_mac: Option<&str>,
) -> CoreConnectionSecurity {
    CoreConnectionSecurity {
        host_key_algorithm: nonempty_method(host_key_algorithm),
        host_key_fingerprint: host_key_fingerprint.to_owned(),
        key_exchange_algorithm: optional_method(key_exchange_algorithm)
            .unwrap_or_else(|| "unknown".to_owned()),
        client_to_server_cipher: optional_method(client_to_server_cipher)
            .unwrap_or_else(|| "unknown".to_owned()),
        server_to_client_cipher: optional_method(server_to_client_cipher)
            .unwrap_or_else(|| "unknown".to_owned()),
        client_to_server_mac: optional_method(client_to_server_mac),
        server_to_client_mac: optional_method(server_to_client_mac),
    }
}

fn optional_method(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("none"))
        .map(str::to_owned)
}

fn nonempty_method(value: &str) -> String {
    optional_method(Some(value)).unwrap_or_else(|| "unknown".to_owned())
}

fn host_key_fingerprint(key: &[u8]) -> String {
    let fingerprint = Sha256::digest(key)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":");
    format!("SHA256 {fingerprint}")
}

fn host_key_algorithm(kind: HostKeyType) -> &'static str {
    match kind {
        HostKeyType::Rsa => "RSA",
        HostKeyType::Dss => "DSA",
        HostKeyType::Ecdsa256 => "ECDSA-256",
        HostKeyType::Ecdsa384 => "ECDSA-384",
        HostKeyType::Ecdsa521 => "ECDSA-521",
        HostKeyType::Ed25519 => "ED25519",
        HostKeyType::Unknown => "UNKNOWN",
    }
}

fn copy_with_fixed_buffer(
    source: &mut impl Read,
    destination: &mut impl Write,
) -> Result<(), CoreError> {
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = source.read(&mut buffer).map_err(io_error)?;
        if count == 0 {
            break;
        }
        destination.write_all(&buffer[..count]).map_err(io_error)?;
    }
    destination.flush().map_err(io_error)
}

fn copy_remote_entry(
    source: &Sftp,
    destination: &Sftp,
    source_path: &Path,
    destination_path: &Path,
    is_directory: bool,
) -> Result<(), CoreError> {
    if is_directory {
        if let Err(error) = destination.mkdir(destination_path, 0o755) {
            if destination.stat(destination_path).is_err() {
                return Err(connection_error(error));
            }
        }
        for (child_path, stat) in source.readdir(source_path).map_err(connection_error)? {
            let Some(name) = child_path.file_name() else {
                continue;
            };
            copy_remote_entry(
                source,
                destination,
                &child_path,
                &destination_path.join(name),
                stat.is_dir(),
            )?;
        }
        return Ok(());
    }

    let mut input = source.open(source_path).map_err(connection_error)?;
    let mut output = destination
        .create(destination_path)
        .map_err(connection_error)?;
    copy_with_fixed_buffer(&mut input, &mut output)
}

fn ensure_destination_absent(sftp: &Sftp, path: &Path) -> Result<(), CoreError> {
    if sftp.stat(path).is_ok() {
        return Err(CoreError::Conflict {
            path: path.to_string_lossy().into_owned(),
        });
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn copy_remote_entry_controlled(
    source: &Sftp,
    destination: &Sftp,
    source_path: &Path,
    destination_path: &Path,
    is_directory: bool,
    total_bytes: u64,
    completed_bytes: &mut u64,
    control: &CoreTransferControl,
    observer: &dyn CoreTransferObserver,
) -> Result<(), CoreError> {
    control.wait_if_paused()?;
    if is_directory {
        if let Err(error) = destination.mkdir(destination_path, 0o755) {
            if destination.stat(destination_path).is_err() {
                return Err(connection_error(error));
            }
        }
        for (child_path, stat) in source.readdir(source_path).map_err(connection_error)? {
            let Some(name) = child_path.file_name() else {
                continue;
            };
            copy_remote_entry_controlled(
                source,
                destination,
                &child_path,
                &destination_path.join(name),
                stat.is_dir(),
                total_bytes,
                completed_bytes,
                control,
                observer,
            )?;
        }
        return Ok(());
    }
    let mut input = source.open(source_path).map_err(connection_error)?;
    let mut output = destination
        .create(destination_path)
        .map_err(connection_error)?;
    copy_with_control_from_offset(
        &mut input,
        &mut output,
        total_bytes,
        completed_bytes,
        control,
        observer,
    )
}

fn copy_with_control(
    source: &mut impl Read,
    destination: &mut impl Write,
    total_bytes: u64,
    control: &CoreTransferControl,
    observer: &dyn CoreTransferObserver,
) -> Result<(), CoreError> {
    let mut completed = 0_u64;
    copy_with_control_from_offset(
        source,
        destination,
        total_bytes,
        &mut completed,
        control,
        observer,
    )
}

fn copy_with_control_from_offset(
    source: &mut impl Read,
    destination: &mut impl Write,
    total_bytes: u64,
    completed_bytes: &mut u64,
    control: &CoreTransferControl,
    observer: &dyn CoreTransferObserver,
) -> Result<(), CoreError> {
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        control.wait_if_paused()?;
        let count = source.read(&mut buffer).map_err(io_error)?;
        if count == 0 {
            break;
        }
        destination.write_all(&buffer[..count]).map_err(io_error)?;
        *completed_bytes = completed_bytes.saturating_add(count as u64);
        observer.on_progress(*completed_bytes, total_bytes);
    }
    destination.flush().map_err(io_error)
}

fn copy_exact_range_with_control(
    source: &mut impl Read,
    destination: &mut impl Write,
    resumed_bytes: u64,
    total_bytes: u64,
    control: &CoreTransferControl,
    observer: &dyn CoreTransferObserver,
) -> Result<(), CoreError> {
    // Also honor cancellation for an empty or already complete part.
    control.wait_if_paused()?;
    let mut completed = resumed_bytes;
    let mut buffer = vec![0_u8; 1024 * 1024];
    while completed < total_bytes {
        control.wait_if_paused()?;
        let remaining = total_bytes - completed;
        let wanted = usize::try_from(remaining.min(buffer.len() as u64)).unwrap_or(buffer.len());
        let count = source.read(&mut buffer[..wanted]).map_err(io_error)?;
        if count == 0 {
            return Err(CoreError::InvalidInput {
                message: "local file ended before the upload part was complete".to_owned(),
            });
        }
        destination.write_all(&buffer[..count]).map_err(io_error)?;
        completed = completed.saturating_add(count as u64);
        observer.on_progress(completed, total_bytes);
    }
    destination.flush().map_err(io_error)
}

fn connection_error(error: ssh2::Error) -> CoreError {
    CoreError::Connection {
        message: error.message().to_owned(),
        stage: None,
    }
}

fn ssh_connection_stage_error(stage: &str, error: ssh2::Error) -> CoreError {
    CoreError::Connection {
        message: error.message().to_owned(),
        stage: Some(stage.to_owned()),
    }
}

fn io_connection_stage_error(stage: &str, error: std::io::Error) -> CoreError {
    CoreError::Connection {
        message: error.to_string(),
        stage: Some(stage.to_owned()),
    }
}

fn authentication_error(error: ssh2::Error) -> CoreError {
    CoreError::Authentication {
        message: error.message().to_owned(),
        stage: None,
    }
}

fn authentication_stage_error(stage: &str, error: ssh2::Error) -> CoreError {
    CoreError::Authentication {
        message: error.message().to_owned(),
        stage: Some(stage.to_owned()),
    }
}

fn io_error(error: std::io::Error) -> CoreError {
    CoreError::Connection {
        message: error.to_string(),
        stage: None,
    }
}

fn parse_identifier(value: &str) -> Result<Uuid, CoreError> {
    Uuid::parse_str(value).map_err(|_| CoreError::InvalidIdentifier {
        value: value.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct RecordingObserver {
        updates: Mutex<Vec<(u64, u64)>>,
    }

    impl CoreTransferObserver for RecordingObserver {
        fn on_progress(&self, completed_bytes: u64, total_bytes: u64) {
            self.updates
                .lock()
                .unwrap()
                .push((completed_bytes, total_bytes));
        }
    }

    #[test]
    fn validates_remote_permission_modes() {
        assert_eq!(validated_sftp_mode(0o644).unwrap(), 0o644);
        assert_eq!(validated_sftp_mode(0o2755).unwrap(), 0o2755);
        assert!(matches!(
            validated_sftp_mode(0o10000),
            Err(CoreError::InvalidInput { .. })
        ));
    }

    #[test]
    fn validates_and_quotes_recursive_delete_paths() {
        assert_eq!(
            validated_recursive_delete_path("/srv/releases/build 1").unwrap(),
            "/srv/releases/build 1"
        );
        assert_eq!(
            shell_single_quote("/tmp/team's build"),
            "'/tmp/team'\"'\"'s build'"
        );
        for unsafe_path in [
            "",
            "/",
            "//",
            "relative/path",
            "/tmp/../etc",
            "/tmp\nnext",
            "/tmp/build ",
        ] {
            assert!(matches!(
                validated_recursive_delete_path(unsafe_path),
                Err(CoreError::InvalidInput { .. })
            ));
        }
    }

    #[test]
    fn creates_schema_and_stores_non_secret_profile() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let store = SnakeStore::open(temp.path()).unwrap();
        let group = SessionGroup {
            id: Uuid::new_v4(),
            name: "生产".into(),
            sort_order: 0,
        };
        store.save_group(&group).unwrap();
        let profile = SshProfile {
            id: Uuid::new_v4(),
            group_id: Some(group.id),
            name: "api-01".into(),
            host: "10.0.0.8".into(),
            port: 22,
            username: "deploy".into(),
            auth_method: AuthMethod::Password,
            keychain_account: Some("id/password".into()),
            private_key_bookmark: None,
            tags_json: "[\"生产\"]".into(),
            symbol_name: "server.rack".into(),
            sort_order: 0,
            saved_password_id: None,
        };
        store.save_profile(&profile).unwrap();
        assert_eq!(store.groups().unwrap(), vec![group]);
        assert_eq!(store.profile(profile.id).unwrap(), Some(profile));
    }

    #[test]
    fn rejects_invalid_profile() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let store = SnakeStore::open(temp.path()).unwrap();
        let profile = SshProfile {
            id: Uuid::new_v4(),
            group_id: None,
            name: "".into(),
            host: "host".into(),
            port: 22,
            username: "user".into(),
            auth_method: AuthMethod::Password,
            keychain_account: None,
            private_key_bookmark: None,
            tags_json: "[]".into(),
            symbol_name: "server.rack".into(),
            sort_order: 0,
            saved_password_id: None,
        };
        assert!(matches!(
            store.save_profile(&profile),
            Err(SnakeCoreError::EmptyField("name"))
        ));
    }

    #[test]
    fn uniffi_database_round_trips_configuration() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let database = CoreDatabase::open(temp.path().to_string_lossy().into_owned()).unwrap();
        let group_id = Uuid::new_v4().to_string();
        database
            .save_group(CoreSessionGroup {
                id: group_id.clone(),
                name: "研发环境".into(),
                sort_order: 0,
            })
            .unwrap();
        let profile = CoreSshProfile {
            id: Uuid::new_v4().to_string(),
            group_id: Some(group_id),
            name: "dev-k8s-01".into(),
            host: "192.168.20.41".into(),
            port: 22,
            username: "deploy".into(),
            auth_method: CoreAuthMethod::PrivateKey,
            keychain_account: Some("profile/key-passphrase".into()),
            private_key_bookmark: Some(vec![1, 2, 3]),
            tags: vec!["开发".into(), "内网".into()],
            symbol_name: "server.rack".into(),
            sort_order: 0,
            saved_password_id: None,
        };
        database.save_profile(profile.clone()).unwrap();
        assert_eq!(database.profiles().unwrap(), vec![profile]);

        let mapping = CoreMountMapping {
            id: Uuid::new_v4().to_string(),
            profile_id: database
                .profiles()
                .unwrap()
                .first()
                .map(|item| item.id.clone()),
            profile_snapshot: "dev-k8s-01".into(),
            name: "发布目录".into(),
            remote_path: "/srv/releases".into(),
            user_access_path: "/Users/test/Snake/releases".into(),
            managed_mount_path: "/Users/Shared/.SnakeMounts/test".into(),
            auto_mount: false,
            enabled: true,
            last_error: None,
        };
        database.save_mount_mapping(mapping.clone()).unwrap();
        assert_eq!(database.mount_mappings().unwrap(), vec![mapping]);

        let transfer = CoreTransferJob {
            id: Uuid::new_v4().to_string(),
            source_profile_name: "本机".into(),
            target_profile_name: "dev-k8s-01".into(),
            source_path: "/tmp/a.zip".into(),
            target_path: "/srv/a.zip".into(),
            total_bytes: 1024,
            completed_bytes: 256,
            state: "paused".into(),
            error_message: None,
            created_at: 1,
        };
        database.save_transfer_job(transfer.clone()).unwrap();
        assert_eq!(database.transfer_jobs().unwrap(), vec![transfer]);
    }

    #[test]
    fn saved_password_metadata_syncs_only_selected_linked_password_profiles() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let database = CoreDatabase::open(temp.path().to_string_lossy().into_owned()).unwrap();
        let entry = CoreSavedPassword { id: Uuid::new_v4().to_string(), name: "team".into(), username: "old".into() };
        database.save_saved_password_and_sync(entry.clone(), vec![], false).unwrap();
        let make_profile = |id: String, linked: Option<String>, method: CoreAuthMethod| CoreSshProfile {
            id, group_id: None, name: "host".into(), host: "127.0.0.1".into(), port: 22,
            username: "old".into(), auth_method: method, keychain_account: Some("profile/password".into()),
            private_key_bookmark: None, tags: vec![], symbol_name: "server.rack".into(), sort_order: 0,
            saved_password_id: linked,
        };
        let linked = make_profile(Uuid::new_v4().to_string(), Some(entry.id.clone()), CoreAuthMethod::Password);
        let untouched = make_profile(Uuid::new_v4().to_string(), Some(entry.id.clone()), CoreAuthMethod::Password);
        let private_key = make_profile(Uuid::new_v4().to_string(), None, CoreAuthMethod::PrivateKey);
        for profile in [&linked, &untouched, &private_key] { database.save_profile(profile.clone()).unwrap(); }
        let changed = CoreSavedPassword { username: "new".into(), ..entry.clone() };
        assert_eq!(database.save_saved_password_and_sync(changed.clone(), vec![linked.id.clone()], true).unwrap(), vec![linked.id.clone()]);
        let profiles = database.profiles().unwrap();
        assert_eq!(profiles.iter().find(|profile| profile.id == linked.id).unwrap().username, "new");
        assert_eq!(profiles.iter().find(|profile| profile.id == untouched.id).unwrap().username, "old");
        assert!(database.save_saved_password_and_sync(changed, vec![private_key.id.clone()], true).is_err());
        database.delete_saved_password(entry.id).unwrap();
        assert!(database.saved_passwords().unwrap().is_empty());
        assert!(database.profiles().unwrap().iter().all(|profile| profile.saved_password_id.is_none()));
        assert_eq!(database.profiles().unwrap().iter().find(|profile| profile.id == linked.id).unwrap().username, "new");
    }

    #[test]
    fn existing_profile_schema_migrates_without_matching_old_sessions() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let connection = Connection::open(temp.path()).unwrap();
        connection.execute_batch("CREATE TABLE ssh_profiles (id TEXT PRIMARY KEY, group_id TEXT, name TEXT, host TEXT, port INTEGER, username TEXT, auth_method TEXT, keychain_account TEXT, private_key_bookmark BLOB, tags_json TEXT, symbol_name TEXT, sort_order INTEGER); INSERT INTO ssh_profiles VALUES ('old','', 'old', '127.0.0.1',22,'root','password',NULL,NULL,'[]','server.rack',0);").unwrap();
        drop(connection);
        let store = SnakeStore::open(temp.path()).unwrap();
        assert_eq!(store.profiles().unwrap().len(), 1);
        assert_eq!(store.profiles().unwrap()[0].saved_password_id, None);
    }

    #[test]
    fn fixed_transfer_buffer_copies_large_payload_without_temp_files() {
        let payload = vec![0x5a; 2 * 1024 * 1024 + 17];
        let mut source = std::io::Cursor::new(payload.clone());
        let mut destination = Vec::new();
        copy_with_fixed_buffer(&mut source, &mut destination).unwrap();
        assert_eq!(destination, payload);
    }

    #[test]
    fn host_key_fingerprint_is_stable_and_algorithm_labeled() {
        let record = host_key_record(
            "host.example",
            2222,
            b"server-public-key",
            HostKeyType::Ed25519,
        );
        assert_eq!(record.host, "host.example");
        assert_eq!(record.port, 2222);
        assert_eq!(record.algorithm, "ED25519");
        assert!(record.fingerprint.starts_with("SHA256 "));
        assert_eq!(record.fingerprint.matches(':').count(), 31);
    }

    #[test]
    fn changed_host_key_requires_exact_confirmation_and_preserves_other_endpoints() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("known_hosts");
        let path = file.to_str().unwrap();
        let session = Session::new().unwrap();
        let verify = |host, port, key: &[u8], accepted: Option<&str>| {
            verify_host_key(&session, host, port, key, HostKeyType::Ed25519, path, accepted)
        };
        for (host, port) in [("127.0.0.1", 49326), ("127.0.0.1", 22), ("other.example", 49326)] {
            verify(host, port, b"old-key", Some(&host_key_fingerprint(b"old-key"))).unwrap();
        }
        let original = std::fs::read(&file).unwrap();
        for accepted in [None, Some(host_key_fingerprint(b"old-key")), Some(host_key_fingerprint(b"another-key"))] {
            let error = verify("127.0.0.1", 49326, b"new-key", accepted.as_deref()).unwrap_err();
            match error {
                CoreError::HostKeyMismatch { previous_fingerprints, fingerprint, .. } => {
                    assert_eq!(previous_fingerprints, vec![host_key_fingerprint(b"old-key")]);
                    assert_eq!(fingerprint, host_key_fingerprint(b"new-key"));
                }
                error => panic!("unexpected error: {error:?}"),
            }
            assert_eq!(std::fs::read(&file).unwrap(), original);
        }
        // A server changing again between prompt and reconnect must be rejected.
        assert!(matches!(
            verify("127.0.0.1", 49326, b"third-key", Some(&host_key_fingerprint(b"new-key"))),
            Err(CoreError::HostKeyMismatch { .. })
        ));
        assert_eq!(std::fs::read(&file).unwrap(), original);

        verify("127.0.0.1", 49326, b"new-key", Some(&host_key_fingerprint(b"new-key"))).unwrap();
        verify("127.0.0.1", 49326, b"new-key", None).unwrap();
        verify("127.0.0.1", 22, b"old-key", None).unwrap();
        verify("other.example", 49326, b"old-key", None).unwrap();
        assert!(matches!(verify("127.0.0.1", 49326, b"old-key", None), Err(CoreError::HostKeyMismatch { .. })));

        let mut stored = session.known_hosts().unwrap();
        stored.read_file(&file, KnownHostFileKind::OpenSSH).unwrap();
        assert_eq!(stored.hosts().unwrap().len(), 3);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(file).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn unknown_host_key_is_not_saved_without_confirmation() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("known_hosts");
        let session = Session::new().unwrap();
        let result = verify_host_key(&session, "test.example", 22, b"new-key", HostKeyType::Ed25519,
            file.to_str().unwrap(), None);
        assert!(matches!(result, Err(CoreError::HostKeyUnknown { .. })));
        assert!(!file.exists());
    }

    #[test]
    fn connection_security_maps_negotiated_methods_and_omits_empty_mac() {
        let security = connection_security_from_methods(
            "ssh-ed25519",
            "SHA256 aa:bb:cc",
            Some("curve25519-sha256"),
            Some("aes256-gcm@openssh.com"),
            Some("chacha20-poly1305@openssh.com"),
            Some("none"),
            Some("hmac-sha2-256"),
        );

        assert_eq!(security.host_key_algorithm, "ssh-ed25519");
        assert_eq!(security.host_key_fingerprint, "SHA256 aa:bb:cc");
        assert_eq!(security.key_exchange_algorithm, "curve25519-sha256");
        assert_eq!(security.client_to_server_cipher, "aes256-gcm@openssh.com");
        assert_eq!(
            security.server_to_client_cipher,
            "chacha20-poly1305@openssh.com"
        );
        assert_eq!(security.client_to_server_mac, None);
        assert_eq!(
            security.server_to_client_mac.as_deref(),
            Some("hmac-sha2-256")
        );

        let fallback =
            connection_security_from_methods("", "SHA256 unchanged", None, None, None, None, None);
        assert_eq!(fallback.host_key_algorithm, "unknown");
        assert_eq!(fallback.host_key_fingerprint, "SHA256 unchanged");
        assert_eq!(fallback.key_exchange_algorithm, "unknown");
    }

    #[test]
    fn terminal_connection_errors_keep_stage_context_without_credentials() {
        let io = io_connection_stage_error(
            "tcp_connect",
            std::io::Error::new(std::io::ErrorKind::ConnectionReset, "connection reset"),
        );
        let CoreError::Connection { message, stage } = io else {
            panic!("expected a connection error");
        };
        assert_eq!(stage.as_deref(), Some("tcp_connect"));
        assert!(message.contains("connection reset"));
        assert!(!message.contains("secret-password"));

        let ssh = ssh_connection_stage_error(
            "ssh_pty",
            ssh2::Error::from_errno(ssh2::ErrorCode::Session(-1)),
        );
        let CoreError::Connection { message, stage } = ssh else {
            panic!("expected a connection error");
        };
        assert_eq!(stage.as_deref(), Some("ssh_pty"));
        assert!(!message.contains("/Users/example/.ssh/id_ed25519"));
    }

    #[test]
    fn terminal_io_treats_libssh2_incoming_drain_as_transient() {
        assert!(terminal_io_would_block(&std::io::Error::new(
            std::io::ErrorKind::WouldBlock,
            "operation would block",
        )));
        assert!(terminal_io_would_block(&std::io::Error::other(
            "Failure while draining incoming flow",
        )));
        assert!(terminal_io_would_block(&std::io::Error::other(
            "transport read"
        )));
        assert!(!terminal_io_would_block(&std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "connection reset",
        )));
    }

    #[test]
    fn controlled_transfer_reports_progress_and_honors_cancel() {
        let payload = vec![7_u8; 1024 * 1024 + 9];
        let observer = RecordingObserver {
            updates: Mutex::new(Vec::new()),
        };
        let control = CoreTransferControl::new();
        let mut source = std::io::Cursor::new(payload.clone());
        let mut destination = Vec::new();
        copy_with_control(
            &mut source,
            &mut destination,
            payload.len() as u64,
            &control,
            &observer,
        )
        .unwrap();
        assert_eq!(destination, payload);
        assert_eq!(
            observer.updates.lock().unwrap().last().unwrap().0,
            payload.len() as u64
        );

        let cancelled = CoreTransferControl::new();
        cancelled.cancel();
        let mut source = std::io::Cursor::new(vec![1_u8; 16]);
        let mut destination = Vec::new();
        assert!(matches!(
            copy_with_control(&mut source, &mut destination, 16, &cancelled, &observer),
            Err(CoreError::TransferCancelled)
        ));
        assert!(destination.is_empty());
    }

    #[test]
    fn resumable_range_continues_after_existing_bytes() {
        let payload = b"0123456789abcdef".to_vec();
        let observer = RecordingObserver {
            updates: Mutex::new(Vec::new()),
        };
        let control = CoreTransferControl::new();
        let mut source = std::io::Cursor::new(payload.clone());
        source.seek(SeekFrom::Start(7)).unwrap();
        let mut destination = b"234".to_vec();
        copy_exact_range_with_control(&mut source, &mut destination, 3, 8, &control, &observer)
            .unwrap();
        assert_eq!(destination, b"234789ab");
        assert_eq!(observer.updates.lock().unwrap().last(), Some(&(8, 8)));
    }

    #[test]
    fn empty_upload_range_stays_empty_and_honors_cancellation() {
        let observer = RecordingObserver {
            updates: Mutex::new(Vec::new()),
        };
        let control = CoreTransferControl::new();
        let mut source = std::io::Cursor::new(Vec::<u8>::new());
        let mut destination = Vec::new();
        copy_exact_range_with_control(&mut source, &mut destination, 0, 0, &control, &observer)
            .unwrap();
        assert!(destination.is_empty());
        control.cancel();
        assert!(matches!(
            copy_exact_range_with_control(&mut source, &mut destination, 0, 0, &control, &observer),
            Err(CoreError::TransferCancelled)
        ));
    }

    #[test]
    fn upload_paths_require_safe_absolute_non_root_paths() {
        assert_eq!(
            validated_remote_upload_path("/srv/releases/.file.snake-part-0").unwrap(),
            "/srv/releases/.file.snake-part-0"
        );
        for unsafe_path in [
            "",
            "/",
            "relative",
            "/tmp/../etc",
            "/tmp\nname",
            "/tmp/name ",
        ] {
            assert!(matches!(
                validated_remote_upload_path(unsafe_path),
                Err(CoreError::InvalidInput { .. })
            ));
        }
    }

    #[test]
    fn recursive_chmod_uses_validated_mode_and_quoted_path() {
        assert_eq!(
            recursive_chmod_command("/srv/team's files", 0o750).unwrap(),
            "chmod -R 0750 -- '/srv/team'\"'\"'s files'"
        );
        assert!(matches!(
            recursive_chmod_command("/", 0o755),
            Err(CoreError::InvalidInput { .. })
        ));
        assert!(matches!(
            recursive_chmod_command("/srv/data", 0o10000),
            Err(CoreError::InvalidInput { .. })
        ));
    }
}
