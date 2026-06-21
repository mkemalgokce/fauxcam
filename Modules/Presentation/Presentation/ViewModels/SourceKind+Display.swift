import Foundation

/// Display strings for `SessionModel.SourceKind` (the legacy 4-case `image`/`webcam`/`video`/`qr`
/// table). The view-level Media/Camera/QR 3-tab collapse lives in `SourceTabBar`.
extension SessionModel.SourceKind {
    var title: String {
        switch self {
        case .image: return "Test Image"
        case .webcam: return "Mac Camera"
        case .video: return "Video File"
        case .qr: return "QR Code"
        }
    }
    var shortTitle: String {
        switch self {
        case .image: return "Image"
        case .webcam: return "Camera"
        case .video: return "Video"
        case .qr: return "QR"
        }
    }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .webcam: return "web.camera"
        case .video: return "film"
        case .qr: return "qrcode"
        }
    }
    var needsDetail: Bool { self == .video || self == .qr }
    var supportsFraming: Bool { true }
    var footerHint: String {
        switch self {
        case .image: return "A built-in test image is shown to the app's camera."
        case .webcam: return "Your Mac camera is mirrored into the app's camera."
        case .video: return "The chosen video file plays as the app's camera."
        case .qr: return "A QR code is generated from your text and shown to the camera."
        }
    }
}
