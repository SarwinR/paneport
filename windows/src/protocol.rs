//! The wire protocol (docs/PROTOCOL.md) and other pure logic.
//!
//! Standard library only and no Windows APIs, so it builds and tests anywhere:
//! `rustc --edition 2021 --test src/protocol.rs && ./protocol`, or `cargo test`.

/// Must match `WireProtocol.version` on the Mac.
pub const PROTOCOL_VERSION: u32 = 1;

/// Flag (1) + capture time (8) + send time (8).
pub const FRAME_HEADER_SIZE: usize = 17;

/// One video frame from the Mac.
#[derive(Debug, PartialEq)]
pub struct Frame<'a> {
    pub is_keyframe: bool,
    /// Mac host clock, microseconds.
    pub captured_micros: u64,
    pub sent_micros: u64,
    /// H.264, Annex B.
    pub payload: &'a [u8],
}

pub fn parse_frame(message: &[u8]) -> Option<Frame<'_>> {
    if message.len() <= FRAME_HEADER_SIZE {
        return None;
    }
    let read_u64 = |at: usize| {
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&message[at..at + 8]);
        u64::from_be_bytes(bytes)
    };
    Some(Frame {
        is_keyframe: message[0] == 1,
        captured_micros: read_u64(1),
        sent_micros: read_u64(9),
        payload: &message[FRAME_HEADER_SIZE..],
    })
}

/// "m:x,y,visible,micros": where the pointer is, in stream pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PointerPosition {
    pub x: f64,
    pub y: f64,
    pub visible: bool,
    /// Mac host clock, microseconds, when the position was read.
    pub micros: u64,
}

pub fn parse_pointer_position(text: &str) -> Option<PointerPosition> {
    let mut parts = text.strip_prefix("m:")?.split(',');
    Some(PointerPosition {
        x: parts.next()?.parse().ok()?,
        y: parts.next()?.parse().ok()?,
        visible: parts.next()? == "1",
        micros: parts.next()?.parse().ok()?,
    })
}

/// One clock-sync measurement.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClockSample {
    pub rtt_ms: f64,
    /// Mac clock minus local clock, in milliseconds.
    pub offset_ms: f64,
}

/// The ping message for local time `now_ms`.
pub fn ping(now_ms: f64) -> String {
    format!("p:{now_ms}")
}

/// From a pong "q:<local ms sent>:<Mac µs>" received at `received_ms`, assuming the
/// reply took half the round trip.
pub fn clock_sample(text: &str, received_ms: f64) -> Option<ClockSample> {
    let mut parts = text.strip_prefix("q:")?.split(':');
    let sent_ms: f64 = parts.next()?.parse().ok()?;
    let mac_ms = parts.next()?.parse::<f64>().ok()? / 1000.0;
    let rtt_ms = received_ms - sent_ms;
    Some(ClockSample { rtt_ms, offset_ms: mac_ms - (sent_ms + rtt_ms / 2.0) })
}

/// The offset from the sample with the shortest round trip, the least affected by queueing.
pub fn best_offset(samples: &[ClockSample]) -> Option<f64> {
    samples.iter().min_by(|a, b| a.rtt_ms.total_cmp(&b.rtt_ms)).map(|s| s.offset_ms)
}

pub fn average(values: &[f64]) -> Option<f64> {
    (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
}

pub fn maximum(values: &[f64]) -> Option<f64> {
    values.iter().copied().reduce(f64::max)
}

/// Latency measurements for one second, sent to the Mac as "s:<json>".
/// Field names match `LatencyStats` on the Mac.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct StatsSummary {
    pub total: Option<f64>,
    pub encode: Option<f64>,
    pub network: Option<f64>,
    pub decode: Option<f64>,
    /// Shown as "browser" on the Mac; here it is decoded → presented.
    pub present: Option<f64>,
    pub pointer: Option<f64>,
    pub rtt: Option<f64>,
    pub fps: u32,
    pub mbps: f64,
    pub drops: u32,
}

impl StatsSummary {
    pub fn message(&self) -> String {
        fn number(v: Option<f64>) -> String {
            match v {
                Some(v) if v.is_finite() => format!("{v:.3}"),
                _ => "null".to_string(),
            }
        }
        format!(
            "s:{{\"total\":{},\"encode\":{},\"network\":{},\"decode\":{},\"browser\":{},\"pointer\":{},\
             \"rtt\":{},\"fps\":{},\"mbps\":{:.3},\"drops\":{}}}",
            number(self.total),
            number(self.encode),
            number(self.network),
            number(self.decode),
            number(self.present),
            number(self.pointer),
            number(self.rtt),
            self.fps,
            self.mbps,
            self.drops
        )
    }
}

/// Splits an HTTP/1.1 response into status code and body.
pub fn parse_http_response(response: &[u8]) -> Option<(u16, &[u8])> {
    let split = response.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = std::str::from_utf8(&response[..split]).ok()?;
    let status = head.split_whitespace().nth(1)?.parse().ok()?;
    Some((status, &response[split + 4..]))
}

/// Splits "host:port" (port defaults to 8080).
pub fn split_host(address: &str) -> (String, u16) {
    let address = address.trim().trim_start_matches("http://").trim_end_matches('/');
    match address.rsplit_once(':') {
        Some((host, port)) => (host.to_string(), port.parse().unwrap_or(8080)),
        None => (address.to_string(), 8080),
    }
}

/// Whether version `a` is newer than `b`, comparing dot-separated numbers ("0.10.0" > "0.9.2").
pub fn is_newer(a: &str, b: &str) -> bool {
    let parse = |v: &str| -> Vec<u64> { v.split('.').map(|p| p.trim().parse().unwrap_or(0)).collect() };
    let (a, b) = (parse(a), parse(b));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

/// A rectangle in pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// The largest rectangle with the stream's aspect ratio that fits the output, centred.
pub fn fit(stream_width: u32, stream_height: u32, output_width: u32, output_height: u32) -> Rect {
    if stream_width == 0 || stream_height == 0 {
        return Rect { x: 0.0, y: 0.0, width: output_width as f32, height: output_height as f32 };
    }
    let scale = (output_width as f32 / stream_width as f32).min(output_height as f32 / stream_height as f32);
    let (width, height) = (stream_width as f32 * scale, stream_height as f32 * scale);
    Rect { x: (output_width as f32 - width) / 2.0, y: (output_height as f32 - height) / 2.0, width, height }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame_message(key: bool, captured: u64, sent: u64, payload: &[u8]) -> Vec<u8> {
        let mut m = vec![key as u8];
        m.extend_from_slice(&captured.to_be_bytes());
        m.extend_from_slice(&sent.to_be_bytes());
        m.extend_from_slice(payload);
        m
    }

    #[test]
    fn parses_frames() {
        let message = frame_message(true, 1_234_567, 1_240_000, &[0, 0, 0, 1, 0x65]);
        let frame = parse_frame(&message).unwrap();
        assert!(frame.is_keyframe);
        assert_eq!(frame.captured_micros, 1_234_567);
        assert_eq!(frame.sent_micros, 1_240_000);
        assert_eq!(frame.payload, &[0, 0, 0, 1, 0x65]);
        assert_eq!(parse_frame(&frame_message(false, 1, 2, &[])), None);
    }

    #[test]
    fn parses_pointer_positions() {
        let p = parse_pointer_position("m:10.5,20.0,1,123456").unwrap();
        assert_eq!(p, PointerPosition { x: 10.5, y: 20.0, visible: true, micros: 123456 });
        assert!(!parse_pointer_position("m:0.0,0.0,0,1").unwrap().visible);
        assert_eq!(parse_pointer_position("m:bad"), None);
    }

    #[test]
    fn clock_sync() {
        let sample = clock_sample("q:100:5000000", 104.0).unwrap();
        assert_eq!(sample.rtt_ms, 4.0);
        assert_eq!(sample.offset_ms, 5000.0 - 102.0);
        let samples = [
            ClockSample { rtt_ms: 5.0, offset_ms: 1.0 },
            ClockSample { rtt_ms: 0.3, offset_ms: 2.0 },
            ClockSample { rtt_ms: 2.0, offset_ms: 3.0 },
        ];
        assert_eq!(best_offset(&samples), Some(2.0));
        assert_eq!(best_offset(&[]), None);
        assert_eq!(ping(12.5), "p:12.5");
    }

    #[test]
    fn averages() {
        assert_eq!(average(&[]), None);
        assert_eq!(average(&[2.0, 4.0]), Some(3.0));
        assert_eq!(maximum(&[1.0, 7.0, 3.0]), Some(7.0));
        assert_eq!(maximum(&[]), None);
    }

    #[test]
    fn stats_message_matches_the_mac_fields() {
        let summary = StatsSummary { total: Some(9.5), fps: 60, mbps: 8.25, drops: 1, ..Default::default() };
        assert_eq!(
            summary.message(),
            "s:{\"total\":9.500,\"encode\":null,\"network\":null,\"decode\":null,\"browser\":null,\
             \"pointer\":null,\"rtt\":null,\"fps\":60,\"mbps\":8.250,\"drops\":1}"
        );
    }

    #[test]
    fn parses_http_responses() {
        let (status, body) = parse_http_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi").unwrap();
        assert_eq!(status, 200);
        assert_eq!(body, b"hi");
        assert_eq!(parse_http_response(b"garbage"), None);
    }

    #[test]
    fn splits_hosts() {
        assert_eq!(split_host("192.168.1.20:9000"), ("192.168.1.20".to_string(), 9000));
        assert_eq!(split_host("http://mac.local/"), ("mac.local".to_string(), 8080));
    }

    #[test]
    fn compares_versions() {
        assert!(is_newer("0.10.0", "0.9.2"));
        assert!(is_newer("1.0", "0.99.99"));
        assert!(!is_newer("0.1.0", "0.1.0"));
        assert!(!is_newer("0.1", "0.1.0"));
    }

    #[test]
    fn fits_with_letterboxing() {
        assert_eq!(fit(1920, 1080, 1920, 1200), Rect { x: 0.0, y: 60.0, width: 1920.0, height: 1080.0 });
        assert_eq!(fit(1920, 1080, 3840, 2160), Rect { x: 0.0, y: 0.0, width: 3840.0, height: 2160.0 });
    }
}
