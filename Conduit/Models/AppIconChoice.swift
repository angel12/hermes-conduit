import Foundation

enum AppIconChoice: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: Self { self }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var alternateIconName: String? {
        self == .light ? "Light" : nil
    }

    var previewAssetName: String {
        self == .light ? "AppIconLightPreview" : "AppIconPreview"
    }
}
