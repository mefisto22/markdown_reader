import AppKit
import QuartzCore

/// When the user last scrolled, dragged or typed. Work that runs on the main
/// thread in slices (rendering the reader, highlighting the editor) uses
/// short slices while the user interacts, so scrolling stays smooth while a
/// document is still being rendered.
enum UserActivity {
    private static var lastInput: CFTimeInterval = 0
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDragged]) { event in
            noteInput()
            return event
        }
    }

    static func noteInput() {
        lastInput = CACurrentMediaTime()
    }

    static var isInteracting: Bool {
        CACurrentMediaTime() - lastInput < 0.5
    }

    /// Time budget for one slice of main-thread work that normally takes `idle`.
    static func sliceBudget(idle: TimeInterval) -> TimeInterval {
        isInteracting ? min(idle, 0.003) : idle
    }

    /// Pause before the next slice. While the user interacts, the pause lets
    /// the run loop go idle, which is when AppKit draws the next frame.
    static var sliceDelay: TimeInterval {
        isInteracting ? 0.010 : 0.001
    }
}
