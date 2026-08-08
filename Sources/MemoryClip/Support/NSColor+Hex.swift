import AppKit

extension NSColor {
    /// Parse a hex color string ("#RRGGBB", "RRGGBB", optional alpha).
    /// Returns nil for anything unparseable.
    convenience init?(hexString: String) {
        var hex = hexString.filter { !$0.isWhitespace }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16)
        else { return nil }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hex.count == 6 {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        } else {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
