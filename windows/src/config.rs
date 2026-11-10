//! Settings remembered between runs, in %APPDATA%\Paneport\receiver.json.

use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::PathBuf;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Config {
    /// The Mac's address, "host:port".
    pub host: Option<String>,
    /// Which Mac display goes on which monitor.
    #[serde(default)]
    pub assignments: Vec<Assignment>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Assignment {
    /// The display's name in Paneport on the Mac.
    pub display: String,
    /// The monitor's Windows device name, like \\.\DISPLAY2.
    pub monitor: String,
}

impl Config {
    fn path() -> Option<PathBuf> {
        let app_data = std::env::var_os("APPDATA")?;
        Some(PathBuf::from(app_data).join("Paneport").join("receiver.json"))
    }

    pub fn load() -> Config {
        Self::path()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(path) = Self::path() else { return };
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        match serde_json::to_vec_pretty(self) {
            Ok(bytes) => {
                if let Err(e) = std::fs::write(&path, bytes) {
                    eprintln!("Couldn't save settings to {}: {e}", path.display());
                }
            }
            Err(e) => eprintln!("Couldn't save settings: {e}"),
        }
    }
}

/// Asks a question in the console and returns the answer without the line break.
pub fn prompt(question: &str) -> String {
    print!("{question}");
    let _ = std::io::stdout().flush();
    let mut answer = String::new();
    let _ = std::io::stdin().read_line(&mut answer);
    answer.trim().to_string()
}
