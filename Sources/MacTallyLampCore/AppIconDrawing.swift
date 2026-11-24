import CoreGraphics
import Foundation

/// Draws the app icon's artwork: white marks on a clear background, one image per layer of the
/// Icon Composer file. `scripts/render-icon.sh` turns them into `Resources/AppIcon.icon`, and
/// the system adds the red background, the rounded shape, and the glass.
///
/// The red is a broadcast tally light's: lit while its camera is live. There are two designs,
/// for choosing. `shipped` is the one in the app.
public enum AppIconDrawing {
    /// The side of the square canvas, in pixels. Icon Composer's canvas for a Mac icon.
    public static let canvas: CGFloat = 1024

    /// The design in `Resources/AppIcon.icon`. To ship another, change this one line and run
    /// `scripts/render-icon.sh`.
    public static let shipped = Design.lampOverScreen

    public enum Design: Int, CaseIterable, Sendable {
        /// A display with a lamp above it, as a tally light sits on a camera.
        case lampOverScreen = 1
        /// A lamp giving off light: a disc with two arcs on each side.
        case glowingLamp = 2

        public var title: String {
            switch self {
            case .lampOverScreen: "Lamp over a screen"
            case .glowingLamp: "Glowing lamp"
            }
        }

        /// The background gradient, top color first, as sRGB components: a tally light's red.
        public var gradient: (top: [CGFloat], bottom: [CGFloat]) {
            ([0.94, 0.25, 0.20], [0.66, 0.06, 0.05])
        }

        /// The layers, front first, as Icon Composer lists them.
        public var layers: [Layer] {
            switch self {
            case .lampOverScreen:
                [Layer(name: "lamp", draw: AppIconDrawing.lamp),
                 Layer(name: "screen", draw: AppIconDrawing.screen)]
            case .glowingLamp:
                [Layer(name: "glow", draw: AppIconDrawing.glow),
                 Layer(name: "disc", draw: AppIconDrawing.disc)]
            }
        }
    }

    /// One layer of the icon: a name for its image, and a routine that draws it on a clear,
    /// canvas-sized context with y pointing up.
    public struct Layer: Sendable {
        public let name: String
        public let draw: @Sendable (CGContext) -> Void
    }

    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let center = CGPoint(x: 512, y: 512)

    // MARK: Lamp over a screen

    /// The display's outline, centered a little low to leave room for the lamp.
    static let display = CGRect(x: 236, y: 300, width: 552, height: 352)

    @Sendable static func screen(_ context: CGContext) {
        context.setStrokeColor(white)
        context.setLineWidth(52)
        context.addPath(CGPath(roundedRect: display, cornerWidth: 56, cornerHeight: 56, transform: nil))
        context.strokePath()
        // The stand: a neck and a foot.
        context.setFillColor(white)
        context.fill(CGRect(x: 482, y: 236, width: 60, height: 64))
        context.addPath(CGPath(
            roundedRect: CGRect(x: 372, y: 196, width: 280, height: 48), cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.fillPath()
    }

    @Sendable static func lamp(_ context: CGContext) {
        context.setFillColor(white)
        let radius: CGFloat = 70
        context.fillEllipse(in: CGRect(x: center.x - radius, y: 760 - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Glowing lamp

    @Sendable static func disc(_ context: CGContext) {
        context.setFillColor(white)
        let radius: CGFloat = 150
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    @Sendable static func glow(_ context: CGContext) {
        context.setStrokeColor(white)
        context.setLineWidth(44)
        context.setLineCap(.round)
        let spread: CGFloat = .pi / 5
        for radius in [234, 316] as [CGFloat] {
            for side in [0, CGFloat.pi] {
                context.addArc(center: center, radius: radius, startAngle: side - spread, endAngle: side + spread, clockwise: false)
                context.strokePath()
            }
        }
    }

    // MARK: Output

    /// Draws one layer on a clear canvas.
    public static func image(of layer: Layer) -> CGImage? {
        let size = Int(canvas)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        layer.draw(context)
        return context.makeImage()
    }

    /// The Icon Composer file's `icon.json` for a design, naming each layer's image as
    /// `<name>.png`.
    public static func iconJSON(for design: Design) -> String {
        func color(_ c: [CGFloat]) -> String {
            "srgb:" + (c + [1]).map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        }
        let layers = design.layers.map {
            """
                    {
                      "image-name" : "\($0.name).png",
                      "name" : "\($0.name)"
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "fill" : {
            "linear-gradient" : [
              "\(color(design.gradient.top))",
              "\(color(design.gradient.bottom))"
            ]
          },
          "groups" : [
            {
              "layers" : [
        \(layers)
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
          ],
          "supported-platforms" : {
            "squares" : [
              "macOS"
            ]
          }
        }

        """
    }
}
