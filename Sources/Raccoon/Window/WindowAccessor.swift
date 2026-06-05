import SwiftUI
import AppKit

/// A zero-size `NSViewRepresentable` that captures the hosting `NSWindow` and hands it
/// back via `onResolve`, so SwiftUI views can act on the real `NSWindow` (e.g. to pin it).
///
/// `view.window` is `nil` while the view is being inserted into the hierarchy, so we
/// resolve it on the next runloop tick and only fire the callback once.
struct WindowAccessor: NSViewRepresentable {
    /// Called once with the resolved window. Runs on the main actor.
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view isn't attached to a window yet inside makeNSView; defer the lookup.
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Fallback in case the window wasn't available on the first async tick.
        if let window = nsView.window {
            DispatchQueue.main.async {
                onResolve(window)
            }
        }
    }
}
