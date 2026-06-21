import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Media-source row: Choose / Paste (glass buttons) + a chip showing the current media with a reset.
struct MediaActions: View {
    let session: SessionModel

    var body: some View {
        HStack(spacing: 6) {
            Button(action: choose) { Label("Choose", systemImage: "folder") }
                .buttonStyle(.glass).controlSize(.small).help("Pick an image or video file")
            Button { session.paste() } label: { Label("Paste", systemImage: "clipboard") }
                .buttonStyle(.glass).controlSize(.small).help("Paste an image or video (⌘V)")
            Spacer(minLength: 4)
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
            Text(session.mediaLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if session.hasCustomMedia {
                Button { session.resetMedia() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Reset to the test image")
            }
        }
        .padding(.leading, 8).padding(.trailing, session.hasCustomMedia ? 5 : 8).padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .frame(maxWidth: 168, alignment: .trailing)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { session.chooseMedia(url) }
    }
}
