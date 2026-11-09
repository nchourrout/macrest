// Renders the 1024 px app icon to the path given as the only argument.
// Run by build-app.sh: `swift render-icon.swift out.png`.
//
// The menu bar glyph, light on a Catppuccin Mocha squircle,
// so the Dock and Finder show the same thing as the menu bar.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = rect.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.28, blue: 0.35, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.18, alpha: 1))!
        .draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.80, green: 0.84, blue: 0.96, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
