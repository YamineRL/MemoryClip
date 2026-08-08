import AppKit
import CoreImage

/// Generates QR-code images for link clips (Phase-2 "Link QR code generation").
enum QRService {
    /// QR code for the given string, rendered crisp at `size` points
    /// (nearest-neighbor upscale of the CIQRCodeGenerator output).
    /// Returns `nil` for an empty string.
    static func image(for string: String, size: CGFloat = 240) -> NSImage? {
        guard !string.isEmpty else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        // The generator's output is a tiny native-size QR symbol. Upscale it
        // to `size` points with an affine transform, then rasterise 1:1.
        let scale = size / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = CIContext().createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
    }
}
