//! Storage and remote execution for Snake's local MCP server.
//!
//! The Swift layer owns HTTP, token generation and credential lookup. This
//! module keeps token metadata, session bindings and the command audit trail in
//! SQLite, and runs one non-interactive command over a fresh SSH exec channel.
//! Token plaintext never reaches SQLite: only its SHA-256 and a display prefix.

use super::*;

/// Outputs kept in the audit trail. Callers still receive the larger result.
pub const AUDIT_EXCERPT_BYTES: usize = 16 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreMcpToken {
    pub id: String,
    pub name: String,
    pub token_prefix: String,
    pub created_at: i64,
    pub expires_at: Option<i64>,
    pub last_used_at: Option<i64>,
    pub revoked_at: Option<i64>,
    pub profile_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreMcpAuditRecord {
    pub id: String,
    pub token_id: Option<String>,
    pub token_name: String,
    pub profile_id: Option<String>,
    pub profile_label: String,
    pub client_name: String,
    pub command: String,
    pub cwd: Option<String>,
    /// Milliseconds since the Unix epoch.
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub duration_ms: Option<i64>,
    /// running, succeeded, failed, timeout, error or denied.
    pub status: String,
    pub exit_status: Option<i32>,
    pub error_message: Option<String>,
    pub stdout_excerpt: String,
    pub stderr_excerpt: String,
    pub stdout_bytes: i64,
    pub stderr_bytes: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreMcpAuditResult {
    pub finished_at: i64,
    pub duration_ms: i64,
    pub status: String,
    pub exit_status: Option<i32>,
    pub error_message: Option<String>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_bytes: i64,
    pub stderr_bytes: i64,
}

/// Every field narrows the selection; an empty filter selects everything.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct CoreMcpAuditFilter {
    pub token_id: Option<String>,
    pub profile_id: Option<String>,
    pub status: Option<String>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub ids: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreCommandOutput {
    pub exit_status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_total_bytes: u64,
    pub stderr_total_bytes: u64,
    pub timed_out: bool,
    pub duration_ms: u64,
}

const AUDIT_STATUSES: [&str; 6] = ["running", "succeeded", "failed", "timeout", "error", "denied"];

impl SnakeStore {
    pub(crate) fn migrate_mcp(&self) -> Result<(), SnakeCoreError> {
        self.connection.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS mcp_tokens (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                token_prefix TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER,
                last_used_at INTEGER,
                revoked_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS mcp_token_profiles (
                token_id TEXT NOT NULL REFERENCES mcp_tokens(id) ON DELETE CASCADE,
                profile_id TEXT NOT NULL REFERENCES ssh_profiles(id) ON DELETE CASCADE,
                PRIMARY KEY(token_id, profile_id)
            );
            CREATE TABLE IF NOT EXISTS mcp_command_audit (
                id TEXT PRIMARY KEY NOT NULL,
                token_id TEXT,
                token_name TEXT NOT NULL,
                profile_id TEXT,
                profile_label TEXT NOT NULL,
                client_name TEXT NOT NULL DEFAULT '',
                command TEXT NOT NULL,
                cwd TEXT,
                started_at INTEGER NOT NULL,
                finished_at INTEGER,
                duration_ms INTEGER,
                status TEXT NOT NULL,
                exit_status INTEGER,
                error_message TEXT,
                stdout_excerpt TEXT NOT NULL DEFAULT '',
                stderr_excerpt TEXT NOT NULL DEFAULT '',
                stdout_bytes INTEGER NOT NULL DEFAULT 0,
                stderr_bytes INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS mcp_audit_started ON mcp_command_audit(started_at);
            CREATE INDEX IF NOT EXISTS mcp_audit_token ON mcp_command_audit(token_id);
            CREATE INDEX IF NOT EXISTS mcp_audit_profile ON mcp_command_audit(profile_id);
            -- A command still running when Snake quit can never report a result.
            UPDATE mcp_command_audit SET status = 'error', error_message = 'interrupted: Snake exited'
            WHERE status = 'running';
            INSERT OR IGNORE INTO schema_migrations(version) VALUES (3);
            ",
        )?;
        Ok(())
    }

    fn mcp_token_profiles(&self, token_id: &str) -> Result<Vec<String>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT profile_id FROM mcp_token_profiles WHERE token_id = ?1 ORDER BY profile_id",
        )?;
        let rows = statement.query_map(params![token_id], |row| row.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn mcp_token_from_row(&self, row: &rusqlite::Row<'_>) -> rusqlite::Result<CoreMcpToken> {
        Ok(CoreMcpToken {
            id: row.get(0)?,
            name: row.get(1)?,
            token_prefix: row.get(2)?,
            created_at: row.get(3)?,
            expires_at: row.get(4)?,
            last_used_at: row.get(5)?,
            revoked_at: row.get(6)?,
            profile_ids: Vec::new(),
        })
    }

    pub fn mcp_tokens(&self) -> Result<Vec<CoreMcpToken>, SnakeCoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, name, token_prefix, created_at, expires_at, last_used_at, revoked_at
             FROM mcp_tokens ORDER BY created_at, id",
        )?;
        let tokens = statement
            .query_map([], |row| self.mcp_token_from_row(row))?
            .collect::<Result<Vec<_>, _>>()?;
        tokens
            .into_iter()
            .map(|mut token| {
                token.profile_ids = self.mcp_token_profiles(&token.id)?;
                Ok(token)
            })
            .collect()
    }

    pub fn mcp_token_by_hash(&self, token_hash: &str) -> Result<Option<CoreMcpToken>, SnakeCoreError> {
        let found = self
            .connection
            .query_row(
                "SELECT id, name, token_prefix, created_at, expires_at, last_used_at, revoked_at, token_hash
                 FROM mcp_tokens WHERE token_hash = ?1",
                params![token_hash],
                |row| Ok((self.mcp_token_from_row(row)?, row.get::<_, String>(7)?)),
            )
            .optional()?;
        // The index lookup already matched; compare again without early exit so
        // a future change to the lookup cannot introduce a timing oracle.
        let Some((mut token, stored)) = found else { return Ok(None) };
        if !constant_time_eq(stored.as_bytes(), token_hash.as_bytes()) {
            return Ok(None);
        }
        token.profile_ids = self.mcp_token_profiles(&token.id)?;
        Ok(Some(token))
    }

    pub fn create_mcp_token(
        &mut self,
        token: &CoreMcpToken,
        token_hash: &str,
    ) -> Result<(), SnakeCoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO mcp_tokens(id, name, token_hash, token_prefix, created_at, expires_at)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![token.id, token.name, token_hash, token.token_prefix, token.created_at, token.expires_at],
        )?;
        for profile_id in &token.profile_ids {
            transaction.execute(
                "INSERT OR IGNORE INTO mcp_token_profiles(token_id, profile_id) VALUES(?1, ?2)",
                params![token.id, profile_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn update_mcp_token(
        &mut self,
        id: &str,
        name: &str,
        expires_at: Option<i64>,
        profile_ids: &[String],
    ) -> Result<(), SnakeCoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE mcp_tokens SET name = ?2, expires_at = ?3 WHERE id = ?1",
            params![id, name, expires_at],
        )?;
        transaction.execute("DELETE FROM mcp_token_profiles WHERE token_id = ?1", params![id])?;
        for profile_id in profile_ids {
            transaction.execute(
                "INSERT OR IGNORE INTO mcp_token_profiles(token_id, profile_id) VALUES(?1, ?2)",
                params![id, profile_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn set_mcp_token_revoked(&self, id: &str, revoked_at: Option<i64>) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "UPDATE mcp_tokens SET revoked_at = ?2 WHERE id = ?1",
            params![id, revoked_at],
        )?;
        Ok(())
    }

    pub fn touch_mcp_token(&self, id: &str, used_at: i64) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "UPDATE mcp_tokens SET last_used_at = ?2 WHERE id = ?1",
            params![id, used_at],
        )?;
        Ok(())
    }

    /// Audit rows keep their token name snapshot after the token is deleted.
    pub fn delete_mcp_token(&self, id: &str) -> Result<(), SnakeCoreError> {
        self.connection.execute("DELETE FROM mcp_tokens WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn insert_mcp_audit(&self, record: &CoreMcpAuditRecord) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "INSERT INTO mcp_command_audit(id, token_id, token_name, profile_id, profile_label, client_name,
                command, cwd, started_at, finished_at, duration_ms, status, exit_status, error_message,
                stdout_excerpt, stderr_excerpt, stdout_bytes, stderr_bytes)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            params![
                record.id, record.token_id, record.token_name, record.profile_id, record.profile_label,
                record.client_name, record.command, record.cwd, record.started_at, record.finished_at,
                record.duration_ms, record.status, record.exit_status, record.error_message,
                excerpt(record.stdout_excerpt.as_bytes()), excerpt(record.stderr_excerpt.as_bytes()),
                record.stdout_bytes, record.stderr_bytes,
            ],
        )?;
        Ok(())
    }

    pub fn finish_mcp_audit(&self, id: &str, result: &CoreMcpAuditResult) -> Result<(), SnakeCoreError> {
        self.connection.execute(
            "UPDATE mcp_command_audit SET finished_at = ?2, duration_ms = ?3, status = ?4, exit_status = ?5,
                error_message = ?6, stdout_excerpt = ?7, stderr_excerpt = ?8, stdout_bytes = ?9, stderr_bytes = ?10
             WHERE id = ?1 AND status = 'running'",
            params![
                id, result.finished_at, result.duration_ms, result.status, result.exit_status,
                result.error_message, excerpt(&result.stdout), excerpt(&result.stderr),
                result.stdout_bytes, result.stderr_bytes,
            ],
        )?;
        Ok(())
    }

    pub fn mcp_audit(
        &self,
        filter: &CoreMcpAuditFilter,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CoreMcpAuditRecord>, SnakeCoreError> {
        let (clause, values) = audit_where(filter);
        let sql = format!(
            "SELECT id, token_id, token_name, profile_id, profile_label, client_name, command, cwd, started_at,
                finished_at, duration_ms, status, exit_status, error_message, stdout_excerpt, stderr_excerpt,
                stdout_bytes, stderr_bytes
             FROM mcp_command_audit {clause} ORDER BY started_at DESC, id DESC LIMIT {limit} OFFSET {offset}"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(rusqlite::params_from_iter(values.iter()), |row| {
            Ok(CoreMcpAuditRecord {
                id: row.get(0)?,
                token_id: row.get(1)?,
                token_name: row.get(2)?,
                profile_id: row.get(3)?,
                profile_label: row.get(4)?,
                client_name: row.get(5)?,
                command: row.get(6)?,
                cwd: row.get(7)?,
                started_at: row.get(8)?,
                finished_at: row.get(9)?,
                duration_ms: row.get(10)?,
                status: row.get(11)?,
                exit_status: row.get(12)?,
                error_message: row.get(13)?,
                stdout_excerpt: row.get(14)?,
                stderr_excerpt: row.get(15)?,
                stdout_bytes: row.get(16)?,
                stderr_bytes: row.get(17)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn mcp_audit_count(&self, filter: &CoreMcpAuditFilter) -> Result<i64, SnakeCoreError> {
        let (clause, values) = audit_where(filter);
        Ok(self.connection.query_row(
            &format!("SELECT COUNT(*) FROM mcp_command_audit {clause}"),
            rusqlite::params_from_iter(values.iter()),
            |row| row.get(0),
        )?)
    }

    /// Manual deletion. Running rows are kept so an active command still has
    /// somewhere to report its result.
    pub fn delete_mcp_audit(&self, filter: &CoreMcpAuditFilter) -> Result<u64, SnakeCoreError> {
        let (clause, values) = audit_where(filter);
        let guard = if clause.is_empty() { "WHERE" } else { "AND" };
        let removed = self.connection.execute(
            &format!("DELETE FROM mcp_command_audit {clause} {guard} status != 'running'"),
            rusqlite::params_from_iter(values.iter()),
        )?;
        Ok(removed as u64)
    }

    /// Rolling deletion: drops finished rows older than `retention_days` and
    /// then the oldest finished rows beyond `max_records`. Zero disables a rule.
    pub fn prune_mcp_audit(
        &mut self,
        now_ms: i64,
        retention_days: u32,
        max_records: u32,
    ) -> Result<u64, SnakeCoreError> {
        let transaction = self.connection.transaction()?;
        let mut removed = 0;
        if retention_days > 0 {
            let cutoff = now_ms - i64::from(retention_days) * 86_400_000;
            removed += transaction.execute(
                "DELETE FROM mcp_command_audit WHERE started_at < ?1 AND status != 'running'",
                params![cutoff],
            )?;
        }
        if max_records > 0 {
            removed += transaction.execute(
                "DELETE FROM mcp_command_audit WHERE id IN (
                    SELECT id FROM mcp_command_audit WHERE status != 'running'
                    ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET ?1)",
                params![i64::from(max_records)],
            )?;
        }
        transaction.commit()?;
        Ok(removed as u64)
    }
}

fn audit_where(filter: &CoreMcpAuditFilter) -> (String, Vec<rusqlite::types::Value>) {
    use rusqlite::types::Value;
    let mut conditions = Vec::new();
    let mut values = Vec::new();
    let mut push = |condition: &str, value: Value| {
        values.push(value);
        conditions.push(condition.replace('?', &format!("?{}", values.len())));
    };
    if let Some(token_id) = &filter.token_id {
        push("token_id = ?", Value::Text(token_id.clone()));
    }
    if let Some(profile_id) = &filter.profile_id {
        push("profile_id = ?", Value::Text(profile_id.clone()));
    }
    if let Some(status) = &filter.status {
        push("status = ?", Value::Text(status.clone()));
    }
    if let Some(since) = filter.since {
        push("started_at >= ?", Value::Integer(since));
    }
    if let Some(until) = filter.until {
        push("started_at < ?", Value::Integer(until));
    }
    if let Some(ids) = &filter.ids {
        if ids.is_empty() {
            conditions.push("0".to_owned());
        } else {
            let start = values.len();
            values.extend(ids.iter().cloned().map(Value::Text));
            let placeholders = (start + 1..=values.len()).map(|index| format!("?{index}")).collect::<Vec<_>>();
            conditions.push(format!("id IN ({})", placeholders.join(",")));
        }
    }
    if conditions.is_empty() {
        (String::new(), values)
    } else {
        (format!("WHERE {}", conditions.join(" AND ")), values)
    }
}

/// Keeps the first bytes that form valid UTF-8 and replaces invalid sequences.
fn excerpt(bytes: &[u8]) -> String {
    let mut end = bytes.len().min(AUDIT_EXCERPT_BYTES);
    while end > 0 && end < bytes.len() && (bytes[end] & 0b1100_0000) == 0b1000_0000 {
        end -= 1;
    }
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter().zip(right).fold(0_u8, |difference, (a, b)| difference | (a ^ b)) == 0
}

fn validate_audit_status(status: &str) -> Result<(), CoreError> {
    if AUDIT_STATUSES.contains(&status) {
        Ok(())
    } else {
        Err(CoreError::InvalidInput { message: format!("unknown audit status `{status}`") })
    }
}

/// Profiles are stored with `Uuid::to_string()` (lowercase), while Swift sends
/// `uuidString` (uppercase). Every identifier is normalized at the boundary so
/// foreign keys and filters compare equal values.
fn canonical(value: &str) -> Result<String, CoreError> {
    parse_identifier(value).map(|id| id.to_string())
}

fn canonical_all(values: &[String]) -> Result<Vec<String>, CoreError> {
    values.iter().map(|value| canonical(value)).collect()
}

fn canonical_filter(filter: CoreMcpAuditFilter) -> Result<CoreMcpAuditFilter, CoreError> {
    Ok(CoreMcpAuditFilter {
        token_id: filter.token_id.as_deref().map(canonical).transpose()?,
        profile_id: filter.profile_id.as_deref().map(canonical).transpose()?,
        ids: filter.ids.as_deref().map(canonical_all).transpose()?,
        ..filter
    })
}

#[uniffi::export]
impl CoreDatabase {
    pub fn mcp_tokens(&self) -> Result<Vec<CoreMcpToken>, CoreError> {
        self.with_store(|store| store.mcp_tokens())
    }

    pub fn mcp_token_by_hash(&self, token_hash: String) -> Result<Option<CoreMcpToken>, CoreError> {
        self.with_store(|store| store.mcp_token_by_hash(&token_hash))
    }

    pub fn create_mcp_token(&self, token: CoreMcpToken, token_hash: String) -> Result<(), CoreError> {
        if token.name.trim().is_empty() || token_hash.len() != 64 {
            return Err(CoreError::InvalidInput { message: "token name and SHA-256 hash are required".to_owned() });
        }
        let token = CoreMcpToken { id: canonical(&token.id)?, profile_ids: canonical_all(&token.profile_ids)?, ..token };
        let mut store = self.store.lock().map_err(|_| CoreError::StorageLock)?;
        store.create_mcp_token(&token, &token_hash).map_err(Into::into)
    }

    pub fn update_mcp_token(
        &self,
        id: String,
        name: String,
        expires_at: Option<i64>,
        profile_ids: Vec<String>,
    ) -> Result<(), CoreError> {
        let (id, profile_ids) = (canonical(&id)?, canonical_all(&profile_ids)?);
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput { message: "token name is required".to_owned() });
        }
        let mut store = self.store.lock().map_err(|_| CoreError::StorageLock)?;
        store.update_mcp_token(&id, &name, expires_at, &profile_ids).map_err(Into::into)
    }

    pub fn set_mcp_token_revoked(&self, id: String, revoked_at: Option<i64>) -> Result<(), CoreError> {
        let id = canonical(&id)?;
        self.with_store(|store| store.set_mcp_token_revoked(&id, revoked_at))
    }

    pub fn touch_mcp_token(&self, id: String, used_at: i64) -> Result<(), CoreError> {
        let id = canonical(&id)?;
        self.with_store(|store| store.touch_mcp_token(&id, used_at))
    }

    pub fn delete_mcp_token(&self, id: String) -> Result<(), CoreError> {
        let id = canonical(&id)?;
        self.with_store(|store| store.delete_mcp_token(&id))
    }

    pub fn insert_mcp_audit(&self, record: CoreMcpAuditRecord) -> Result<(), CoreError> {
        validate_audit_status(&record.status)?;
        let record = CoreMcpAuditRecord {
            id: canonical(&record.id)?,
            token_id: record.token_id.as_deref().map(canonical).transpose()?,
            profile_id: record.profile_id.as_deref().map(canonical).transpose()?,
            ..record
        };
        self.with_store(|store| store.insert_mcp_audit(&record))
    }

    pub fn finish_mcp_audit(&self, id: String, result: CoreMcpAuditResult) -> Result<(), CoreError> {
        validate_audit_status(&result.status)?;
        let id = canonical(&id)?;
        self.with_store(|store| store.finish_mcp_audit(&id, &result))
    }

    pub fn mcp_audit(
        &self,
        filter: CoreMcpAuditFilter,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CoreMcpAuditRecord>, CoreError> {
        let filter = canonical_filter(filter)?;
        self.with_store(|store| store.mcp_audit(&filter, limit.min(10_000), offset))
    }

    pub fn mcp_audit_count(&self, filter: CoreMcpAuditFilter) -> Result<i64, CoreError> {
        let filter = canonical_filter(filter)?;
        self.with_store(|store| store.mcp_audit_count(&filter))
    }

    pub fn delete_mcp_audit(&self, filter: CoreMcpAuditFilter) -> Result<u64, CoreError> {
        let filter = canonical_filter(filter)?;
        self.with_store(|store| store.delete_mcp_audit(&filter))
    }

    pub fn prune_mcp_audit(&self, now_ms: i64, retention_days: u32, max_records: u32) -> Result<u64, CoreError> {
        let mut store = self.store.lock().map_err(|_| CoreError::StorageLock)?;
        store.prune_mcp_audit(now_ms, retention_days, max_records).map_err(Into::into)
    }
}

/// Runs `command` once over a fresh connection authenticated with a password.
/// The host key must already be trusted; an unknown key fails rather than
/// prompting, because no person is present to compare fingerprints.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn run_command_password(
    host: String,
    port: u16,
    username: String,
    password: Vec<u8>,
    known_hosts_path: String,
    command: String,
    cwd: Option<String>,
    timeout_ms: u64,
    max_output_bytes: u64,
) -> Result<CoreCommandOutput, CoreError> {
    let started = std::time::Instant::now();
    let session = trusted_session(&host, port, &known_hosts_path)?;
    let password = Zeroizing::new(String::from_utf8(password).map_err(|_| CoreError::Authentication {
        message: String::new(),
        stage: Some("auth_password_encoding_invalid".to_owned()),
    })?);
    session
        .userauth_password(&username, password.as_str())
        .map_err(|error| authentication_stage_error("auth_password", error))?;
    execute_command(session, &command, cwd.as_deref(), started, timeout_ms, max_output_bytes)
}

#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn run_command_private_key(
    host: String,
    port: u16,
    username: String,
    private_key_path: String,
    passphrase: Option<Vec<u8>>,
    known_hosts_path: String,
    command: String,
    cwd: Option<String>,
    timeout_ms: u64,
    max_output_bytes: u64,
) -> Result<CoreCommandOutput, CoreError> {
    let started = std::time::Instant::now();
    let session = trusted_session(&host, port, &known_hosts_path)?;
    let passphrase = passphrase
        .map(|bytes| String::from_utf8(bytes).map(Zeroizing::new))
        .transpose()
        .map_err(|_| CoreError::Authentication {
            message: String::new(),
            stage: Some("auth_private_key_passphrase_invalid".to_owned()),
        })?;
    session
        .userauth_pubkey_file(&username, None, Path::new(&private_key_path), passphrase.as_deref().map(String::as_str))
        .map_err(|error| authentication_stage_error("auth_private_key", error))?;
    execute_command(session, &command, cwd.as_deref(), started, timeout_ms, max_output_bytes)
}

fn trusted_session(host: &str, port: u16, known_hosts_path: &str) -> Result<Session, CoreError> {
    let (session, key, kind, _stream) = handshake(host, port)?;
    verify_host_key(&session, host, port, &key, kind, known_hosts_path, None)?;
    Ok(session)
}

/// The script runs in the remote `/bin/sh` rather than the login shell, so
/// tools see one predictable POSIX dialect whether the account uses bash, zsh
/// or fish. The login shell only has to understand `exec /bin/sh -s`.
fn command_script(command: &str, cwd: Option<&str>) -> Result<String, CoreError> {
    if command.trim().is_empty() {
        return Err(CoreError::InvalidInput { message: "command is empty".to_owned() });
    }
    let mut script = String::from("printf '%s\\n' \"$$\"\n");
    if let Some(cwd) = cwd {
        if !cwd.starts_with('/') || cwd.chars().any(char::is_control) {
            return Err(CoreError::InvalidInput { message: "cwd must be an absolute path".to_owned() });
        }
        script.push_str(&format!("cd -- {} || exit 126\n", shell_single_quote(cwd)));
    }
    // The braces make sh parse the whole command before running it, and the
    // redirect keeps a command that reads stdin from consuming the script.
    script.push_str("{\n");
    script.push_str(command);
    script.push_str("\n} </dev/null\n");
    Ok(script)
}

fn execute_command(
    session: Session,
    command: &str,
    cwd: Option<&str>,
    started: std::time::Instant,
    timeout_ms: u64,
    max_output_bytes: u64,
) -> Result<CoreCommandOutput, CoreError> {
    if !session.authenticated() {
        return Err(CoreError::Authentication {
            message: "server rejected the supplied credential".to_owned(),
            stage: None,
        });
    }
    let script = command_script(command, cwd)?;
    let deadline = started + std::time::Duration::from_millis(timeout_ms.max(1));
    let limit = usize::try_from(max_output_bytes).unwrap_or(usize::MAX);
    let mut channel = session
        .channel_session()
        .map_err(|error| ssh_connection_stage_error("ssh_channel", error))?;
    channel
        .exec("exec /bin/sh -s")
        .map_err(|error| ssh_connection_stage_error("ssh_exec", error))?;
    channel.write_all(script.as_bytes()).map_err(io_error)?;
    channel.send_eof().map_err(|error| ssh_connection_stage_error("ssh_exec", error))?;
    session.set_blocking(false);

    // The first stdout line is the remote shell's PID, used to stop it on timeout.
    let mut pid_line = Vec::new();
    let mut pid_complete = false;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let (mut stdout_total, mut stderr_total) = (0_u64, 0_u64);
    let mut buffer = vec![0_u8; 32 * 1024];
    let mut timed_out = false;
    loop {
        let mut progressed = false;
        for is_stderr in [false, true] {
            let read = if is_stderr { channel.stderr().read(&mut buffer) } else { channel.read(&mut buffer) };
            let mut data = match read {
                Ok(0) => continue,
                Ok(count) => &buffer[..count],
                Err(error) if terminal_io_would_block(&error) => continue,
                Err(error) => return Err(io_error(error)),
            };
            progressed = true;
            if !is_stderr && !pid_complete {
                match data.iter().position(|byte| *byte == b'\n') {
                    Some(end) => {
                        pid_line.extend_from_slice(&data[..end]);
                        pid_complete = true;
                        data = &data[end + 1..];
                    }
                    None => {
                        pid_line.extend_from_slice(data);
                        continue;
                    }
                }
            }
            let (kept, total) = if is_stderr { (&mut stderr, &mut stderr_total) } else { (&mut stdout, &mut stdout_total) };
            *total += data.len() as u64;
            let room = limit.saturating_sub(kept.len());
            kept.extend_from_slice(&data[..data.len().min(room)]);
        }
        if channel.eof() && !progressed {
            break;
        }
        if std::time::Instant::now() >= deadline {
            timed_out = true;
            break;
        }
        if !progressed {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    session.set_blocking(true);
    session.set_timeout(2_000);
    let exit_status = if timed_out {
        // Without a PTY sshd does not hang up the command when the channel
        // closes, so stop the shell and its direct children explicitly.
        let pid = std::str::from_utf8(&pid_line).ok().and_then(|value| value.trim().parse::<u32>().ok());
        if let Some(pid) = pid.filter(|pid| *pid > 1) {
            if let Ok(mut killer) = session.channel_session() {
                let _ = killer.exec(&format!("pkill -TERM -P {pid} 2>/dev/null; kill -TERM {pid} 2>/dev/null"));
                let _ = killer.wait_close();
            }
        }
        let _ = channel.close();
        None
    } else {
        let _ = channel.wait_close();
        channel.exit_status().ok()
    };
    let _ = session.disconnect(None, "done", None);
    Ok(CoreCommandOutput {
        exit_status,
        stdout,
        stderr,
        stdout_total_bytes: stdout_total,
        stderr_total_bytes: stderr_total,
        timed_out,
        duration_ms: started.elapsed().as_millis() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> SnakeStore {
        let store = SnakeStore::open(":memory:").unwrap();
        for id in [PROFILE_A, PROFILE_B] {
            store
                .connection
                .execute(
                    "INSERT INTO ssh_profiles(id, name, host, port, username, auth_method) VALUES(?1, 'p', 'h', 22, 'u', 'password')",
                    params![id],
                )
                .unwrap();
        }
        store
    }

    const PROFILE_A: &str = "11111111-1111-4111-8111-111111111111";
    const PROFILE_B: &str = "22222222-2222-4222-8222-222222222222";
    const TOKEN: &str = "33333333-3333-4333-8333-333333333333";

    fn token(profile_ids: &[&str]) -> CoreMcpToken {
        CoreMcpToken {
            id: TOKEN.to_owned(),
            name: "agent".to_owned(),
            token_prefix: "snk_abcd".to_owned(),
            created_at: 1,
            expires_at: None,
            last_used_at: None,
            revoked_at: None,
            profile_ids: profile_ids.iter().map(|id| (*id).to_owned()).collect(),
        }
    }

    fn audit(id: u32, started_at: i64, status: &str) -> CoreMcpAuditRecord {
        CoreMcpAuditRecord {
            id: format!("00000000-0000-4000-8000-{id:012}"),
            token_id: Some(TOKEN.to_owned()),
            token_name: "agent".to_owned(),
            profile_id: Some(PROFILE_A.to_owned()),
            profile_label: "u@h:22".to_owned(),
            client_name: "test".to_owned(),
            command: format!("echo {id}"),
            cwd: None,
            started_at,
            finished_at: None,
            duration_ms: None,
            status: status.to_owned(),
            exit_status: None,
            error_message: None,
            stdout_excerpt: String::new(),
            stderr_excerpt: String::new(),
            stdout_bytes: 0,
            stderr_bytes: 0,
        }
    }

    #[test]
    fn tokens_bind_profiles_and_follow_profile_deletion() {
        let mut store = store();
        let hash = "a".repeat(64);
        store.create_mcp_token(&token(&[PROFILE_A, PROFILE_B]), &hash).unwrap();
        let found = store.mcp_token_by_hash(&hash).unwrap().unwrap();
        assert_eq!(found.profile_ids, vec![PROFILE_A, PROFILE_B]);
        assert!(store.mcp_token_by_hash(&"b".repeat(64)).unwrap().is_none());

        store.connection.execute("DELETE FROM ssh_profiles WHERE id = ?1", params![PROFILE_B]).unwrap();
        assert_eq!(store.mcp_tokens().unwrap()[0].profile_ids, vec![PROFILE_A]);

        store.update_mcp_token(TOKEN, "renamed", Some(9), &[]).unwrap();
        let updated = &store.mcp_tokens().unwrap()[0];
        assert_eq!((updated.name.as_str(), updated.expires_at, updated.profile_ids.len()), ("renamed", Some(9), 0));

        store.insert_mcp_audit(&audit(1, 10, "succeeded")).unwrap();
        store.delete_mcp_token(TOKEN).unwrap();
        let kept = store.mcp_audit(&CoreMcpAuditFilter::default(), 10, 0).unwrap();
        assert_eq!(kept[0].token_name, "agent", "audit keeps the snapshot after deletion");
    }

    #[test]
    fn rolling_deletion_keeps_running_rows_and_newest_records() {
        let mut store = store();
        let day = 86_400_000;
        for (index, started) in [0, day, 5 * day, 6 * day, 7 * day].into_iter().enumerate() {
            store.insert_mcp_audit(&audit(index as u32, started, "succeeded")).unwrap();
        }
        store.insert_mcp_audit(&audit(9, 0, "running")).unwrap();

        // Three days of retention at day 7 removes the day 0 and day 1 rows.
        assert_eq!(store.prune_mcp_audit(7 * day, 3, 0).unwrap(), 2);
        // Keep only the two newest finished rows.
        assert_eq!(store.prune_mcp_audit(7 * day, 0, 2).unwrap(), 1);
        let left = store.mcp_audit(&CoreMcpAuditFilter::default(), 10, 0).unwrap();
        let commands: Vec<_> = left.iter().map(|row| row.command.as_str()).collect();
        assert_eq!(commands, vec!["echo 4", "echo 3", "echo 9"]);
        assert_eq!(store.prune_mcp_audit(7 * day, 0, 0).unwrap(), 0, "zero disables both rules");
    }

    #[test]
    fn audit_filters_finish_and_manual_deletion() {
        let store = store();
        store.insert_mcp_audit(&audit(1, 10, "running")).unwrap();
        store.insert_mcp_audit(&audit(2, 20, "denied")).unwrap();
        let big = vec![b'x'; AUDIT_EXCERPT_BYTES + 10];
        store
            .finish_mcp_audit(&audit(1, 0, "").id, &CoreMcpAuditResult {
                finished_at: 30, duration_ms: 20, status: "failed".to_owned(), exit_status: Some(2),
                error_message: None, stdout: big.clone(), stderr: "错误".as_bytes().to_vec(),
                stdout_bytes: big.len() as i64, stderr_bytes: 6,
            })
            .unwrap();
        let failed = CoreMcpAuditFilter { status: Some("failed".to_owned()), ..Default::default() };
        let row = &store.mcp_audit(&failed, 10, 0).unwrap()[0];
        assert_eq!((row.exit_status, row.stdout_excerpt.len(), row.stderr_excerpt.as_str()), (Some(2), AUDIT_EXCERPT_BYTES, "错误"));
        assert_eq!(store.mcp_audit_count(&CoreMcpAuditFilter { since: Some(15), ..Default::default() }).unwrap(), 1);

        let by_id = CoreMcpAuditFilter { ids: Some(vec![audit(2, 0, "").id]), ..Default::default() };
        assert_eq!(store.delete_mcp_audit(&by_id).unwrap(), 1);
        assert_eq!(store.delete_mcp_audit(&CoreMcpAuditFilter { ids: Some(vec![]), ..Default::default() }).unwrap(), 0);
        assert_eq!(store.delete_mcp_audit(&CoreMcpAuditFilter::default()).unwrap(), 1);
        assert_eq!(store.mcp_audit_count(&CoreMcpAuditFilter::default()).unwrap(), 0);
    }

    #[test]
    fn command_script_quotes_cwd_and_isolates_stdin() {
        let script = command_script("cat; echo done", Some("/tmp/it's here")).unwrap();
        assert_eq!(script, "printf '%s\\n' \"$$\"\ncd -- '/tmp/it'\"'\"'s here' || exit 126\n{\ncat; echo done\n} </dev/null\n");
        assert!(command_script("  ", None).is_err());
        assert!(command_script("ls", Some("relative")).is_err());
    }

    #[test]
    fn database_boundary_normalizes_uppercase_identifiers() {
        let database = CoreDatabase::open(":memory:".to_owned()).unwrap();
        database.with_store(|store| {
            store.connection.execute(
                "INSERT INTO ssh_profiles(id, name, host, port, username, auth_method) VALUES(?1, 'p', 'h', 22, 'u', 'password')",
                params![PROFILE_A],
            )?;
            Ok(())
        }).unwrap();
        let upper = |value: &str| value.to_uppercase();
        let mut created = token(&[PROFILE_A]);
        created.id = upper(TOKEN);
        created.profile_ids = vec![upper(PROFILE_A)];
        database.create_mcp_token(created, "c".repeat(64)).unwrap();
        database.set_mcp_token_revoked(upper(TOKEN), Some(5)).unwrap();
        let stored = &database.mcp_tokens().unwrap()[0];
        assert_eq!((stored.id.as_str(), stored.profile_ids[0].as_str(), stored.revoked_at), (TOKEN, PROFILE_A, Some(5)));

        let mut record = audit(1, 1, "succeeded");
        record.id = record.id.to_uppercase();
        record.token_id = Some(upper(TOKEN));
        database.insert_mcp_audit(record).unwrap();
        let by_token = CoreMcpAuditFilter { token_id: Some(upper(TOKEN)), ..Default::default() };
        assert_eq!(database.mcp_audit_count(by_token).unwrap(), 1);
        assert!(database.insert_mcp_audit(audit(2, 1, "bogus")).is_err());
    }

    #[test]
    fn excerpt_never_splits_a_utf8_character() {
        let mut bytes = vec![b'a'; AUDIT_EXCERPT_BYTES - 1];
        bytes.extend_from_slice("中文".as_bytes());
        assert_eq!(excerpt(&bytes).len(), AUDIT_EXCERPT_BYTES - 1);
    }
}
