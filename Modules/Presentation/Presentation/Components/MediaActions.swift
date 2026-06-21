import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Media-source row (legacy `RootView.sourceDetail` `.media` case): Choose / Paste glass buttons plus a
/// chip showing the current Media file (or "Test image") with an inline reset to the default.
struct MediaActions: View {
    let session: SessionModel

    var body: some View {
        HStack(spacing: 6) {
            Button(action: choose) { Label("Choose", systemImage: "folder") }
                .buttonStyle(.glass).controlSize(.small).help("Pick an image or video file")
            Button { session.paste() } label: { Label("Paste", systemImage: "clipboard") }
                .buttonStyle(.glass).controlSize(.small).help("Paste an image or video (⌘V)")
            Spacer(minLength: 4)
            mediaChip
        }
    }

    /// Shows the current Media file (or "Test image") with an inline button to clear back to the default.
    private var mediaChip: some View {
        HStack(spacing: 5) {
            Image(systemName: session.hasCustomMedia ? mediaIcon : "photo").font(.caption2).foregroundStyle(.secondary)
            Text(session.mediaLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if session.hasCustomMedia {
                Button {
                    session.imagePath = ""; session.videoPath = ""; session.sourceKind = .image
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Reset to the test image")
            }
        }
        .padding(.leading, 8).padding(.trailing, session.hasCustomMedia ? 5 : 8).padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .frame(maxWidth: 168, alignment: .trailing)
    }

    private var mediaIcon: String { session.sourceKind == .video ? "film" : "photo" }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { session.chooseMedia(url) }
    }
}
