//! Paneport Receiver: shows a Mac's Paneport virtual displays fullscreen on this PC's monitors,
//! with lower delay than the browser page.
//!
//!     PaneportReceiver.exe [--host 192.168.1.20:8080] [--setup] [--vsync]
//!
//! Threads per display: network (WebSocket, clock sync, stats) → decoder (Media Foundation
//! H.264) → renderer (Direct3D 11, flip model). Pointer updates go straight from the network
//! thread to the renderer, so the pointer never waits for video.

#![cfg_attr(not(windows), allow(dead_code))]

mod protocol;

#[cfg(windows)]
mod api;
#[cfg(windows)]
mod app;
#[cfg(windows)]
mod config;
#[cfg(windows)]
mod decoder;
#[cfg(windows)]
mod renderer;
#[cfg(windows)]
mod session;
#[cfg(windows)]
mod setup;
#[cfg(windows)]
mod update;

#[cfg(not(windows))]
fn main() {
    eprintln!("Paneport Receiver runs on Windows. On other systems, use the browser page.");
}

#[cfg(windows)]
fn main() {
    if let Err(message) = run() {
        eprintln!("\n{message}");
        config::prompt("\nPress Enter to close.");
        std::process::exit(1);
    }
}

#[cfg(windows)]
struct Options {
    host: Option<String>,
    setup: bool,
    vsync: bool,
}

#[cfg(windows)]
fn parse_options() -> Result<Options, String> {
    let mut options = Options { host: None, setup: false, vsync: false };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--host" => options.host = Some(args.next().ok_or("--host needs an address, like 192.168.1.20:8080")?),
            "--setup" => options.setup = true,
            "--vsync" => options.vsync = true,
            "--help" | "-h" => {
                println!(
                    "Paneport Receiver {}\n\n\
                     Usage: PaneportReceiver.exe [--host ADDRESS] [--setup] [--vsync]\n\n  \
                     --host ADDRESS  the Mac's address from Paneport's Connect tab (remembered)\n  \
                     --setup         choose which display goes on which monitor again\n  \
                     --vsync         wait for the monitor's refresh (no tearing, slightly more delay)\n\n\
                     Press Esc on a Paneport screen to quit.",
                    env!("CARGO_PKG_VERSION")
                );
                std::process::exit(0);
            }
            other => return Err(format!("Unknown option {other}. Run with --help for the options.")),
        }
    }
    Ok(options)
}

#[cfg(windows)]
fn run() -> Result<(), String> {
    update::remove_leftovers();
    let options = parse_options()?;
    println!("Paneport Receiver {}", env!("CARGO_PKG_VERSION"));

    let mut config = config::Config::load();
    if options.setup {
        config.assignments.clear();
    }

    let host = match options.host.or_else(|| config.host.clone()) {
        Some(host) => host,
        None => config::prompt("Mac address, as shown on Paneport's Connect tab (for example 192.168.1.20:8080): "),
    };
    let mac = api::MacClient::new(&host);
    let version = mac
        .version()
        .map_err(|e| format!("Can't reach Paneport at {host}: {e}\nCheck the address and that Paneport is running."))?;
    update::check(&mac, &version)?;

    config.host = Some(host);
    config.save();

    let displays = mac.displays()?;
    if displays.is_empty() {
        return Err(
            "The Mac isn't streaming any displays. Press Start Streaming in Paneport, then run this again.".into()
        );
    }
    app::run(app::Startup { mac_host: mac.host().to_string(), displays, config, vsync: options.vsync })
}
