use super::*;
use std::os::fd::BorrowedFd;
use std::os::unix::fs::FileExt;

const CHECKSUM_PROBE_SCRIPT: &str = "if command -v sha256sum >/dev/null 2>&1 && sha256sum </dev/null >/dev/null 2>&1; then echo snake:sha256sum; elif command -v shasum >/dev/null 2>&1 && shasum -a 256 </dev/null >/dev/null 2>&1; then echo snake:shasum; elif command -v openssl >/dev/null 2>&1 && openssl dgst -sha256 </dev/null >/dev/null 2>&1; then echo snake:openssl-sha256; elif command -v md5sum >/dev/null 2>&1 && md5sum </dev/null >/dev/null 2>&1; then echo snake:md5sum; elif command -v md5 >/dev/null 2>&1 && md5 -q </dev/null >/dev/null 2>&1; then echo snake:md5; elif command -v openssl >/dev/null 2>&1 && openssl dgst -md5 </dev/null >/dev/null 2>&1; then echo snake:openssl-md5; else echo snake:none; fi";

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreFileMetadata {
    pub size: u64,
    pub modified_at: u64,
    pub kind: String,
    pub link_target: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreChecksumCapability {
    pub tool: String,
    pub algorithm: String,
    pub reason: String,
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput { message: message.into() }
}

// sshd passes exec requests through the account's login shell. Use only a
// simple invocation there and let /bin/sh parse our POSIX control flow.
// Keep metacharacters inside single quotes. Escape apostrophes and backslashes
// outside those quotes, where sh/bash/zsh/fish share the same semantics.
fn posix_command(script: &str) -> String {
    let mut quoted = String::from("/bin/sh -c '");
    for character in script.chars() {
        match character {
            '\'' => quoted.push_str("'\\''"),
            '\\' => quoted.push_str("'\\\\'"),
            _ => quoted.push(character),
        }
    }
    quoted.push('\'');
    quoted
}

fn probe_failure(status: i32, output: &str) -> CoreError {
    // Classify diagnostics without exposing arbitrary login banners, command
    // text, paths or other server output in UI/logs.
    let lower = output.to_ascii_lowercase();
    let reason = if lower.contains("/bin/sh") && (lower.contains("not found") || lower.contains("no such file")) {
        "服务器缺少 /bin/sh"
    } else if lower.contains("permission denied") {
        "服务器拒绝执行探测命令"
    } else if lower.contains("syntax error") || lower.contains("expected end of the statement") {
        "远端 Shell 无法解析探测命令"
    } else if status != 0 {
        "远端探测命令执行失败"
    } else {
        "未收到有效的校验工具标识"
    };
    invalid(&format!("校验能力探测失败（退出码 {status}）：{reason}；这不表示文件已损坏"))
}

// Read both streams through a single bounded channel. No remote file bytes are
// returned here: only tool detection markers and a small digest response.
fn command_output(session: &Session, command: &str, control: Option<&CoreTransferControl>) -> Result<(i32, String), CoreError> {
    let mut channel = session.channel_session().map_err(connection_error)?;
    channel.handle_extended_data(ExtendedData::Merge).map_err(connection_error)?;
    if let Err(error) = channel.exec(&posix_command(command)) {
        if error.code() == ErrorCode::Session(-22) { return Ok((126, "snake:exec-denied".into())); }
        return Err(connection_error(error));
    }
    struct BlockingRestore<'a>(&'a Session);
    impl Drop for BlockingRestore<'_> { fn drop(&mut self) { self.0.set_blocking(true); } }
    session.set_blocking(false);
    let _restore = BlockingRestore(session);
    let mut bytes = Vec::new();
    let start = std::time::Instant::now();
    let timeout_seconds = if control.is_some() { 1800 } else { 30 };
    loop {
        if let Some(control) = control {
            if let Err(error) = control.wait_if_paused() { let _ = channel.close(); return Err(error); }
        }
        if start.elapsed().as_secs() > timeout_seconds {
            let _ = channel.close(); return Err(invalid("远端校验命令超时"));
        }
        let mut buffer = [0; 1024];
        match channel.read(&mut buffer) {
            Ok(0) if channel.eof() => break,
            Ok(size) => bytes.extend_from_slice(&buffer[..size]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {},
            Err(error) => return Err(io_error(error)),
        }
        if bytes.len() > 8192 { let _ = channel.close(); return Err(invalid("校验命令输出过长")); }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    // Drain close packets without switching to a blocking wait so cancellation
    // stays responsive even when the server stalls after sending the digest.
    while let Err(error) = channel.wait_close() {
        if error.code() != ErrorCode::Session(-37) { return Err(connection_error(error)); }
        if let Some(control) = control { control.wait_if_paused()?; }
        if start.elapsed().as_secs() > timeout_seconds { return Err(invalid("远端命令关闭超时")); }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    Ok((channel.exit_status().map_err(connection_error)?, String::from_utf8_lossy(&bytes).into_owned()))
}

fn parse_digest(output: &str, algorithm: &str) -> Result<String, CoreError> {
    let length = match algorithm { "SHA-256" => 64, "MD5" => 32, _ => return Err(invalid("未知校验算法")) };
    let candidates: Vec<_> = output.split_whitespace()
        .filter(|word| word.len() == length && word.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .collect();
    if candidates.len() != 1 { return Err(invalid("远端摘要格式错误")); }
    Ok(candidates[0].to_ascii_lowercase())
}

#[uniffi::export]
impl CoreSftpHandle {
    pub fn remove_transfer_temporary(&self, path: String) -> Result<(), CoreError> {
        let path = validated_remote_upload_path(&path)?;
        if !Path::new(&path).file_name().unwrap_or_default().to_string_lossy().starts_with(".snake-upload-") {
            return Err(invalid("拒绝删除非传输暂存文件"));
        }
        self.sftp.unlink(Path::new(&path)).map_err(connection_error)
    }

    pub fn file_metadata(&self, path: String) -> Result<CoreFileMetadata, CoreError> {
        let stat = self.sftp.lstat(Path::new(&path)).map_err(connection_error)?;
        let link = stat.file_type().is_symlink();
        Ok(CoreFileMetadata {
            size: stat.size.unwrap_or(0), modified_at: stat.mtime.unwrap_or(0),
            kind: if link { "link" } else if stat.is_dir() { "directory" } else if stat.is_file() { "file" } else { "special" }.into(),
            link_target: if link { Some(self.sftp.readlink(Path::new(&path)).map_err(connection_error)?.to_string_lossy().into_owned()) } else { None },
        })
    }

    pub fn checksum_capability(&self) -> Result<CoreChecksumCapability, CoreError> {
        // Probe algorithms with an empty input as well as executable presence;
        // installations with disabled OpenSSL MD5 are not falsely advertised.
        let result = command_output(&self._session, CHECKSUM_PROBE_SCRIPT, None);
        match result {
            Err(error) => Err(error),
            Ok((status, output)) => {
                let tool = output.lines().find_map(|line| line.trim().strip_prefix("snake:"));
                match (status, tool) {
                    (126, Some("exec-denied")) => Ok(CoreChecksumCapability { tool: "sftp-only".into(), algorithm: String::new(), reason: "服务器禁止执行远端命令".into() }),
                    (0, Some("none")) => Ok(CoreChecksumCapability { tool: String::new(), algorithm: String::new(), reason: "服务器没有可用的 SHA-256 或 MD5 工具".into() }),
                    (0, Some(tool @ ("sha256sum" | "shasum" | "openssl-sha256" | "md5sum" | "md5" | "openssl-md5"))) =>
                        Ok(CoreChecksumCapability { tool: tool.into(), algorithm: if tool.contains("md5") { "MD5" } else { "SHA-256" }.into(), reason: String::new() }),
                    _ if output.trim() == "This service allows sftp connections only." => Ok(CoreChecksumCapability { tool: "sftp-only".into(), algorithm: String::new(), reason: "服务器仅允许 SFTP，无法执行校验命令".into() }),
                    _ => Err(probe_failure(status, &output)),
                }
            }
        }
    }

    pub fn remote_checksum(&self, path: String, capability: CoreChecksumCapability, control: Arc<CoreTransferControl>) -> Result<String, CoreError> {
        control.wait_if_paused()?;
        let command = match capability.tool.as_str() {
            "sha256sum" => "sha256sum", "shasum" => "shasum -a 256",
            "openssl-sha256" => "openssl dgst -sha256", "md5sum" => "md5sum",
            "md5" => "md5 -q", "openssl-md5" => "openssl dgst -md5",
            _ => return Err(invalid("没有可用的远端校验工具")),
        };
        let path = validated_remote_upload_path(&path)?;
        // Redirection avoids interpreting filenames as options and prevents
        // escaped filenames from contaminating GNU checksum output parsing.
        let (status, output) = command_output(&self._session, &format!("{command} < {}", shell_single_quote(&path)), Some(&control))?;
        control.wait_if_paused()?;
        if status != 0 { return Err(invalid("远端文件校验命令失败，请检查文件权限或重试")); }
        parse_digest(&output, &capability.algorithm)
    }

    /// Swift owns an O_EXCL, no-follow staging descriptor for the duration of
    /// all workers. Clone it but use positional writes (dup shares seek state).
    pub fn download_range(&self, remote_path: String, local_fd: i32, offset: u64, length: u64,
        control: Arc<CoreTransferControl>, observer: Box<dyn CoreTransferObserver>) -> Result<(), CoreError> {
        if local_fd < 0 { return Err(invalid("本地暂存句柄无效")); }
        let end = offset.checked_add(length).ok_or_else(|| invalid("下载区间溢出"))?;
        let mut source = self.sftp.open(Path::new(&remote_path)).map_err(connection_error)?;
        if end > source.stat().map_err(connection_error)?.size.unwrap_or(0) { return Err(invalid("远端文件大小已变化")); }
        source.seek(SeekFrom::Start(offset)).map_err(io_error)?;
        let destination = std::fs::File::from(unsafe { BorrowedFd::borrow_raw(local_fd) }.try_clone_to_owned().map_err(io_error)?);
        let mut buffer = vec![0u8; 1024 * 1024];
        let mut completed = 0;
        while completed < length {
            control.wait_if_paused()?;
            let count = source.read(&mut buffer[..((length - completed).min(1024 * 1024) as usize)]).map_err(io_error)?;
            if count == 0 { return Err(invalid("下载提前结束，远端文件可能已变化")); }
            destination.write_all_at(&buffer[..count], offset + completed).map_err(io_error)?;
            completed += count as u64;
            observer.on_progress(completed, length);
        }
        control.wait_if_paused()?;
        observer.on_progress(length, length);
        Ok(())
    }

    /// SFTP-only accounts cannot run cat/mv. Independent handles write
    /// disjoint ranges into one fresh, exclusively created staging file.
    pub fn prepare_native_upload(&self, staging: String) -> Result<(), CoreError> {
        let staging = validated_remote_upload_path(&staging)?;
        self.sftp.open_mode(Path::new(&staging), OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUSIVE, 0o600, OpenType::File).map_err(connection_error)?;
        Ok(())
    }

    pub fn upload_native_range(&self, local_path: String, staging: String, offset: u64, length: u64,
        control: Arc<CoreTransferControl>, observer: Box<dyn CoreTransferObserver>) -> Result<(), CoreError> {
        let staging = validated_remote_upload_path(&staging)?;
        let mut source = std::fs::File::open(local_path).map_err(io_error)?;
        let end = offset.checked_add(length).ok_or_else(|| invalid("上传区间溢出"))?;
        if end > source.metadata().map_err(io_error)?.len() { return Err(invalid("本地源文件大小已变化")); }
        source.seek(SeekFrom::Start(offset)).map_err(io_error)?;
        let mut destination = self.sftp.open_mode(Path::new(&staging), OpenFlags::WRITE, 0o600, OpenType::File).map_err(connection_error)?;
        destination.seek(SeekFrom::Start(offset)).map_err(io_error)?;
        copy_exact_range_with_control(&mut source, &mut destination, 0, length, &control, observer.as_ref())
    }

    pub fn publish_native_upload(&self, staging: String, target: String, overwrite: bool, control: Arc<CoreTransferControl>) -> Result<(), CoreError> {
        control.wait_if_paused()?;
        let staging = validated_remote_upload_path(&staging)?;
        let target = validated_remote_upload_path(&target)?;
        if !overwrite { ensure_destination_absent(&self.sftp, Path::new(&target))?; }
        let flags = if overwrite { ssh2::RenameFlags::ATOMIC | ssh2::RenameFlags::OVERWRITE } else { ssh2::RenameFlags::empty() };
        self.sftp.rename(Path::new(&staging), Path::new(&target), Some(flags)).map_err(connection_error)
    }

    pub fn assemble_upload(&self, parts: Vec<String>, staging: String, control: Arc<CoreTransferControl>) -> Result<(), CoreError> {
        control.wait_if_paused()?;
        if parts.is_empty() { return Err(invalid("缺少上传分片")); }
        let staging = validated_remote_upload_path(&staging)?;
        let quoted = parts.iter().map(|p| validated_remote_upload_path(p).map(|p| shell_single_quote(&p))).collect::<Result<Vec<_>, _>>()?.join(" ");
        let (status, _) = command_output(&self._session, &format!("cat -- {quoted} > {}", shell_single_quote(&staging)), Some(&control))?;
        if status != 0 { return Err(invalid("合并上传分片失败")); }
        control.wait_if_paused()
    }

    pub fn publish_upload(&self, staging: String, target: String, parts: Vec<String>, overwrite: bool, control: Arc<CoreTransferControl>) -> Result<(), CoreError> {
        control.wait_if_paused()?;
        let staging = validated_remote_upload_path(&staging)?;
        let target = validated_remote_upload_path(&target)?;
        if !overwrite { ensure_destination_absent(&self.sftp, Path::new(&target))?; }
        let command = format!("mv {} -- {} {} && test ! -e {}", if overwrite { "-f" } else { "-n" }, shell_single_quote(&staging), shell_single_quote(&target), shell_single_quote(&staging));
        run_remote_command(&self._session, &posix_command(&command), "发布上传文件")?;
        // Cleanup failure after successful publication must not misreport the
        // completed transfer; unlink only exact managed parts, never recurse.
        for part in parts {
            let part = validated_remote_upload_path(&part)?;
            let _ = self.sftp.unlink(Path::new(&part));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn posix_probe_and_quoting_work_through_available_login_shells() {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/bin/fish"];
        let literal = "中文 'single' \"double\" \\ slash $HOME $(printf injected) `printf injected` ; end";
        for shell in shells.into_iter().filter(|shell| Path::new(shell).exists()) {
            let run = |script: &str| Command::new(shell).args(["-c", &posix_command(script)]).output().unwrap();
            let result = run(CHECKSUM_PROBE_SCRIPT);
            assert!(result.status.success(), "probe failed via {shell}: {}", String::from_utf8_lossy(&result.stderr));
            let stdout = String::from_utf8(result.stdout).unwrap();
            assert!(stdout.lines().any(|line| line.starts_with("snake:")), "missing marker via {shell}");
            let result = run(&format!("printf '%s' {}", shell_single_quote(literal)));
            assert!(result.status.success(), "quoting failed via {shell}");
            assert_eq!(String::from_utf8(result.stdout).unwrap(), literal, "literal changed via {shell}");
        }
    }

    #[test]
    fn probe_errors_explain_failure_without_leaking_remote_output() {
        let missing = probe_failure(127, "/bin/sh: not found private-banner").to_string();
        assert!(missing.contains("127") && missing.contains("缺少 /bin/sh"));
        assert!(!missing.contains("private-banner"));
        assert!(probe_failure(2, "syntax error").to_string().contains("无法解析"));
        assert!(probe_failure(0, "unexpected output").to_string().contains("未收到有效"));
    }

    #[test]
    fn digest_parser_accepts_tools_but_rejects_ambiguous_or_wrong_lengths() {
        let sha = "a".repeat(64);
        assert_eq!(parse_digest(&format!("{sha}  -\n"), "SHA-256").unwrap(), sha);
        let md5 = "B".repeat(32);
        assert_eq!(parse_digest(&format!("MD5(stdin)= {md5}\n"), "MD5").unwrap(), md5.to_lowercase());
        assert!(parse_digest(&md5, "SHA-256").is_err());
        assert!(parse_digest(&format!("{sha}\n{sha}"), "SHA-256").is_err());
        assert!(parse_digest("not-a-hash", "MD5").is_err());
    }
}
