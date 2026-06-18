import CoreImage
enum CIImageColor {
    static let green = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
}
