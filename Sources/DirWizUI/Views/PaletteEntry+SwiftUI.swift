import DirWizCore
import SwiftUI

extension PaletteEntry {
    var swiftUIColor: Color {
        Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))
    }
}

extension ExtensionPalette {
    func swiftUIColor(forHash hash: UInt32) -> Color {
        let c = color(forHash: hash)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
