//! The window side: one borderless fullscreen window per chosen monitor.

use crate::api::DisplayInfo;
use crate::config::Config;
use crate::{session, setup};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::monitor::MonitorHandle;
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::{Fullscreen, Window, WindowId};

pub struct Startup {
    pub mac_host: String,
    pub displays: Vec<DisplayInfo>,
    pub config: Config,
    pub vsync: bool,
}

struct App {
    startup: Startup,
    windows: Vec<Window>,
    started: bool,
}

pub fn run(startup: Startup) -> Result<(), String> {
    let event_loop = EventLoop::new().map_err(|e| format!("Couldn't start: {e}"))?;
    let mut app = App { startup, windows: Vec::new(), started: false };
    event_loop.run_app(&mut app).map_err(|e| e.to_string())
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.started {
            return;
        }
        self.started = true;

        let monitors: Vec<MonitorHandle> = event_loop.available_monitors().collect();
        let primary = event_loop.primary_monitor();
        let assignments = setup::assign(&self.startup.displays, &monitors, primary.as_ref(), &mut self.startup.config);
        self.startup.config.save();
        if assignments.is_empty() {
            println!("No monitors chosen, so there's nothing to show. Run with --setup to choose again.");
            event_loop.exit();
            return;
        }

        for (display, monitor) in assignments {
            let attributes = Window::default_attributes()
                .with_title(format!("Paneport – {}", display.name))
                .with_fullscreen(Some(Fullscreen::Borderless(Some(monitor))));
            let window = match event_loop.create_window(attributes) {
                Ok(window) => window,
                Err(e) => {
                    eprintln!("Couldn't open a window for \"{}\": {e}", display.name);
                    continue;
                }
            };
            window.set_cursor_visible(false); // the Mac's pointer is drawn instead
            match window_handle(&window) {
                Some(hwnd) => {
                    println!("Showing \"{}\". Press Esc on a Paneport screen to quit.", display.name);
                    session::start(display, self.startup.mac_host.clone(), hwnd, self.startup.vsync);
                }
                None => eprintln!("Couldn't get a window handle for \"{}\".", display.name),
            }
            self.windows.push(window);
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::KeyboardInput { event, .. }
                if event.state == ElementState::Pressed && event.logical_key == Key::Named(NamedKey::Escape) =>
            {
                event_loop.exit()
            }
            _ => {}
        }
    }
}

/// The Win32 window handle, as an integer so it can be passed to the render thread.
fn window_handle(window: &Window) -> Option<isize> {
    match window.window_handle().ok()?.as_raw() {
        RawWindowHandle::Win32(handle) => Some(handle.hwnd.get()),
        _ => None,
    }
}
