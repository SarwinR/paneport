//! Choosing which Mac display goes on which of this PC's monitors.

use crate::api::DisplayInfo;
use crate::config::{prompt, Assignment, Config};
use winit::monitor::MonitorHandle;

fn monitor_name(monitor: &MonitorHandle) -> String {
    monitor.name().unwrap_or_else(|| "unknown monitor".to_string())
}

/// Uses the saved choices when they still fit this setup; otherwise asks in the console
/// and saves the answers in `config`.
pub fn assign(
    displays: &[DisplayInfo],
    monitors: &[MonitorHandle],
    primary: Option<&MonitorHandle>,
    config: &mut Config,
) -> Vec<(DisplayInfo, MonitorHandle)> {
    let saved: Vec<(DisplayInfo, MonitorHandle)> = config
        .assignments
        .iter()
        .filter_map(|a| {
            let display = displays.iter().find(|d| d.name == a.display)?;
            let monitor = monitors.iter().find(|m| monitor_name(m) == a.monitor)?;
            Some((display.clone(), monitor.clone()))
        })
        .collect();
    if !saved.is_empty() && saved.len() == config.assignments.len() {
        println!("Using your saved monitor choices (run with --setup to change them).");
        return saved;
    }

    println!("\nMonitors on this PC:");
    for (index, monitor) in monitors.iter().enumerate() {
        let size = monitor.size();
        let position = monitor.position();
        let main = if Some(monitor) == primary { "  (main)" } else { "" };
        println!(
            "  {}: {}  {}×{} at {},{}{main}",
            index + 1,
            monitor_name(monitor),
            size.width,
            size.height,
            position.x,
            position.y
        );
    }
    println!();

    config.assignments.clear();
    let mut chosen = Vec::new();
    for display in displays {
        let answer = prompt(&format!(
            "Show \"{}\" ({}×{}) on which monitor? Enter its number, or press Enter to skip: ",
            display.name, display.width, display.height
        ));
        let Ok(number) = answer.parse::<usize>() else { continue };
        let Some(monitor) = number.checked_sub(1).and_then(|i| monitors.get(i)) else {
            println!("  There's no monitor {number}; skipping.");
            continue;
        };
        config.assignments.push(Assignment { display: display.name.clone(), monitor: monitor_name(monitor) });
        chosen.push((display.clone(), monitor.clone()));
    }
    chosen
}
