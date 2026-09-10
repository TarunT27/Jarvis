import AppKit
import CoreText
import SwiftUI

enum JarvisTypography {
    enum Face:String {
        case extraLight = "Chillax-Extralight"
        case light = "Chillax-Light"
        case regular = "Chillax-Regular"
        case medium = "Chillax-Medium"
        case semibold = "Chillax-Semibold"
        case bold = "Chillax-Bold"
    }

    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true

        for face in [Face.extraLight, .light, .regular, .medium, .semibold, .bold] {
            guard let url = Bundle.main.url(forResource: face.rawValue, withExtension: "otf", subdirectory: "Fonts") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ face:Face = .regular, size:CGFloat, relativeTo style:Font.TextStyle = .body) -> Font {
        Font.custom(face.rawValue, size: size, relativeTo: style)
    }

    static func font(_ face: Face = .regular, style: Font.TextStyle) -> Font {
        let size: CGFloat = switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 15
        case .subheadline: 13
        case .body: 15
        case .callout: 14
        case .caption: 12
        case .caption2: 11
        case .footnote: 12
        @unknown default: 15
        }
        return font(face, size: size, relativeTo: style)
    }
}
