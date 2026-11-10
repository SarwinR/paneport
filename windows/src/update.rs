//! Keeping the receiver in step with the Mac: it downloads newer versions from the Mac itself.

use crate::api::{MacClient, VersionInfo};
use crate::config::prompt;
use crate::protocol::{is_newer, PROTOCOL_VERSION};
use std::path::PathBuf;
use std::process::Command;

const OUR_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Offers (or, when this version can't talk to the Mac, performs) an update from the Mac,
/// then fails if the two still don't speak the same protocol.
pub fn check(mac: &MacClient, info: &VersionInfo) -> Result<(), String> {
    let compatible = info.protocol_version == PROTOCOL_VERSION;
    if let Some(download) = &info.windows_receiver {
        if is_newer(&download.version, OUR_VERSION) {
            let update = if compatible {
                let answer = prompt(&format!(
                    "Version {} is available from the Mac (you have {OUR_VERSION}). Update now? [Y/n] ",
                    download.version
                ));
                !answer.eq_ignore_ascii_case("n")
            } else {
                println!(
                    "This version can't talk to the Mac's Paneport {}. Updating to {}…",
                    info.app_version, download.version
                );
                true
            };
            if update {
                let bytes = mac.get(&download.path).map_err(|e| format!("Download failed: {e}"))?;
                install_and_restart(&bytes)?;
            }
        }
    }
    if !compatible {
        return Err(format!(
            "This app (protocol {PROTOCOL_VERSION}) doesn't match the Mac's Paneport {} (protocol {}).\n\
             Use the receiver from the same Paneport release: open the Mac's address in a browser to download it.",
            info.app_version, info.protocol_version
        ));
    }
    Ok(())
}

/// Replaces the running executable with `bytes` and starts the new one with the same arguments.
/// Windows lets a running .exe be renamed, but not overwritten.
fn install_and_restart(bytes: &[u8]) -> Result<(), String> {
    if !bytes.starts_with(b"MZ") {
        return Err("The download isn't a Windows program; not installing it.".into());
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let (new, old) = sibling_paths(&exe);
    std::fs::write(&new, bytes).map_err(|e| format!("Couldn't save the update: {e}"))?;
    let _ = std::fs::remove_file(&old);
    std::fs::rename(&exe, &old).map_err(|e| format!("Couldn't replace the app: {e}"))?;
    if let Err(e) = std::fs::rename(&new, &exe) {
        let _ = std::fs::rename(&old, &exe); // put the original back
        return Err(format!("Couldn't install the update: {e}"));
    }
    Command::new(&exe)
        .args(std::env::args().skip(1))
        .spawn()
        .map_err(|e| format!("Updated, but couldn't restart: {e}. Start it again."))?;
    std::process::exit(0);
}

/// Deletes what an update left behind (the previous version can't delete itself while running).
pub fn remove_leftovers() {
    if let Ok(exe) = std::env::current_exe() {
        let (new, old) = sibling_paths(&exe);
        let _ = std::fs::remove_file(new);
        let _ = std::fs::remove_file(old);
    }
}

fn sibling_paths(exe: &std::path::Path) -> (PathBuf, PathBuf) {
    (exe.with_extension("new.exe"), exe.with_extension("old.exe"))
}
