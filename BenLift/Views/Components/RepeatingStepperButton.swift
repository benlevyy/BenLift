import SwiftUI

/// Button that fires `action` once on tap, and repeatedly on long-press with
/// an accelerating cadence — the pattern Apple uses on the Clock app's
/// timer setter and on the Photos crop inspector.
///
/// Cadence schedule (seconds between fires):
///  • first 0.4s: holding registers, then 0.35s/tick for 4 ticks
///  • next second: 0.2s/tick
///  • then steady 0.08s/tick
///
/// One selection haptic fires per tick at the slower rates; at the fastest
/// rate haptics space out to every third tick so the device doesn't buzz
/// into a continuous hum.
struct RepeatingStepperButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var timer: Timer?
    @State private var ticksFired: Int = 0

    var body: some View {
        // Wrap in a shape-backed button so the whole frame is the hit
        // target (not just the glyph). We intentionally don't use the
        // plain Button's action — the simultaneous tap gesture handles
        // single taps so we don't double-fire alongside the long-press
        // release path.
        label()
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.selection()
                action()
            }
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30) {
                // onLongPressGesture's `perform` fires once the threshold
                // is crossed. We use that as "start scrubbing."
                startScrubbing()
            } onPressingChanged: { pressing in
                // When finger lifts, onPressingChanged(false) fires —
                // that's our cue to stop the timer.
                if !pressing { stopScrubbing() }
            }
    }

    private func startScrubbing() {
        // One immediate fire so the hold feels responsive.
        Haptics.impact(.light)
        action()
        ticksFired = 0
        scheduleNext()
    }

    private func scheduleNext() {
        let interval = cadence(for: ticksFired)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            ticksFired += 1
            action()
            // Haptic throttling: every tick below 8, every 3rd above.
            if ticksFired < 8 || ticksFired % 3 == 0 {
                Haptics.selection()
            }
            scheduleNext()
        }
    }

    private func stopScrubbing() {
        timer?.invalidate()
        timer = nil
        ticksFired = 0
    }

    /// Accelerating cadence. Tuned so:
    ///  • small corrections feel deliberate (first few ticks slow)
    ///  • long scrubs reach ~12 units/sec quickly for bigger jumps
    private func cadence(for tick: Int) -> TimeInterval {
        switch tick {
        case ..<4:  return 0.30
        case ..<10: return 0.15
        default:    return 0.08
        }
    }
}
