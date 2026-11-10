//! Talking to the Mac over HTTP, and the JSON messages it sends.

use crate::protocol::{parse_http_response, split_host};
use serde::Deserialize;
use std::io::{Read, Write};
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

    pub fn version(&self) -> Result<VersionInfo, String> {
        let body = self.get("/version")?;
        serde_json::from_slice(&body)
            .map_err(|_| "the Mac's Paneport is too old for this app; update it to the latest release".to_string())
    }

    pub fn displays(&self) -> Result<Vec<DisplayInfo>, String> {
        let body = self.get("/displays.json")?;
        serde_json::from_slice(&body).map_err(|e| format!("unexpected display list from the Mac: {e}"))
    }

    /// A plain HTTP GET; the Mac's server closes the connection after each response.
    pub fn get(&self, path: &str) -> Result<Vec<u8>, String> {
        let address = (self.host.as_str(), self.port)
            .to_socket_addrs()
            .map_err(|e| e.to_string())?
            .next()
            .ok_or("the address didn't resolve")?;
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(3)).map_err(|e| e.to_string())?;
        stream.set_read_timeout(Some(Duration::from_secs(30))).map_err(|e| e.to_string())?;
        write!(stream, "GET {path} HTTP/1.1\r\nHost: {}:{}\r\nConnection: close\r\n\r\n", self.host, self.port)
            .map_err(|e| e.to_string())?;
        let mut response = Vec::new();
        stream.read_to_end(&mut response).map_err(|e| e.to_string())?;
        match parse_http_response(&response) {
            Some((200, body)) => Ok(body.to_vec()),
            Some((status, _)) => Err(format!("the Mac answered {path} with HTTP {status}")),
            None => Err(format!("the Mac sent an unreadable response for {path}")),
        }
    }
}
