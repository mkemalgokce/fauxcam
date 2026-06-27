import SwiftUI

/// The Media / Camera / QR selector — a Liquid Glass container of segment buttons.
///
/// `SessionModel.SourceKind` has four cases (`image`/`webcam`/`video`/`qr`); the panel collapses
/// them into three visible tabs (Media spans `image`+`video`). That Media/Camera/QR collapse is a
/// view-level concern, modelled here by `SourceTab` mapped onto the 4-case `SourceKind`.
struct SourceTabBar: View {
    @Binding var sourceKind: SessionModel.SourceKind
    let videoPath: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The three visible tabs (legacy `RootView.SourceTab`).
    enum SourceTab: CaseIterable, Identifiable {
        case media, camera, qr
        var id: Self { self }
        var symbol: String {
            switch self { case .media: return "photo.on.rectangle.angled"; case .camera: return "web.camera"; case .qr: return "qrcode" }
        }
        var title: String {
            switch self { case .media: return "Media"; case .camera: return "Camera"; case .qr: return "QR" }
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SourceTab.allCases) { tabButton($0) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selectedTab)
    }

    private var selectedTab: SourceTab {
        switch sourceKind { case .image, .video: return .media; case .webcam: return .camera; case .qr: return .qr }
    }

    private func selectTab(_ tab: SourceTab) {
        switch tab {
        case .media:
            if sourceKind != .image, sourceKind != .video {
                sourceKind = videoPath.isEmpty ? .image : .video
            }
        case .camera: sourceKind = .webcam
        case .qr: sourceKind = .qr
        }
    }

    private func tabButton(_ tab: SourceTab) -> some View {
        let selected = selectedTab == tab
        return Button { selectTab(tab) } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 15, weight: .medium))
                Text(tab.title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        // Each tab is its own Liquid Glass segment (selected = accent-tinted glass); the surrounding
        // GlassEffectContainer lets them morph as the selection moves.
        .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 9))
        .accessibilityLabel(tab.title)
    }
}
