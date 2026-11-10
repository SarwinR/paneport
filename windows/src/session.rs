//! One display's stream: the network thread, and the render thread it feeds.
//!
//! network thread ── encoded frames ──▶ decoder thread ── decoded frames ──┐
//!       └──────────── pointer position and image ─────────────────────────┴▶ render thread

use crate::api::{DisplayInfo, Hello, PointerShapeMessage};
use crate::decoder;
use crate::protocol::{
    average, best_offset, clock_sample, parse_frame, parse_pointer_position, ping, ClockSample, PointerPosition,
    StatsSummary, PROTOCOL_VERSION,
};
use crate::renderer::Renderer;
use base64::Engine as _;
use std::io::ErrorKind;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tungstenite::Message;

/// A decoder this many frames behind skips to the next keyframe instead of building up delay.
const MAX_DECODER_BACKLOG: usize = 3;
/// How long a read waits before the loop sends pings, stats and keyframe requests.
const READ_TIMEOUT: Duration = Duration::from_millis(4);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
/// Latency is printed to the console this often.
const PRINT_EVERY_SECONDS: u32 = 5;

/// Milliseconds since the app started; every local time uses this clock.
pub fn now_ms() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

#[derive(Debug, Clone, Copy)]
pub struct FrameTiming {
    /// Mac host clock, microseconds.
    pub captured_micros: u64,
    pub sent_micros: u64,
    /// Local clock, milliseconds.
    pub arrived_ms: f64,
}

pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub is_keyframe: bool,
    pub timing: FrameTiming,
}

/// NV12: a luma plane of `stride` × `height` bytes, then interleaved chroma of `stride` × `height / 2`.
pub struct DecodedFrame {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub data: Vec<u8>,
    pub chroma_offset: usize,
    pub timing: Option<FrameTiming>,
    pub decoded_ms: f64,
}

/// The pointer image, RGBA, with its size and hot spot in stream pixels.
pub struct PointerImage {
    pub rgba: Vec<u8>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub width: f32,
    pub height: f32,
    pub hot_x: f32,
    pub hot_y: f32,
}

pub enum RenderEvent {
    Video(DecodedFrame),
    Pointer(PointerPosition),
    PointerImage(PointerImage),
}

/// Measurements for the current second.
#[derive(Default)]
pub struct StatsWindow {
    pub total: Vec<f64>,
    pub encode: Vec<f64>,
    pub network: Vec<f64>,
    pub decode: Vec<f64>,
    pub present: Vec<f64>,
    pub pointer: Vec<f64>,
    pub shown: u32,
    pub bytes: u64,
    pub drops: u32,
}

/// State shared by one display's threads.
pub struct Shared {
    pub name: String,
    pub stats: Mutex<StatsWindow>,
    /// Mac clock minus local clock, in milliseconds, once known.
    pub clock_offset: Mutex<Option<f64>>,
}

impl Shared {
    fn offset(&self) -> Option<f64> {
        *self.clock_offset.lock().unwrap()
    }
}

/// Starts streaming `display` into the window `hwnd`.
pub fn start(display: DisplayInfo, mac_host: String, hwnd: isize, vsync: bool) {
    let shared = Arc::new(Shared {
        name: display.name.clone(),
        stats: Mutex::new(StatsWindow::default()),
        clock_offset: Mutex::new(None),
    });
    let (render_tx, render_rx) = mpsc::channel();

    let render_shared = shared.clone();
    let _ = thread::Builder::new()
        .name(format!("render: {}", display.name))
        .spawn(move || render_loop(hwnd, vsync, render_rx, render_shared));

    let _ = thread::Builder::new()
        .name(format!("network: {}", display.name))
        .spawn(move || network_loop(display, mac_host, shared, render_tx));
}

// MARK: - Rendering

fn render_loop(hwnd: isize, vsync: bool, events: Receiver<RenderEvent>, shared: Arc<Shared>) {
    let mut renderer = match Renderer::new(hwnd, vsync) {
        Ok(renderer) => renderer,
        Err(e) => {
            eprintln!("{}: couldn't set up graphics: {e}", shared.name);
            return;
        }
    };
    let _ = renderer.present();

    while let Ok(first) = events.recv() {
        // Handle everything that's waiting, then draw once.
        let mut frame_timing = None;
        let mut pointer_micros = None;
        for event in std::iter::once(first).chain(events.try_iter()) {
            match event {
                RenderEvent::Video(frame) => {
                    if let Err(e) = renderer.upload_video(&frame) {
                        eprintln!("{}: couldn't upload a frame: {e}", shared.name);
                        continue;
                    }
                    frame_timing = frame.timing.map(|t| (t, frame.decoded_ms));
                }
                RenderEvent::Pointer(position) => {
                    if position.visible {
                        pointer_micros = Some(position.micros);
                    }
                    renderer.set_pointer(position);
                }
                RenderEvent::PointerImage(image) => {
                    if let Err(e) = renderer.set_pointer_image(&image) {
                        eprintln!("{}: couldn't load the pointer image: {e}", shared.name);
                    }
                }
            }
        }
        if let Err(e) = renderer.present() {
            eprintln!("{}: drawing failed: {e}", shared.name);
            return;
        }
        record_presentation(&shared, frame_timing, pointer_micros, now_ms());
    }
}

fn record_presentation(
    shared: &Shared,
    frame: Option<(FrameTiming, f64)>,
    pointer_micros: Option<u64>,
    presented_ms: f64,
) {
    let offset = shared.offset();
    let mut stats = shared.stats.lock().unwrap();
    if let Some((timing, decoded_ms)) = frame {
        stats.shown += 1;
        stats.decode.push(decoded_ms - timing.arrived_ms);
        stats.present.push(presented_ms - decoded_ms);
        if let Some(offset) = offset {
            stats.encode.push((timing.sent_micros as f64 - timing.captured_micros as f64) / 1000.0);
            stats.network.push((timing.arrived_ms + offset - timing.sent_micros as f64 / 1000.0).max(0.0));
            stats.total.push(presented_ms + offset - timing.captured_micros as f64 / 1000.0);
        }
    }
    if let (Some(micros), Some(offset)) = (pointer_micros, offset) {
        stats.pointer.push((presented_ms + offset - micros as f64 / 1000.0).max(0.0));
    }
}

// MARK: - Network

enum StreamEnd {
    /// Try again shortly (the Mac restarted, the network dropped).
    Retry(String),
    /// Retrying won't help.
    Stop(String),
}

fn network_loop(display: DisplayInfo, mac_host: String, shared: Arc<Shared>, render: Sender<RenderEvent>) {
    loop {
        match stream_display(&display, &mac_host, &shared, &render) {
            StreamEnd::Retry(reason) => {
                eprintln!("{}: {reason}; reconnecting…", display.name);
                thread::sleep(RECONNECT_DELAY);
            }
            StreamEnd::Stop(reason) => {
                eprintln!("{}: {reason}", display.name);
                return;
            }
        }
    }
}

/// Connection-level state for one WebSocket session.
struct Connection {
    decoder: Option<Sender<EncodedFrame>>,
    /// Frames sent to the decoder but not yet decoded. Per connection, so a decoder left
    /// over from a dropped connection can't throw the count off.
    decoder_backlog: Arc<AtomicUsize>,
    waiting_for_keyframe: bool,
    clock_samples: Vec<ClockSample>,
    last_rtt: Option<f64>,
}

fn stream_display(display: &DisplayInfo, host: &str, shared: &Arc<Shared>, render: &Sender<RenderEvent>) -> StreamEnd {
    let mut socket = match connect(host, display.port) {
        Ok(socket) => socket,
        Err(e) => return StreamEnd::Retry(e),
    };
    let (outbox, outgoing) = mpsc::channel::<String>();
    let mut connection = Connection {
        decoder: None,
        decoder_backlog: Arc::new(AtomicUsize::new(0)),
        waiting_for_keyframe: true,
        clock_samples: Vec::new(),
        last_rtt: None,
    };
    *shared.clock_offset.lock().unwrap() = None;

    let started = now_ms();
    let mut pings_sent = 0u32;
    let mut next_ping = started;
    let mut next_stats = started + 1000.0;
    let mut seconds = 0u32;

    loop {
        match socket.read() {
            Ok(Message::Binary(data)) => {
                if let Err(end) = on_frame(&data, shared, &mut connection, &outbox) {
                    return end;
                }
            }
            Ok(Message::Text(text)) => {
                if let Err(end) = on_text(&text, shared, &mut connection, render, &outbox) {
                    return end;
                }
            }
            Ok(Message::Close(_)) => return StreamEnd::Retry("the Mac closed the stream".into()),
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(e) => return StreamEnd::Retry(format!("connection lost ({e})")),
        }

        let now = now_ms();
        // Clock sync: five quick pings, then one a second.
        if now >= next_ping {
            let _ = outbox.send(ping(now));
            pings_sent += 1;
            next_ping = now + if pings_sent < 5 { 100.0 } else { 1000.0 };
        }
        if now >= next_stats {
            next_stats += 1000.0;
            seconds += 1;
            let summary = take_summary(shared, connection.last_rtt);
            let _ = outbox.send(summary.message());
            if seconds % PRINT_EVERY_SECONDS == 0 {
                print_summary(&shared.name, &summary);
            }
        }
        for message in outgoing.try_iter() {
            if let Err(e) = socket.send(Message::Text(message)) {
                return StreamEnd::Retry(format!("connection lost ({e})"));
            }
        }
    }
}

type Socket = tungstenite::WebSocket<TcpStream>;

fn connect(host: &str, port: u16) -> Result<Socket, String> {
    let address = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("can't resolve {host}: {e}"))?
        .next()
        .ok_or_else(|| format!("can't resolve {host}"))?;
    let stream = TcpStream::connect_timeout(&address, Duration::from_secs(3))
        .map_err(|e| format!("can't connect to {host}:{port} ({e})"))?;
    stream.set_nodelay(true).map_err(|e| e.to_string())?; // send small messages immediately
    let (socket, _) = tungstenite::client(format!("ws://{host}:{port}/"), stream)
        .map_err(|e| format!("WebSocket handshake failed ({e})"))?;
    socket.get_ref().set_read_timeout(Some(READ_TIMEOUT)).map_err(|e| e.to_string())?;
    Ok(socket)
}

fn on_frame(
    data: &[u8],
    shared: &Shared,
    connection: &mut Connection,
    outbox: &Sender<String>,
) -> Result<(), StreamEnd> {
    let arrived_ms = now_ms();
    let Some(frame) = parse_frame(data) else { return Ok(()) };
    shared.stats.lock().unwrap().bytes += data.len() as u64;
    let Some(decoder) = &connection.decoder else { return Ok(()) }; // no hello yet

    if connection.waiting_for_keyframe && !frame.is_keyframe {
        return Ok(());
    }
    if !frame.is_keyframe && connection.decoder_backlog.load(Ordering::SeqCst) > MAX_DECODER_BACKLOG {
        connection.waiting_for_keyframe = true;
        shared.stats.lock().unwrap().drops += 1;
        let _ = outbox.send("k".to_string());
        return Ok(());
    }
    connection.waiting_for_keyframe = false;

    connection.decoder_backlog.fetch_add(1, Ordering::SeqCst);
    let encoded = EncodedFrame {
        data: frame.payload.to_vec(),
        is_keyframe: frame.is_keyframe,
        timing: FrameTiming { captured_micros: frame.captured_micros, sent_micros: frame.sent_micros, arrived_ms },
    };
    decoder.send(encoded).map_err(|_| StreamEnd::Retry("the decoder stopped".into()))
}

fn on_text(
    text: &str,
    shared: &Arc<Shared>,
    connection: &mut Connection,
    render: &Sender<RenderEvent>,
    outbox: &Sender<String>,
) -> Result<(), StreamEnd> {
    if text.starts_with("m:") {
        if let Some(position) = parse_pointer_position(text) {
            let _ = render.send(RenderEvent::Pointer(position));
        }
    } else if text.starts_with("q:") {
        if let Some(sample) = clock_sample(text, now_ms()) {
            connection.last_rtt = Some(sample.rtt_ms);
            connection.clock_samples.push(sample);
            if connection.clock_samples.len() > 20 {
                connection.clock_samples.remove(0);
            }
            *shared.clock_offset.lock().unwrap() = best_offset(&connection.clock_samples);
        }
    } else if text.starts_with("c:") {
        match decode_pointer_image(text) {
            Some(image) => {
                let _ = render.send(RenderEvent::PointerImage(image));
            }
            None => eprintln!("{}: couldn't read the pointer image", shared.name),
        }
    } else if let Some(json) = text.strip_prefix("h:") {
        let hello: Hello =
            serde_json::from_str(json).map_err(|e| StreamEnd::Retry(format!("unreadable hello from the Mac ({e})")))?;
        if hello.protocol != PROTOCOL_VERSION {
            return Err(StreamEnd::Stop(format!(
                "the Mac's Paneport {} uses protocol {}, but this app uses {}. Restart this app to update it.",
                hello.app, hello.protocol, PROTOCOL_VERSION
            )));
        }
        connection.decoder = Some(decoder::spawn(
            hello.width,
            hello.height,
            shared.clone(),
            render.clone(),
            outbox.clone(),
            connection.decoder_backlog.clone(),
        ));
        connection.waiting_for_keyframe = true;
    }
    Ok(())
}

fn decode_pointer_image(text: &str) -> Option<PointerImage> {
    let message: PointerShapeMessage = serde_json::from_str(text.strip_prefix("c:")?).ok()?;
    let png_bytes = base64::engine::general_purpose::STANDARD.decode(message.png).ok()?;
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png_bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buffer).ok()?;
    let pixels = &buffer[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => pixels.to_vec(),
        png::ColorType::Rgb => pixels.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => pixels.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Grayscale => pixels.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return None, // EXPAND turns palettes into RGB(A)
    };
    Some(PointerImage {
        rgba,
        pixel_width: info.width,
        pixel_height: info.height,
        width: message.w as f32,
        height: message.h as f32,
        hot_x: message.hx as f32,
        hot_y: message.hy as f32,
    })
}

fn take_summary(shared: &Shared, rtt: Option<f64>) -> StatsSummary {
    let window = std::mem::take(&mut *shared.stats.lock().unwrap());
    StatsSummary {
        total: average(&window.total),
        encode: average(&window.encode),
        network: average(&window.network),
        decode: average(&window.decode),
        present: average(&window.present),
        pointer: average(&window.pointer),
        rtt,
        fps: window.shown,
        mbps: window.bytes as f64 * 8.0 / 1_000_000.0,
        drops: window.drops,
    }
}

fn print_summary(name: &str, s: &StatsSummary) {
    let ms = |v: Option<f64>| v.map_or("–".to_string(), |v| format!("{v:.1}"));
    println!(
        "{name}: {} ms delay (encode {}, network {}, decode {}, present {}), pointer {} ms, {} fps, {:.1} Mbit/s",
        ms(s.total),
        ms(s.encode),
        ms(s.network),
        ms(s.decode),
        ms(s.present),
        ms(s.pointer),
        s.fps,
        s.mbps
    );
}
