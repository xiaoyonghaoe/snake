//! Blocking SFTP façade over russh-sftp with the subset of the former ssh2
//! `Sftp`/`File` API that Snake's transfer code uses. File reads and writes
//! split each buffer into several in-flight SFTP requests (pipelining), which
//! is where SFTP throughput comes from on high-latency links.

use super::ssh::{block_on, Connection, SshError};
use russh_sftp::client::rawsession::Limits;
use russh_sftp::client::RawSftpSession;
use russh_sftp::protocol::{FileAttributes, OpenFlags as WireOpenFlags, StatusCode};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Result<T> = std::result::Result<T, SshError>;

/// Per-request payload without a `limits@openssh.com` answer.
const DEFAULT_CHUNK: u64 = 32 * 1024;
/// Upper bound even when the server allows more (OpenSSH: 255 KiB), keeping
/// each SFTP packet well inside russh-sftp's 256 KiB packet limit.
const MAX_CHUNK: u64 = 128 * 1024;
/// Each request waits up to this long for its reply.
const REQUEST_TIMEOUT_SECONDS: u64 = 120;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct OpenFlags(u32);

impl OpenFlags {
    pub(crate) const READ: Self = Self(WireOpenFlags::READ.bits());
    pub(crate) const WRITE: Self = Self(WireOpenFlags::WRITE.bits());
    pub(crate) const CREATE: Self = Self(WireOpenFlags::CREATE.bits());
    pub(crate) const TRUNCATE: Self = Self(WireOpenFlags::TRUNCATE.bits());
    pub(crate) const EXCLUSIVE: Self = Self(WireOpenFlags::EXCLUDE.bits());
}

impl std::ops::BitOr for OpenFlags {
    type Output = Self;
    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

pub(crate) enum OpenType {
    File,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct FileStat {
    pub(crate) size: Option<u64>,
    pub(crate) uid: Option<u32>,
    pub(crate) gid: Option<u32>,
    /// Full `st_mode`, including the file type bits.
    pub(crate) perm: Option<u32>,
    pub(crate) atime: Option<u64>,
    pub(crate) mtime: Option<u64>,
}

pub(crate) struct FileType(u32);

impl FileType {
    pub(crate) fn is_symlink(&self) -> bool {
        self.0 == 0o120000
    }
}

impl FileStat {
    fn kind(&self) -> u32 {
        self.perm.unwrap_or_default() & 0o170000
    }

    pub(crate) fn file_type(&self) -> FileType {
        FileType(self.kind())
    }

    pub(crate) fn is_dir(&self) -> bool {
        self.kind() == 0o040000
    }

    pub(crate) fn is_file(&self) -> bool {
        self.kind() == 0o100000
    }

    fn from_attributes(attributes: &FileAttributes) -> Self {
        Self {
            size: attributes.size,
            uid: attributes.uid,
            gid: attributes.gid,
            perm: attributes.permissions,
            atime: attributes.atime.map(u64::from),
            mtime: attributes.mtime.map(u64::from),
        }
    }

    fn attributes(&self) -> FileAttributes {
        let mut attributes = FileAttributes::empty();
        attributes.size = self.size;
        attributes.uid = self.uid;
        attributes.gid = self.gid;
        attributes.permissions = self.perm;
        attributes.atime = self.atime.map(|value| value as u32);
        attributes.mtime = self.mtime.map(|value| value as u32);
        attributes
    }
}

fn wire_path(path: &Path) -> Result<String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| SshError("remote path is not valid UTF-8".to_owned()))
}

pub(crate) struct Sftp {
    raw: Arc<RawSftpSession>,
    read_chunk: u64,
    write_chunk: u64,
    supports_posix_rename: bool,
    // Keeps the SSH connection alive for as long as the subsystem is used.
    _connection: Arc<Connection>,
}

impl Sftp {
    pub(crate) fn start(connection: Arc<Connection>) -> std::result::Result<Self, crate::CoreError> {
        block_on(async {
            let channel = connection.open_session().await?;
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|error| crate::connection_error(error.into()))?;
            let mut raw = RawSftpSession::new(channel.into_stream());
            raw.set_timeout(REQUEST_TIMEOUT_SECONDS);
            let version = raw.init().await.map_err(|error| crate::connection_error(error.into()))?;
            let (mut read_chunk, mut write_chunk) = (DEFAULT_CHUNK, DEFAULT_CHUNK);
            if version.extensions.contains_key("limits@openssh.com") {
                if let Ok(limits) = raw.limits().await {
                    if limits.max_read_len > 0 {
                        read_chunk = limits.max_read_len.min(MAX_CHUNK);
                    }
                    if limits.max_write_len > 0 {
                        write_chunk = limits.max_write_len.min(MAX_CHUNK);
                    }
                    raw.set_limits(Limits::from(limits));
                }
            }
            Ok(Self {
                raw: Arc::new(raw),
                read_chunk,
                write_chunk,
                supports_posix_rename: version.extensions.get("posix-rename@openssh.com").map(String::as_str) == Some("1"),
                _connection: connection,
            })
        })
    }

    pub(crate) fn raw(&self) -> &Arc<RawSftpSession> {
        &self.raw
    }

    pub(crate) fn supports_posix_rename(&self) -> bool {
        self.supports_posix_rename
    }

    pub(crate) fn readdir(&self, path: &Path) -> Result<Vec<(PathBuf, FileStat)>> {
        let wire = wire_path(path)?;
        block_on(async {
            let handle = self.raw.opendir(wire).await?.handle;
            let mut entries = Vec::new();
            let result = loop {
                match self.raw.readdir(handle.as_str()).await {
                    Ok(name) => {
                        for file in name.files {
                            if file.filename == "." || file.filename == ".." {
                                continue;
                            }
                            entries.push((path.join(&file.filename), FileStat::from_attributes(&file.attrs)));
                        }
                    }
                    Err(russh_sftp::client::error::Error::Status(status)) if status.status_code == StatusCode::Eof => break Ok(()),
                    Err(error) => break Err(SshError::from(error)),
                }
            };
            let _ = self.raw.close(handle).await;
            result.map(|_| entries)
        })
    }

    pub(crate) fn stat(&self, path: &Path) -> Result<FileStat> {
        let wire = wire_path(path)?;
        Ok(FileStat::from_attributes(&block_on(self.raw.stat(wire))?.attrs))
    }

    pub(crate) fn lstat(&self, path: &Path) -> Result<FileStat> {
        let wire = wire_path(path)?;
        Ok(FileStat::from_attributes(&block_on(self.raw.lstat(wire))?.attrs))
    }

    pub(crate) fn setstat(&self, path: &Path, stat: FileStat) -> Result<()> {
        let wire = wire_path(path)?;
        block_on(self.raw.setstat(wire, stat.attributes()))?;
        Ok(())
    }

    pub(crate) fn mkdir(&self, path: &Path, mode: i32) -> Result<()> {
        let wire = wire_path(path)?;
        let mut attributes = FileAttributes::empty();
        attributes.permissions = Some(mode as u32);
        block_on(self.raw.mkdir(wire, attributes))?;
        Ok(())
    }

    pub(crate) fn rmdir(&self, path: &Path) -> Result<()> {
        let wire = wire_path(path)?;
        block_on(self.raw.rmdir(wire))?;
        Ok(())
    }

    pub(crate) fn unlink(&self, path: &Path) -> Result<()> {
        let wire = wire_path(path)?;
        block_on(self.raw.remove(wire))?;
        Ok(())
    }

    pub(crate) fn readlink(&self, path: &Path) -> Result<PathBuf> {
        let wire = wire_path(path)?;
        first_name(block_on(self.raw.readlink(wire))?)
    }

    pub(crate) fn realpath(&self, path: &Path) -> Result<PathBuf> {
        let wire = wire_path(path)?;
        first_name(block_on(self.raw.realpath(wire))?)
    }

    /// Creates a link at `link` whose contents are `target`. OpenSSH reads the
    /// two SSH_FXP_SYMLINK fields in reverse, so the target goes first, as
    /// libssh2 also sent it.
    pub(crate) fn symlink(&self, target: &Path, link: &Path) -> Result<()> {
        let (target, link) = (wire_path(target)?, wire_path(link)?);
        block_on(self.raw.symlink(target, link))?;
        Ok(())
    }

    /// Plain SSH_FXP_RENAME: fails when the destination exists.
    pub(crate) fn rename(&self, source: &Path, destination: &Path) -> Result<()> {
        let (source, destination) = (wire_path(source)?, wire_path(destination)?);
        block_on(self.raw.rename(source, destination))?;
        Ok(())
    }

    pub(crate) fn open(&self, path: &Path) -> Result<File> {
        self.open_mode(path, OpenFlags::READ, 0o644, OpenType::File)
    }

    pub(crate) fn create(&self, path: &Path) -> Result<File> {
        self.open_mode(path, OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE, 0o644, OpenType::File)
    }

    pub(crate) fn open_mode(&self, path: &Path, flags: OpenFlags, mode: i32, _kind: OpenType) -> Result<File> {
        let wire = wire_path(path)?;
        let mut attributes = FileAttributes::empty();
        if flags.0 & OpenFlags::CREATE.0 != 0 {
            attributes.permissions = Some(mode as u32);
        }
        let handle = block_on(self.raw.open(wire, WireOpenFlags::from_bits_truncate(flags.0), attributes))?.handle;
        Ok(File {
            raw: Arc::clone(&self.raw),
            handle,
            offset: 0,
            read_chunk: self.read_chunk,
            write_chunk: self.write_chunk,
        })
    }
}

fn first_name(name: russh_sftp::protocol::Name) -> Result<PathBuf> {
    name.files
        .into_iter()
        .next()
        .map(|file| PathBuf::from(file.filename))
        .ok_or_else(|| SshError("server returned no path".to_owned()))
}

pub(crate) struct File {
    raw: Arc<RawSftpSession>,
    handle: String,
    offset: u64,
    read_chunk: u64,
    write_chunk: u64,
}

impl File {
    pub(crate) fn stat(&mut self) -> Result<FileStat> {
        Ok(FileStat::from_attributes(&block_on(self.raw.fstat(self.handle.as_str()))?.attrs))
    }
}

impl Read for File {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let (raw, handle, start, chunk) = (&self.raw, self.handle.as_str(), self.offset, self.read_chunk);
        let requests = (0..buffer.len() as u64).step_by(chunk as usize).map(|relative| {
            let length = chunk.min(buffer.len() as u64 - relative) as u32;
            async move { (length, raw.read(handle, start + relative, length).await) }
        });
        let replies = block_on(futures::future::join_all(requests));
        let mut filled = 0;
        for (requested, reply) in replies {
            match reply {
                Ok(data) => {
                    buffer[filled..filled + data.data.len()].copy_from_slice(&data.data);
                    filled += data.data.len();
                    // A short reply leaves a gap; later chunks are re-read next time.
                    if data.data.len() < requested as usize {
                        break;
                    }
                }
                Err(russh_sftp::client::error::Error::Status(status)) if status.status_code == StatusCode::Eof => break,
                Err(error) if filled == 0 => return Err(SshError::from(error).into()),
                Err(_) => break,
            }
        }
        self.offset += filled as u64;
        Ok(filled)
    }
}

impl Write for File {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let (raw, handle, start) = (&self.raw, self.handle.as_str(), self.offset);
        let requests = buffer.chunks(self.write_chunk as usize).enumerate().map(|(index, piece)| {
            let offset = start + index as u64 * self.write_chunk;
            raw.write(handle, offset, piece.to_vec())
        });
        for reply in block_on(futures::future::join_all(requests)) {
            reply.map_err(SshError::from)?;
        }
        self.offset += buffer.len() as u64;
        Ok(buffer.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Seek for File {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        let target = match position {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::Current(delta) => self.offset.checked_add_signed(delta),
            SeekFrom::End(delta) => self.stat()?.size.unwrap_or_default().checked_add_signed(delta),
        };
        self.offset = target.ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid seek"))?;
        Ok(self.offset)
    }
}

impl Drop for File {
    fn drop(&mut self) {
        // Close synchronously so a following rename or stat sees the final file.
        let (raw, handle) = (Arc::clone(&self.raw), std::mem::take(&mut self.handle));
        if tokio::runtime::Handle::try_current().is_ok() {
            tokio::spawn(async move {
                let _ = raw.close(handle).await;
            });
        } else {
            let _ = block_on(raw.close(handle));
        }
    }
}
