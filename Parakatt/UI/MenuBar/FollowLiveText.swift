import SwiftUI
import AppKit

/// Wheel observation is local to this scroll view. It never consumes the event.
private struct ScrollIntent: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    func makeCoordinator() -> Coordinator { Coordinator(onScroll) }
    final class Coordinator {
        weak var view: NSView?
        var onScroll: () -> Void
        var monitor: Any?
        init(_ callback: @escaping () -> Void) {
            onScroll = callback
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, let view = self.view, view.window === event.window,
                   view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { self.onScroll() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
struct FollowLiveText: View {
    let text: Text
    let revision: String
    @State private var following = true
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .trailing, spacing: 4) {
                ScrollView {
                    text.font(.system(.body, design: .rounded)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("liveBottom")
                }
                .background(ScrollIntent { following = false })
                .onChange(of: revision) { _, _ in if following { proxy.scrollTo("liveBottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("liveBottom", anchor: .bottom) }
                if !following {
                    Button("Follow live") { following = true; proxy.scrollTo("liveBottom", anchor: .bottom) }
                        .font(.caption).buttonStyle(.borderless)
                }
            }
        }.frame(maxHeight: 160)
    }
}
