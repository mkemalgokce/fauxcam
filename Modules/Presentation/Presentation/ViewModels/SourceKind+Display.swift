import Foundation

extension SessionModel.SourceKind: CaseIterable, Identifiable {
    public static var allCases: [SessionModel.SourceKind] { [.media, .camera, .qr] }
    public var id: Self { self }
    var symbol: String {
        switch self {
        case .media: return "photo.on.rectangle.angled"
        case .camera: return "web.camera"
        case .qr: return "qrcode"
        }
    }
    var title: String {
        switch self {
        case .media: return "Media"
        case .camera: return "Camera"
        case .qr: return "QR"
        }
    }
}
