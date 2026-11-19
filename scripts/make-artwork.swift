import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1
    )
}

func stroke(_ points: [CGPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func render(_ url: URL, width: Int, height: Int, scale: Int, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, shade: UInt32) {
    (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(shade)
    ])
}

func icon(at origin: CGPoint, size: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let tile = NSBezierPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884), xRadius: 204, yRadius: 204)
    NSGradient(starting: color(0x354F9F), ending: color(0x121C3D))!.draw(in: tile, angle: -70)
    color(0x97ADFF).withAlphaComponent(0.4).setStroke()
    tile.lineWidth = 8
    tile.stroke()

    let brackets: [[CGPoint]] = [
        [.init(x: 305, y: 617), .init(x: 305, y: 719), .init(x: 407, y: 719)],
        [.init(x: 617, y: 719), .init(x: 719, y: 719), .init(x: 719, y: 617)],
        [.init(x: 719, y: 407), .init(x: 719, y: 305), .init(x: 617, y: 305)],
        [.init(x: 407, y: 305), .init(x: 305, y: 305), .init(x: 305, y: 407)]
    ]
    for bracket in brackets { stroke(bracket, width: 38, color: color(0xE2E9FF)) }
    let ring = NSBezierPath(ovalIn: CGRect(x: 416, y: 416, width: 192, height: 192))
    ring.lineWidth = 20
    color(0x9CACFF).setStroke()
    ring.stroke()
    color(0xE2E9FF).setFill()
    NSBezierPath(ovalIn: CGRect(x: 480, y: 480, width: 64, height: 64)).fill()
    ctx.restoreGState()
}

func background(width: CGFloat, height: CGFloat) {
    NSGradient(starting: color(0x1F346D), ending: color(0x10182F))!
        .draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: -35)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fatalError("Uso: swift scripts/make-artwork.swift RUTA_AL_ICONSET") }
let iconset = URL(fileURLWithPath: arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), width: size, height: size, scale: scale) {
            icon(at: .zero, size: CGFloat(size))
        }
    }
}

let assets = URL(fileURLWithPath: "scripts/assets", isDirectory: true)
for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    try render(assets.appendingPathComponent("installer-background\(suffix).png"), width: 640, height: 450, scale: scale) {
        background(width: 640, height: 450)
        text("FocusApp", x: 39, y: 373, size: 36, weight: .bold, shade: 0xF3F5FF)
        text("Arrastra FocusApp a Aplicaciones", x: 41, y: 339, size: 16, weight: .medium, shade: 0xBDC9EF)

        text("macOS 14+  ·  Apple Silicon e Intel", x: 411, y: 390, size: 11, weight: .medium, shade: 0xB0BEE7)
        color(0xDCE7FF).setFill()
        for center in [155, 485] {
            NSBezierPath(roundedRect: CGRect(x: center - 75, y: 182, width: 150, height: 31),
                         xRadius: 12, yRadius: 12).fill()
        }

        stroke([CGPoint(x: 280, y: 266), CGPoint(x: 355, y: 266)], width: 2, color: color(0x9CACFF))
        stroke([CGPoint(x: 341, y: 280), CGPoint(x: 355, y: 266), CGPoint(x: 341, y: 252)],
               width: 2, color: color(0x9CACFF))
        stroke([CGPoint(x: 41, y: 158), CGPoint(x: 599, y: 158)], width: 1, color: color(0x415481))

        text("ABRIR FOCUSAPP", x: 41, y: 123, size: 12, weight: .bold, shade: 0xB2BFFF)
        text("Abre FocusApp desde Aplicaciones y usa el visor de la barra de menús.",
             x: 41, y: 97, size: 13, weight: .regular, shade: 0xE2E9FF)
        text("Si macOS bloquea el primer inicio, consulta las instrucciones del repositorio.",
             x: 41, y: 73, size: 13, weight: .regular, shade: 0xE2E9FF)
    }
}

try render(URL(fileURLWithPath: "docs/assets/focusapp-banner.png"), width: 900, height: 248, scale: 1) {
    background(width: 900, height: 248)
    icon(at: CGPoint(x: 46, y: 56), size: 136)
    text("FocusApp", x: 206, y: 112, size: 55, weight: .bold, shade: 0xF3F5FF)
    text("Desenfoque de ventanas para macOS", x: 208, y: 71, size: 21, weight: .regular, shade: 0xB8C5ED)
}
