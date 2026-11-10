import CoreMedia

/// The Mac's host clock. ScreenCaptureKit stamps frames with this clock, so frame
/// timestamps and "now" can be compared directly. Viewers sync to it for latency stats.
enum HostClock {
    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    static func nowMicros() -> UInt64 {
        micros(now())
    }

    /// Microseconds for a host-clock time; 0 for invalid or negative times.
    static func micros(_ time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000)
    }
}
