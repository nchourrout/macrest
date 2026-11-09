import AppKit
import MacRestCore
import SwiftUI

/// `MacRest --render <dir>` draws the menu bar panel to PNGs, light and dark,
/// from live Backrest readings. A menu bar panel only exists while it is
/// clicked open, so this is how it gets checked without a hand on the mouse.
@MainActor
enum Render {
    static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await AppModel.shared.reload()
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = MenuPanel(model: AppModel.shared)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appending(path: "panel-\(name).png"))
        }
    }
}
