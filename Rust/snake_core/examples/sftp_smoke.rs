use snake_core::open_sftp_password;
use std::io::Read;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = std::env::args().collect::<Vec<_>>();
    if arguments.len() != 5 {
        return Err("usage: sftp_smoke <host> <port> <username> <known-hosts-path>".into());
    }

    let mut password = Vec::new();
    std::io::stdin().read_to_end(&mut password)?;
    while matches!(password.last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    if password.is_empty() {
        return Err("password input is empty".into());
    }

    let handle = open_sftp_password(
        arguments[1].clone(),
        arguments[2].parse::<u16>()?,
        arguments[3].clone(),
        password,
        arguments[4].clone(),
        None,
    )?;
    let home = handle.home_directory()?;
    let entries = handle.list(home.clone())?;

    println!(
        "Snake SFTP smoke test passed: {home} ({} entries).",
        entries.len()
    );
    Ok(())
}
