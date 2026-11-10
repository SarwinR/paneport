//! Talking to the Mac over HTTP, and the JSON messages it sends.

use crate::protocol::{parse_http_response, split_host};
use serde::Deserialize;
use std::fmt;
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// An entry of /displays.json.
#[derive(Debug, Clone, Deserialize)]
pub struct DisplayInfo {
    pub name: String,
    pub port: u16,
    pub width: u32,
    pub height: u32,
}

/// /version.
#[derive(Debug, Deserialize)]
pub struct VersionInfo {
    #[serde(rename = "app")]
    pub app_version: String,
    #[serde(rename = "protocol")]
    pub protocol_version: u32,
    #[serde(rename = "windowsReceiver")]
    pub windows_receiver: Option<Download>,
}

#[derive(Debug, Deserialize)]
pub struct Download {
    pub version: String,
    pub path: String,
}

/// "h:<json>", the first message on every stream connection.
#[derive(Debug, Deserialize)]
pub struct Hello {
    pub protocol: u32,
    pub app: String,
    pub width: u32,
    pub height: u32,
}

/// "c:<json>": the pointer image (base64 PNG) and its size and hot spot in stream pixels.
#[derive(Debug, Deserialize)]
pub struct PointerShapeMessage {
    pub png: String,
    pub w: f64,
    pub h: f64,
    pub hx: f64,
    pub hy: f64,
}

/// Why a request to the Mac failed.
#[derive(Debug)]
pub enum MacError {
    /// Nothing is listening at the address: Paneport isn't streaming, or isn't running.
    NotStreaming,
    /// The Mac couldn't be reached at all.
    Unreachable(String),
    /// The Mac answered, but not as expected.
    Unexpected(String),
}

impl fmt::Display for MacError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MacError::NotStreaming => write!(f, "nothing is answering there, so Paneport isn't streaming"),
            MacError::Unreachable(reason) | MacError::Unexpected(reason) => write!(f, "{reason}"),
        }
    }
}

pub struct MacClient {
    host: String,
    port: u16,
}

impl MacClient {
    pub fn new(address: &str) -> MacClient {
        let (host, port) = split_host(address);
        MacClient { host, port }
    }

    /// The Mac's host name or IP address, without the port.
    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn version(&self) -> Result<VersionInfo, MacError> {
        let body = self.get("/version")?;
        serde_json::from_slice(&body).map_err(|_| {
            MacError::Unexpected("the Mac's Paneport is too old for this app; update it to the latest release".into())
        })
    }

    pub fn displays(&self) -> Result<Vec<DisplayInfo>, MacError> {
        let body = self.get("/displays.json")?;
        serde_json::from_slice(&body).map_err(|e| MacError::Unexpected(format!("unexpected display list: {e}")))
    }

    /// A plain HTTP GET; the Mac's server closes the connection after each response.
    pub fn get(&self, path: &str) -> Result<Vec<u8>, MacError> {
        let unreachable = |e: std::io::Error| MacError::Unreachable(e.to_string());
        let address = (self.host.as_str(), self.port)
            .to_socket_addrs()
            .map_err(|e| MacError::Unreachable(format!("can't find {}: {e}", self.host)))?
            .next()
            .ok_or_else(|| MacError::Unreachable(format!("can't find {}", self.host)))?;
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(3)).map_err(|e| match e.kind() {
            ErrorKind::ConnectionRefused => MacError::NotStreaming,
            _ => MacError::Unreachable(e.to_string()),
        })?;
        stream.set_read_timeout(Some(Duration::from_secs(30))).map_err(unreachable)?;
        stream.set_nodelay(true).map_err(unreachable)?;
        // One write, so the whole request arrives together.
        let request = format!("GET {path} HTTP/1.1\r\nHost: {}:{}\r\nConnection: close\r\n\r\n", self.host, self.port);
        stream.write_all(request.as_bytes()).map_err(unreachable)?;
        let mut response = Vec::new();
        if let Err(e) = stream.read_to_end(&mut response) {
            // A connection closed abruptly after a complete response is still a success.
            if parse_http_response(&response).is_none() {
                return Err(unreachable(e));
            }
        }
        match parse_http_response(&response) {
            Some((200, body)) => Ok(body.to_vec()),
            Some((status, _)) => Err(MacError::Unexpected(format!("the Mac answered {path} with HTTP {status}"))),
            None => Err(MacError::Unexpected(format!("the Mac sent an unreadable response for {path}"))),
        }
    }
}
