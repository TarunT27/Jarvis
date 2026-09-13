import AppKit
import CoreText
import SwiftUI

/// Keep the existing typography call sites, using the native system face for Quiet Workspace.
enum JarvisTypography {
    enum Face:String {
        case extraLight = "Chillax-Extralight"
        case light = "Chillax-Light"
        case regular = "Chillax-Regular"
        case medium = "Chillax-Medium"
        case semibold = "Chillax-Semibold"
        case bold = "Chillax-Bold"
    }

    private static func weight(_ face: Face) -> Font.Weight {
        switch face {
        case .extraLight: .ultraLight
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
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

    static func font(_ face: Face = .regular, style: Font.TextStyle) -> Font {
        return Font.system(style, design: .default).weight(weight(face))
    }
}
