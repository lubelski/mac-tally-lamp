import SwiftUI

extension EnvironmentValues {
    /// A moment to draw instead of the real time. Set by `--render-previews`, so a rendering
    /// shows a chosen moment and never waits on a timeline.
    @Entry var frozenNow: Date?
    /// True while `--render-previews` draws a view offscreen. A sidebar list's selection draws
    /// as a black block in a window that was never on screen, so previews draw a stand-in
    /// highlight for the selected row instead.
    @Entry var isRenderingPreview = false
}

extension View {
    /// The stand-in selection highlight `--render-previews` draws. See `isRenderingPreview`.
    func previewSelection(_ selected: Bool, rendering: Bool) -> some View {
        listRowBackground(
            rendering && selected
                ? RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)).padding(.horizontal, 10)
                : nil)
    }
}

/// Redraws its content with the current time, once a second. Only the drawing repeats: what
/// is drawn is computed from the claims and the time each time.
struct Ticking<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.frozenNow) private var frozenNow

    var body: some View {
        if let frozenNow {
            content(frozenNow)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        }
    }
}
