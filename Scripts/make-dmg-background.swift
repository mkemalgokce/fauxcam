#!/usr/bin/env swift

/// Renders the FauxCam disk-image background to Assets/dmg/background.png at 2x.
///
/// Layout (bottom-up CoreGraphics coordinates, 1080x760 = 2x of the 540x380 DMG window):
/// a deep gradient with a warm brand glow behind the logo, the logo + wordmark + tagline near
/// the top, two rounded "wells" grounding the app icon (left) and the Applications drop-link
/// (right) with an arrow guiding the drag between them, and a dim footer.
///
/// The PNG is written at 144 DPI (its point size is the 540x380 window, its pixel size 2x that),
/// so Finder maps every well to its icon: the wells at pixels 280/800 land on the create-dmg icon
/// points 140/400. Tagging it as Retina is what keeps the artwork sized to the window instead of
/// being shown 1:1 (oversized, misaligned, icons outside the wells).
///
/// Usage: swift Scripts/make-dmg-background.swift [logo-png] [output-png]

import AppKit

let backgroundPixelWidth = 1080
let backgroundPixelHeight = 760
let canvasWidth = CGFloat(backgroundPixelWidth)
let canvasHeight = CGFloat(backgroundPixelHeight)
let windowPointSize = NSSize(width: 540, height: 380)

let logoTopMargin: CGFloat = 66
let logoSide: CGFloat = 150
let titleToLogoGap: CGFloat = 14
let taglineToTitleGap: CGFloat = 12

let iconCenterYFromTop: CGFloat = 462
let leftIconCenterX: CGFloat = 280
let rightIconCenterX: CGFloat = 800
let iconWellSide: CGFloat = 252
let iconWellCornerRadius: CGFloat = 56

let brandColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.16, alpha: 1.0)

func yFromTop(_ topOffset: CGFloat) -> CGFloat { canvasHeight - topOffset }

func topAnchoredOrigin(forTopOffset topOffset: CGFloat, elementHeight: CGFloat) -> CGFloat {
    canvasHeight - topOffset - elementHeight
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let logoURL: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    return repositoryRoot
        .appendingPathComponent("Modules/Presentation/Presentation/Resources/faux_logo.png")
}()

let outputURL: URL = {
    if CommandLine.arguments.count > 2 {
        return URL(fileURLWithPath: CommandLine.arguments[2])
    }
    return repositoryRoot.appendingPathComponent("Assets/dmg/background.png")
}()

// MARK: - Background

func drawBackground(in context: CGContext) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let topColor = CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1.0)
    let bottomColor = CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: [topColor, bottomColor] as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: canvasHeight),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    let glowCenter = CGPoint(x: canvasWidth / 2, y: yFromTop(logoTopMargin + logoSide / 2))
    let glowColors = [
        brandColor.withAlphaComponent(0.22).cgColor,
        brandColor.withAlphaComponent(0.0).cgColor,
    ]
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: [0.0, 1.0]) {
        context.drawRadialGradient(
            glow,
            startCenter: glowCenter, startRadius: 0,
            endCenter: glowCenter, endRadius: 380,
            options: []
        )
    }

    let vignetteColors = [
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.45),
    ]
    if let vignette = CGGradient(colorsSpace: colorSpace, colors: vignetteColors as CFArray, locations: [0.55, 1.0]) {
        let center = CGPoint(x: canvasWidth / 2, y: canvasHeight / 2)
        context.drawRadialGradient(
            vignette,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: canvasWidth * 0.62,
            options: []
        )
    }
}

// MARK: - Icon wells

func drawIconWell(in context: CGContext, centerX: CGFloat) {
    let rect = CGRect(
        x: centerX - iconWellSide / 2,
        y: yFromTop(iconCenterYFromTop) - iconWellSide / 2,
        width: iconWellSide,
        height: iconWellSide
    )
    let path = CGPath(roundedRect: rect, cornerWidth: iconWellCornerRadius, cornerHeight: iconWellCornerRadius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()
}

// MARK: - Arrow

func drawArrow(in context: CGContext) {
    let centerX = (leftIconCenterX + rightIconCenterX) / 2
    let centerY = yFromTop(iconCenterYFromTop)
    let shaftHalfLength: CGFloat = 58
    let headLength: CGFloat = 30
    let headHalfHeight: CGFloat = 26
    let color = brandColor.withAlphaComponent(0.92).cgColor

    context.saveGState()
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineWidth(11)
    context.setLineCap(.round)

    context.move(to: CGPoint(x: centerX - shaftHalfLength, y: centerY))
    context.addLine(to: CGPoint(x: centerX + shaftHalfLength - headLength + 4, y: centerY))
    context.strokePath()

    let tipX = centerX + shaftHalfLength
    context.move(to: CGPoint(x: tipX, y: centerY))
    context.addLine(to: CGPoint(x: tipX - headLength, y: centerY + headHalfHeight))
    context.addLine(to: CGPoint(x: tipX - headLength, y: centerY - headHalfHeight))
    context.closePath()
    context.fillPath()
    context.restoreGState()
}

// MARK: - Logo

func drawLogo(in context: CGContext) {
    guard let logoImage = NSImage(contentsOf: logoURL),
          let logoCGImage = logoImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write(Data("warning: logo not found at \(logoURL.path)\n".utf8))
        return
    }
    let logoRect = CGRect(
        x: canvasWidth / 2 - logoSide / 2,
        y: topAnchoredOrigin(forTopOffset: logoTopMargin, elementHeight: logoSide),
        width: logoSide,
        height: logoSide
    )
    context.saveGState()
    context.setShadow(offset: .zero, blur: 24, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
    context.draw(logoCGImage, in: logoRect)
    context.restoreGState()
}

// MARK: - Text

func drawCenteredText(_ string: String, font: NSFont, color: NSColor, topOffset: CGFloat) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
    let size = attributed.size()
    attributed.draw(at: CGPoint(
        x: canvasWidth / 2 - size.width / 2,
        y: topAnchoredOrigin(forTopOffset: topOffset, elementHeight: size.height)
    ))
    return size.height
}

func drawText(in context: CGContext) {
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let titleTopOffset = logoTopMargin + logoSide + titleToLogoGap
    let titleHeight = drawCenteredText(
        "FauxCam",
        font: .systemFont(ofSize: 56, weight: .bold),
        color: .white,
        topOffset: titleTopOffset
    )

    _ = drawCenteredText(
        "Fake camera for the iOS Simulator",
        font: .systemFont(ofSize: 24, weight: .regular),
        color: NSColor(white: 1.0, alpha: 0.52),
        topOffset: titleTopOffset + titleHeight + taglineToTitleGap
    )

    let footerHeight = NSFont.systemFont(ofSize: 19, weight: .regular).pointSize + 6
    _ = drawCenteredText(
        "Drag FauxCam onto Applications  ·  requires macOS 26",
        font: .systemFont(ofSize: 19, weight: .regular),
        color: NSColor(white: 1.0, alpha: 0.30),
        topOffset: canvasHeight - 40 - footerHeight
    )

    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Render

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: backgroundPixelWidth,
    pixelsHigh: backgroundPixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
    FileHandle.standardError.write(Data("error: unable to create bitmap context\n".utf8))
    exit(1)
}

drawBackground(in: context)
drawIconWell(in: context, centerX: leftIconCenterX)
drawIconWell(in: context, centerX: rightIconCenterX)
drawArrow(in: context)
drawLogo(in: context)
drawText(in: context)

try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

bitmap.size = windowPointSize

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: unable to encode PNG\n".utf8))
    exit(1)
}

do {
    try pngData.write(to: outputURL)
    print("wrote \(outputURL.path) (\(backgroundPixelWidth)x\(backgroundPixelHeight))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
