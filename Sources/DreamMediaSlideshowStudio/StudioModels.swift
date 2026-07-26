import AppKit
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ImportedFontFace: Hashable {
    let familyName: String
    let postScriptName: String
    let weight: Int
    let fileURL: URL
    let format: String
}

enum MacFontCatalog {
    private static let bundledFamilies = [
        "Pretendard Variable"
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var importedFacesCache: [String: [ImportedFontFace]]?
    nonisolated(unsafe) private static var availableFamiliesCache: [String]?
    nonisolated(unsafe) private static var availableFamilySetCache: Set<String>?

    static func availableFamilies() -> [String] {
        lock.lock()
        if let cached = availableFamiliesCache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let importedFamilies = Array(importedFontFacesMap().keys)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let families = Array(NSOrderedSet(array: bundledFamilies + importedFamilies)) as? [String] ?? (bundledFamilies + importedFamilies)

        lock.lock()
        availableFamiliesCache = families
        availableFamilySetCache = Set(families)
        lock.unlock()
        return families
    }

    static func containsFamily(_ family: String) -> Bool {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        lock.lock()
        if let cached = availableFamilySetCache {
            lock.unlock()
            return cached.contains(trimmed)
        }
        lock.unlock()

        _ = availableFamilies()

        lock.lock()
        let result = availableFamilySetCache?.contains(trimmed) ?? false
        lock.unlock()
        return result
    }

    static func isBundledWebFont(_ family: String) -> Bool {
        bundledFamilies.contains(family)
    }

    static func importedFontFaces(for family: String) -> [ImportedFontFace] {
        importedFontFacesMap()[family] ?? []
    }

    static func importedFontsDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("PhotoslideStudio", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    static func importFontFiles(from urls: [URL]) throws -> [String] {
        let destinationFolder = importedFontsDirectoryURL()
        var importedFamilies = Set<String>()

        for sourceURL in urls {
            let ext = sourceURL.pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }

            let destinationURL = uniqueImportedFontURL(for: sourceURL, in: destinationFolder)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            AppFontRegistrar.registerFont(at: destinationURL)

            for face in descriptors(from: destinationURL) {
                importedFamilies.insert(face.familyName)
            }
        }

        reload()
        return Array(importedFamilies).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func reload() {
        lock.lock()
        importedFacesCache = nil
        availableFamiliesCache = nil
        availableFamilySetCache = nil
        lock.unlock()
    }

    static func cssStack(for family: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "System Font" else {
            return "\"Pretendard Variable\", sans-serif"
        }

        guard bundledFamilies.contains(trimmed) || importedFontFacesMap()[trimmed] != nil else {
            return "\"Pretendard Variable\", sans-serif"
        }

        let preferred = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        let stack = [preferred, "Pretendard Variable"]
        let uniqueStack = Array(NSOrderedSet(array: stack)) as? [String] ?? stack
        let cssStack = uniqueStack.map { "\"\($0)\"" }.joined(separator: ", ")
        return "\(cssStack), sans-serif"
    }

    private static func importedFontFacesMap() -> [String: [ImportedFontFace]] {
        lock.lock()
        if let cached = importedFacesCache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: importedFontsDirectoryURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let faces = urls.flatMap { descriptors(from: $0) }
        let grouped = Dictionary(grouping: faces, by: \.familyName)

        lock.lock()
        importedFacesCache = grouped
        lock.unlock()
        return grouped
    }

    private static func descriptors(from url: URL) -> [ImportedFontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }

        return descriptors.compactMap { descriptor in
            guard let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
                return nil
            }

            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let weight = normalizedCSSWeight(for: traits) ?? 400

            return ImportedFontFace(
                familyName: familyName,
                postScriptName: postScriptName,
                weight: weight,
                fileURL: url,
                format: cssFontFormat(for: url.pathExtension)
            )
        }
    }

    private static func uniqueImportedFontURL(for sourceURL: URL, in folder: URL) -> URL {
        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty("Font")
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanBase = baseName.components(separatedBy: invalidCharacters).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty("Font")

        var candidate = folder.appendingPathComponent(cleanBase).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(cleanBase) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private static func cssFontFormat(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "ttf", "ttc": return "truetype"
        case "otf", "otc": return "opentype"
        default: return "truetype"
        }
    }

    private static func normalizedCSSWeight(for traits: [CFString: Any]?) -> Int? {
        if let rawWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue {
            let clamped = min(max(rawWeight, -1), 1)
            let cssWeight = Int(round((((clamped + 1) / 2) * 8) + 1)) * 100
            return min(max(cssWeight, 100), 900)
        }
        return nil
    }
}

enum OverlayPosition: String, CaseIterable, Codable, Identifiable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case center
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return String(localized: "좌상단")
        case .topCenter: return String(localized: "중앙상단")
        case .topRight: return String(localized: "우상단")
        case .middleLeft: return String(localized: "좌중단")
        case .center: return String(localized: "중앙")
        case .middleRight: return String(localized: "우중단")
        case .bottomLeft: return String(localized: "좌하단")
        case .bottomCenter: return String(localized: "중앙하단")
        case .bottomRight: return String(localized: "우하단")
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:
            return .leading
        case .topCenter, .center, .bottomCenter:
            return .center
        case .topRight, .middleRight, .bottomRight:
            return .trailing
        }
    }

    var stackAlignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .middleLeft: return .leading
        case .center: return .center
        case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}

enum TextBackgroundEffect: String, CaseIterable, Codable, Identifiable {
    case clean = "clean"
    case dropShadow = "drop-shadow"
    case blurBar = "blur-bar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return String(localized: "클린")
        case .dropShadow: return String(localized: "드랍쉐도우")
        case .blurBar: return String(localized: "블러바")
        }
    }
}

enum OverlayFontOption: String, CaseIterable, Codable, Identifiable {
    case systemUI
    case pretendardVariable
    case sourceHanSansKR
    case nanumSquare
    case sCoreDream
    case blackHanSans
    case hahmlet
    case gowunBatang
    case nanumMyeongjo
    case gaegu
    case nanumPenScript
    case nanumBrushScript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemUI: return String(localized: "시스템 폰트")
        case .pretendardVariable: return String(localized: "프리텐다드")
        case .sourceHanSansKR: return String(localized: "본고딕")
        case .nanumSquare: return String(localized: "나눔스퀘어")
        case .sCoreDream: return String(localized: "에스코어 드림")
        case .blackHanSans: return String(localized: "검은고딕")
        case .hahmlet: return String(localized: "함렛")
        case .gowunBatang: return String(localized: "고운바탕")
        case .nanumMyeongjo: return String(localized: "나눔명조")
        case .gaegu: return String(localized: "개구쟁이")
        case .nanumPenScript: return String(localized: "나눔손글씨 펜")
        case .nanumBrushScript: return String(localized: "나눔손글씨 붓")
        }
    }

    var cssFamily: String {
        "\"Pretendard Variable\", sans-serif"
    }

    private var nativeFontFamily: String? {
        "Pretendard Variable"
    }

    var supportedWeights: [Int] {
        [100, 200, 300, 400, 500, 600, 700, 800, 900]
    }

    func weightLabel(for weight: Int) -> String {
        genericWeightLabel(weight)
    }

    func previewFont(size: Double, weight: Int) -> Font {
        Font(appKitFont(size: CGFloat(size), weight: weight))
    }

    private func appKitFont(size: CGFloat, weight: Int) -> NSFont {
        let clampedWeight = min(max(weight, 100), 900)

        let managerWeight = Int(round((Double(clampedWeight - 100) / 800.0) * 13.0)) + 1
        let traits: NSFontTraitMask = clampedWeight >= 700 ? .boldFontMask : []

        if let family = nativeFontFamily,
           let resolved = NSFontManager.shared.font(withFamily: family, traits: traits, weight: managerWeight, size: size) {
            return resolved
        }

        if let family = nativeFontFamily,
           let fallback = NSFont(name: family, size: size) {
            return fallback
        }

        return .systemFont(ofSize: size, weight: nsFontWeight(for: clampedWeight))
    }

    private func nsFontWeight(for weight: Int) -> NSFont.Weight {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }
}

enum ImageMotionEffect: String, CaseIterable, Codable, Identifiable {
    case none = "none"
    case kenBurns = "ken-burns"
    case slowZoomIn = "slow-zoom-in"
    case slowZoomOut = "slow-zoom-out"
    case driftLeft = "drift-left"
    case driftRight = "drift-right"
    case driftUp = "drift-up"
    case driftDown = "drift-down"
    case parallaxFloat = "parallax-float"
    case cinematicPush = "cinematic-push"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "기본 슬라이드")
        case .kenBurns: return String(localized: "캔번스")
        case .slowZoomIn: return String(localized: "슬로우 줌 인")
        case .slowZoomOut: return String(localized: "슬로우 줌 아웃")
        case .driftLeft: return String(localized: "좌측 드리프트")
        case .driftRight: return String(localized: "우측 드리프트")
        case .driftUp: return String(localized: "상단 드리프트")
        case .driftDown: return String(localized: "하단 드리프트")
        case .parallaxFloat: return String(localized: "패럴랙스 플로트")
        case .cinematicPush: return String(localized: "시네마틱 푸시")
        }
    }
}

enum KenBurnsDirection: String, CaseIterable, Codable, Identifiable {
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoomIn: return String(localized: "줌인")
        case .zoomOut: return String(localized: "줌아웃")
        }
    }
}

enum KenBurnsFocusMode: String, CaseIterable, Codable, Identifiable {
    case center = "center"
    case random = "random"
    case subject = "subject"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .center: return String(localized: "정중앙")
        case .random: return String(localized: "랜덤")
        case .subject: return String(localized: "얼굴/피사체")
        }
    }
}

enum TransitionEffect: String, CaseIterable, Codable, Identifiable {
    case none = "none"
    case crossfade = "crossfade"
    case pageLeft = "page-left"
    case pageRight = "page-right"
    case pageUp = "page-up"
    case pageDown = "page-down"
    case slideLeft = "slide-left"
    case slideRight = "slide-right"
    case slideUp = "slide-up"
    case slideDown = "slide-down"
    case zoomDissolve = "zoom-dissolve"
    case cinematicReveal = "cinematic-reveal"
    case splitWipe = "split-wipe"
    case flashFade = "flash-fade"
    case diagonalReveal = "diagonal-reveal"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "없음")
        case .crossfade: return String(localized: "디졸브")
        case .pageLeft: return String(localized: "책장넘기기 좌")
        case .pageRight: return String(localized: "책장넘기기 우")
        case .pageUp: return String(localized: "책장넘기기 상")
        case .pageDown: return String(localized: "책장넘기기 하")
        case .slideLeft: return String(localized: "슬라이드(밀어내기) 좌")
        case .slideRight: return String(localized: "슬라이드(밀어내기) 우")
        case .slideUp: return String(localized: "슬라이드(밀어내기) 상")
        case .slideDown: return String(localized: "슬라이드(밀어내기) 하")
        case .zoomDissolve: return String(localized: "디졸브")
        case .cinematicReveal: return String(localized: "디졸브")
        case .splitWipe: return String(localized: "디졸브")
        case .flashFade: return String(localized: "디졸브")
        case .diagonalReveal: return String(localized: "디졸브")
        }
    }
}

enum PlaybackOrder: String, CaseIterable, Codable, Identifiable {
    case random = "random"
    case fileNameAscending = "filename-asc"
    case captureDateAscending = "capture-date-asc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .random: return String(localized: "랜덤 재생")
        case .fileNameAscending: return String(localized: "순차 재생(파일명순)")
        case .captureDateAscending: return String(localized: "촬영일순")
        }
    }
}

enum MediaFitMode: String, CaseIterable, Codable, Identifiable {
    case fill = "fill"
    case fit = "fit"
    case stretch = "stretch"
    case forced16x9 = "forced-16x9"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return String(localized: "스트레치")
        case .forced16x9: return String(localized: "16:9 강제비율")
        }
    }
}

enum SpecialEffect: String, CaseIterable, Codable, Identifiable {
    case none = "none"
    case floatingParticles = "floating-particles"
    case lightLeaks = "light-leaks"
    case glassOrbs = "glass-orbs"
    case gradientMesh = "gradient-mesh"
    case paperGrain = "paper-grain"
    case prismLines = "prism-lines"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .floatingParticles: return "Floating Particles"
        case .lightLeaks: return "Light Leaks"
        case .glassOrbs: return "Glass Orbs"
        case .gradientMesh: return "Gradient Mesh"
        case .paperGrain: return "Paper Grain"
        case .prismLines: return "Prism Lines"
        }
    }
}

struct TextAppearance: Codable, Hashable {
    var font: OverlayFontOption
    var fontFamilyName: String
    var size: Double
    var colorHex: String
    var weightEnabled: Bool
    var weight: Int
    var italicEnabled: Bool
    var letterSpacingEnabled: Bool
    var letterSpacing: Double
    var lineHeightEnabled: Bool
    var lineHeight: Double
    var shadowEnabled: Bool
    var shadowStrength: Double
    var shadowOpacity: Double
    var shadowDistance: Double
    var shadowBlur: Double
    var shadowFeather: Double

    static func titleDefault() -> TextAppearance {
        TextAppearance(
            font: .pretendardVariable,
            fontFamilyName: "Pretendard Variable",
            size: 50,
            colorHex: "#FFFFFF",
            weightEnabled: true,
            weight: 800,
            italicEnabled: false,
            letterSpacingEnabled: false,
            letterSpacing: -1.5,
            lineHeightEnabled: false,
            lineHeight: 0.92,
            shadowEnabled: true,
            shadowStrength: 0.36,
            shadowOpacity: 0.42,
            shadowDistance: 20,
            shadowBlur: 34,
            shadowFeather: 14
        )
    }

    static func subtitleDefault() -> TextAppearance {
        TextAppearance(
            font: .pretendardVariable,
            fontFamilyName: "Pretendard Variable",
            size: 30,
            colorHex: "#FFFFFF",
            weightEnabled: true,
            weight: 600,
            italicEnabled: false,
            letterSpacingEnabled: false,
            letterSpacing: -0.6,
            lineHeightEnabled: false,
            lineHeight: 1.18,
            shadowEnabled: true,
            shadowStrength: 0.28,
            shadowOpacity: 0.34,
            shadowDistance: 12,
            shadowBlur: 24,
            shadowFeather: 10
        )
    }

    enum CodingKeys: String, CodingKey {
        case font
        case fontFamilyName
        case size
        case colorHex
        case weightEnabled
        case weight
        case italicEnabled
        case letterSpacingEnabled
        case letterSpacing
        case lineHeightEnabled
        case lineHeight
        case shadowEnabled
        case shadowStrength
        case shadowOpacity
        case shadowDistance
        case shadowBlur
        case shadowFeather
    }

    init(
        font: OverlayFontOption,
        fontFamilyName: String,
        size: Double,
        colorHex: String,
        weightEnabled: Bool,
        weight: Int,
        italicEnabled: Bool,
        letterSpacingEnabled: Bool,
        letterSpacing: Double,
        lineHeightEnabled: Bool,
        lineHeight: Double,
        shadowEnabled: Bool,
        shadowStrength: Double,
        shadowOpacity: Double,
        shadowDistance: Double,
        shadowBlur: Double,
        shadowFeather: Double
    ) {
        self.font = font
        self.fontFamilyName = fontFamilyName
        self.size = size
        self.colorHex = colorHex
        self.weightEnabled = weightEnabled
        self.weight = weight
        self.italicEnabled = italicEnabled
        self.letterSpacingEnabled = letterSpacingEnabled
        self.letterSpacing = letterSpacing
        self.lineHeightEnabled = lineHeightEnabled
        self.lineHeight = lineHeight
        self.shadowEnabled = shadowEnabled
        self.shadowStrength = shadowStrength
        self.shadowOpacity = shadowOpacity
        self.shadowDistance = shadowDistance
        self.shadowBlur = shadowBlur
        self.shadowFeather = shadowFeather
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFont = try container.decodeIfPresent(OverlayFontOption.self, forKey: .font) ?? .pretendardVariable
        let decodedFamilyName = try container.decodeIfPresent(String.self, forKey: .fontFamilyName) ?? Self.defaultFamilyName(for: decodedFont)
        let normalizedFamilyName = decodedFamilyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedFamilyName.isEmpty || normalizedFamilyName == "System Font" || !MacFontCatalog.containsFamily(decodedFamilyName) {
            font = .pretendardVariable
            fontFamilyName = "Pretendard Variable"
        } else {
            font = decodedFont
            fontFamilyName = decodedFamilyName
        }
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 32
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        let defaultWeight = font.supportedWeights.last(where: { $0 <= 700 }) ?? font.supportedWeights.last ?? 400
        weightEnabled = try container.decodeIfPresent(Bool.self, forKey: .weightEnabled) ?? true
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? defaultWeight
        italicEnabled = try container.decodeIfPresent(Bool.self, forKey: .italicEnabled) ?? false
        letterSpacingEnabled = try container.decodeIfPresent(Bool.self, forKey: .letterSpacingEnabled) ?? false
        letterSpacing = try container.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0
        lineHeightEnabled = try container.decodeIfPresent(Bool.self, forKey: .lineHeightEnabled) ?? false
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.12
        shadowEnabled = try container.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .shadowStrength) ?? 0.3
        let resolvedShadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity)
        let resolvedShadowDistance = try container.decodeIfPresent(Double.self, forKey: .shadowDistance)
        let resolvedShadowBlur = try container.decodeIfPresent(Double.self, forKey: .shadowBlur)
        let resolvedShadowFeather = try container.decodeIfPresent(Double.self, forKey: .shadowFeather)
        shadowOpacity = resolvedShadowOpacity ?? max(0.16, min(0.62, shadowStrength * 1.2))
        shadowDistance = resolvedShadowDistance ?? max(4, 6 + shadowStrength * 36)
        shadowBlur = resolvedShadowBlur ?? max(8, 10 + shadowStrength * 54)
        shadowFeather = resolvedShadowFeather ?? max(0, shadowStrength * 18)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(font, forKey: .font)
        try container.encode(fontFamilyName, forKey: .fontFamilyName)
        try container.encode(size, forKey: .size)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encode(weightEnabled, forKey: .weightEnabled)
        try container.encode(weight, forKey: .weight)
        try container.encode(italicEnabled, forKey: .italicEnabled)
        try container.encode(letterSpacingEnabled, forKey: .letterSpacingEnabled)
        try container.encode(letterSpacing, forKey: .letterSpacing)
        try container.encode(lineHeightEnabled, forKey: .lineHeightEnabled)
        try container.encode(lineHeight, forKey: .lineHeight)
        try container.encode(shadowEnabled, forKey: .shadowEnabled)
        try container.encode(shadowStrength, forKey: .shadowStrength)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowDistance, forKey: .shadowDistance)
        try container.encode(shadowBlur, forKey: .shadowBlur)
        try container.encode(shadowFeather, forKey: .shadowFeather)
    }

    var resolvedFontFamilyName: String {
        if fontFamilyName == "System Font" || fontFamilyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Pretendard Variable"
        }
        return MacFontCatalog.containsFamily(fontFamilyName) ? fontFamilyName : "Pretendard Variable"
    }

    var cssFontFamily: String {
        MacFontCatalog.cssStack(for: resolvedFontFamilyName)
    }

    func previewFont(size: Double) -> Font {
        let clampedWeight = min(max(weight, 100), 900)
        let managerWeight = Int(round((Double(clampedWeight - 100) / 800.0) * 13.0)) + 1
        let traits: NSFontTraitMask = clampedWeight >= 700 ? .boldFontMask : []
        if let resolved = NSFontManager.shared.font(withFamily: resolvedFontFamilyName, traits: traits, weight: managerWeight, size: CGFloat(size)) {
            return Font(resolved)
        }
        if let fallback = NSFont(name: resolvedFontFamilyName, size: CGFloat(size)) {
            return Font(fallback)
        }
        return font.previewFont(size: size, weight: weight)
    }

    var supportedWeights: [Int] {
        [100, 200, 300, 400, 500, 600, 700, 800, 900]
    }

    var resolvedWeight: Int {
        weightEnabled ? weight : 400
    }

    var resolvedLetterSpacing: Double {
        // "자간 조정" 체크가 꺼져 있으면 기본값으로 되돌린다.
        letterSpacingEnabled ? letterSpacing : 0
    }

    var resolvedLineHeight: Double {
        // "줄간 조정" 체크가 꺼져 있으면 기본값으로 되돌린다.
        lineHeightEnabled ? lineHeight : 1.12
    }

    func weightLabel(for value: Int) -> String {
        genericWeightLabel(value)
    }

    private static func defaultFamilyName(for font: OverlayFontOption) -> String {
        "Pretendard Variable"
    }

    private func nsFontWeight(for weight: Int) -> NSFont.Weight {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }
}

struct LogoOverlay: Codable, Hashable {
    var enabled: Bool
    var filePath: String
    var position: OverlayPosition
    var size: Double
    var offsetX: Double
    var offsetY: Double
    var opacity: Double

    static func `default`() -> LogoOverlay {
        LogoOverlay(
            enabled: false,
            filePath: "",
            position: .topRight,
            size: 160,
            offsetX: 0,
            offsetY: 0,
            opacity: 1
        )
    }

    var fileURL: URL? {
        guard !filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case filePath
        case position
        case size
        case offsetX
        case offsetY
        case opacity
    }

    init(
        enabled: Bool,
        filePath: String,
        position: OverlayPosition,
        size: Double,
        offsetX: Double,
        offsetY: Double,
        opacity: Double
    ) {
        self.enabled = enabled
        self.filePath = filePath
        self.position = position
        self.size = size
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        position = try container.decodeIfPresent(OverlayPosition.self, forKey: .position) ?? .topRight
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 160
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

enum BackgroundAudioSourceKind: String, CaseIterable, Codable, Identifiable {
    case none = "none"
    case localFile = "local-file"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "없음")
        case .localFile: return String(localized: "로컬 mp3/mp4")
        }
    }

    // 더 이상 지원하지 않는 소스(예: 과거의 "youtube")로 저장된 프로젝트도
    // 로드되도록, 알 수 없는 값은 .none으로 폴백한다.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BackgroundAudioSourceKind(rawValue: raw) ?? .none
    }
}

struct BackgroundAudio: Codable, Hashable {
    var sourceKind: BackgroundAudioSourceKind
    var filePath: String
    var volume: Double

    static func `default`() -> BackgroundAudio {
        BackgroundAudio(
            sourceKind: .none,
            filePath: "",
            volume: 0.72
        )
    }

    var fileURL: URL? {
        guard !filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: filePath)
    }
}

enum EventPlaybackMode: String, CaseIterable, Codable, Identifiable {
    case sequential = "sequential"
    case random = "random"
    case playlist = "playlist"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return String(localized: "순차 재생")
        case .random: return String(localized: "랜덤 재생")
        case .playlist: return String(localized: "플레이리스트")
        }
    }
}

struct SlideshowEvent: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: ProjectKind
    var name: String
    var subtitle: String
    var displayTitle: String
    var displaySubtitle: String
    var textOverlayEnabled: Bool
    var textBackgroundEffect: TextBackgroundEffect
    var overlayPosition: OverlayPosition
    var overlayOffsetX: Double
    var overlayOffsetY: Double
    var titleAppearance: TextAppearance
    var subtitleAppearance: TextAppearance
    var logoOverlay: LogoOverlay
    var backgroundAudio: BackgroundAudio
    var mediaSourceKind: MediaSourceKind
    var mediaFolderPath: String
    var cloudSourceURL: String
    var playbackOrder: PlaybackOrder
    var mediaFitMode: MediaFitMode
    var secondsPerPhoto: Double
    var transitionDuration: Double
    var imageMotionEffect: ImageMotionEffect
    var kenBurnsDirection: KenBurnsDirection
    var kenBurnsScalePercent: Double
    var kenBurnsFocusMode: KenBurnsFocusMode
    var transitionEffect: TransitionEffect
    var specialEffect: SpecialEffect
    var createdAt: Date
    var updatedAt: Date

    static func makeDefault(index: Int, kind: ProjectKind) -> SlideshowEvent {
        let now = Date()
        let eventName: String = switch kind {
        case .photo: String(localized: "사진 이벤트 \(index)")
        case .video: String(localized: "비디오 이벤트 \(index)")
        }

        return SlideshowEvent(
            id: UUID(),
            kind: kind,
            name: eventName,
            subtitle: "",
            displayTitle: eventName,
            displaySubtitle: "",
            textOverlayEnabled: true,
            textBackgroundEffect: .blurBar,
            overlayPosition: .bottomLeft,
            overlayOffsetX: 0,
            overlayOffsetY: 0,
            titleAppearance: .titleDefault(),
            subtitleAppearance: .subtitleDefault(),
            logoOverlay: .default(),
            backgroundAudio: .default(),
            mediaSourceKind: .localFolder,
            mediaFolderPath: "",
            cloudSourceURL: "",
            playbackOrder: .random,
            mediaFitMode: .fill,
            secondsPerPhoto: 8,
            transitionDuration: 1.4,
            imageMotionEffect: .kenBurns,
            kenBurnsDirection: .zoomIn,
            kenBurnsScalePercent: 3,
            kenBurnsFocusMode: .center,
            transitionEffect: .crossfade,
            specialEffect: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    var mediaFolderURL: URL? {
        guard mediaSourceKind == .localFolder, !mediaFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: mediaFolderPath)
    }

    mutating func touch() {
        updatedAt = Date()
    }

    func duplicated(defaultName: String) -> SlideshowEvent {
        let now = Date()
        return SlideshowEvent(
            id: UUID(),
            kind: kind,
            name: defaultName,
            subtitle: subtitle,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle,
            textOverlayEnabled: textOverlayEnabled,
            textBackgroundEffect: textBackgroundEffect,
            overlayPosition: overlayPosition,
            overlayOffsetX: overlayOffsetX,
            overlayOffsetY: overlayOffsetY,
            titleAppearance: titleAppearance,
            subtitleAppearance: subtitleAppearance,
            logoOverlay: logoOverlay,
            backgroundAudio: backgroundAudio,
            mediaSourceKind: mediaSourceKind,
            mediaFolderPath: mediaFolderPath,
            cloudSourceURL: cloudSourceURL,
            playbackOrder: playbackOrder,
            mediaFitMode: mediaFitMode,
            secondsPerPhoto: secondsPerPhoto,
            transitionDuration: transitionDuration,
            imageMotionEffect: imageMotionEffect,
            kenBurnsDirection: kenBurnsDirection,
            kenBurnsScalePercent: kenBurnsScalePercent,
            kenBurnsFocusMode: kenBurnsFocusMode,
            transitionEffect: transitionEffect,
            specialEffect: specialEffect,
            createdAt: now,
            updatedAt: now
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case subtitle
        case displayTitle
        case displaySubtitle
        case textOverlayEnabled
        case textBackgroundEffect
        case overlayPosition
        case overlayOffsetX
        case overlayOffsetY
        case titleAppearance
        case subtitleAppearance
        case logoOverlay
        case backgroundAudio
        case mediaSourceKind
        case mediaFolderPath
        case cloudSourceURL
        case legacyPhotoFolderPath = "photoFolderPath"
        case playbackOrder
        case mediaFitMode
        case secondsPerPhoto
        case transitionDuration
        case imageMotionEffect
        case kenBurnsDirection
        case kenBurnsScalePercent
        case kenBurnsFocusMode
        case transitionEffect
        case specialEffect
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        kind: ProjectKind,
        name: String,
        subtitle: String,
        displayTitle: String,
        displaySubtitle: String,
        textOverlayEnabled: Bool,
        textBackgroundEffect: TextBackgroundEffect,
        overlayPosition: OverlayPosition,
        overlayOffsetX: Double,
        overlayOffsetY: Double,
        titleAppearance: TextAppearance,
        subtitleAppearance: TextAppearance,
        logoOverlay: LogoOverlay,
        backgroundAudio: BackgroundAudio,
        mediaSourceKind: MediaSourceKind,
        mediaFolderPath: String,
        cloudSourceURL: String,
        playbackOrder: PlaybackOrder,
        mediaFitMode: MediaFitMode,
        secondsPerPhoto: Double,
        transitionDuration: Double,
        imageMotionEffect: ImageMotionEffect,
        kenBurnsDirection: KenBurnsDirection,
        kenBurnsScalePercent: Double,
        kenBurnsFocusMode: KenBurnsFocusMode,
        transitionEffect: TransitionEffect,
        specialEffect: SpecialEffect,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.displayTitle = displayTitle
        self.displaySubtitle = displaySubtitle
        self.textOverlayEnabled = textOverlayEnabled
        self.textBackgroundEffect = textBackgroundEffect
        self.overlayPosition = overlayPosition
        self.overlayOffsetX = overlayOffsetX
        self.overlayOffsetY = overlayOffsetY
        self.titleAppearance = titleAppearance
        self.subtitleAppearance = subtitleAppearance
        self.logoOverlay = logoOverlay
        self.backgroundAudio = backgroundAudio
        self.mediaSourceKind = mediaSourceKind
        self.mediaFolderPath = mediaFolderPath
        self.cloudSourceURL = cloudSourceURL
        self.playbackOrder = playbackOrder
        self.mediaFitMode = mediaFitMode
        self.secondsPerPhoto = secondsPerPhoto
        self.transitionDuration = transitionDuration
        self.imageMotionEffect = imageMotionEffect
        self.kenBurnsDirection = kenBurnsDirection
        self.kenBurnsScalePercent = kenBurnsScalePercent
        self.kenBurnsFocusMode = kenBurnsFocusMode
        self.transitionEffect = transitionEffect
        self.specialEffect = specialEffect
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .photo
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "\(kind.shortTitle) 이벤트")
        let decodedSubtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        let decodedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        let decodedDisplaySubtitle = try container.decodeIfPresent(String.self, forKey: .displaySubtitle)
        name = Self.preferredCaption(primary: decodedDisplayTitle, fallback: decodedName, defaultValue: String(localized: "\(kind.shortTitle) 이벤트"))
        subtitle = Self.preferredCaption(primary: decodedDisplaySubtitle, fallback: decodedSubtitle, defaultValue: "")
        displayTitle = name
        displaySubtitle = subtitle
        textOverlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .textOverlayEnabled) ?? true
        textBackgroundEffect = try container.decodeIfPresent(TextBackgroundEffect.self, forKey: .textBackgroundEffect) ?? .blurBar
        overlayPosition = try container.decodeIfPresent(OverlayPosition.self, forKey: .overlayPosition) ?? .bottomLeft
        overlayOffsetX = try container.decodeIfPresent(Double.self, forKey: .overlayOffsetX) ?? 0
        overlayOffsetY = try container.decodeIfPresent(Double.self, forKey: .overlayOffsetY) ?? 0
        titleAppearance = try container.decodeIfPresent(TextAppearance.self, forKey: .titleAppearance) ?? .titleDefault()
        subtitleAppearance = try container.decodeIfPresent(TextAppearance.self, forKey: .subtitleAppearance) ?? .subtitleDefault()
        logoOverlay = try container.decodeIfPresent(LogoOverlay.self, forKey: .logoOverlay) ?? .default()
        backgroundAudio = try container.decodeIfPresent(BackgroundAudio.self, forKey: .backgroundAudio) ?? .default()
        mediaSourceKind = try container.decodeIfPresent(MediaSourceKind.self, forKey: .mediaSourceKind) ?? .localFolder
        let decodedMediaFolderPath = try container.decodeIfPresent(String.self, forKey: .mediaFolderPath)
        let decodedLegacyPhotoFolderPath = try container.decodeIfPresent(String.self, forKey: .legacyPhotoFolderPath)
        mediaFolderPath = decodedMediaFolderPath ?? decodedLegacyPhotoFolderPath ?? ""
        cloudSourceURL = try container.decodeIfPresent(String.self, forKey: .cloudSourceURL) ?? ""
        playbackOrder = try container.decodeIfPresent(PlaybackOrder.self, forKey: .playbackOrder) ?? .random
        mediaFitMode = try container.decodeIfPresent(MediaFitMode.self, forKey: .mediaFitMode) ?? .fill
        secondsPerPhoto = try container.decodeIfPresent(Double.self, forKey: .secondsPerPhoto) ?? 8
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 2.6
        imageMotionEffect = try container.decodeIfPresent(ImageMotionEffect.self, forKey: .imageMotionEffect) ?? .kenBurns
        kenBurnsDirection = try container.decodeIfPresent(KenBurnsDirection.self, forKey: .kenBurnsDirection) ?? .zoomIn
        kenBurnsScalePercent = try container.decodeIfPresent(Double.self, forKey: .kenBurnsScalePercent) ?? 3
        kenBurnsFocusMode = try container.decodeIfPresent(KenBurnsFocusMode.self, forKey: .kenBurnsFocusMode) ?? .center
        transitionEffect = try container.decodeIfPresent(TransitionEffect.self, forKey: .transitionEffect) ?? .crossfade
        specialEffect = try container.decodeIfPresent(SpecialEffect.self, forKey: .specialEffect) ?? .none
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(name, forKey: .displayTitle)
        try container.encode(subtitle, forKey: .displaySubtitle)
        try container.encode(textOverlayEnabled, forKey: .textOverlayEnabled)
        try container.encode(textBackgroundEffect, forKey: .textBackgroundEffect)
        try container.encode(overlayPosition, forKey: .overlayPosition)
        try container.encode(overlayOffsetX, forKey: .overlayOffsetX)
        try container.encode(overlayOffsetY, forKey: .overlayOffsetY)
        try container.encode(titleAppearance, forKey: .titleAppearance)
        try container.encode(subtitleAppearance, forKey: .subtitleAppearance)
        try container.encode(logoOverlay, forKey: .logoOverlay)
        try container.encode(backgroundAudio, forKey: .backgroundAudio)
        try container.encode(mediaSourceKind, forKey: .mediaSourceKind)
        try container.encode(mediaFolderPath, forKey: .mediaFolderPath)
        try container.encode(cloudSourceURL, forKey: .cloudSourceURL)
        try container.encode(playbackOrder, forKey: .playbackOrder)
        try container.encode(mediaFitMode, forKey: .mediaFitMode)
        try container.encode(secondsPerPhoto, forKey: .secondsPerPhoto)
        try container.encode(transitionDuration, forKey: .transitionDuration)
        try container.encode(imageMotionEffect, forKey: .imageMotionEffect)
        try container.encode(kenBurnsDirection, forKey: .kenBurnsDirection)
        try container.encode(kenBurnsScalePercent, forKey: .kenBurnsScalePercent)
        try container.encode(kenBurnsFocusMode, forKey: .kenBurnsFocusMode)
        try container.encode(transitionEffect, forKey: .transitionEffect)
        try container.encode(specialEffect, forKey: .specialEffect)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func preferredCaption(primary: String?, fallback: String, defaultValue: String) -> String {
        let primaryText = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primaryText.isEmpty {
            return primaryText
        }

        let fallbackText = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackText.isEmpty ? defaultValue : fallbackText
    }
}

struct SlideshowProject: Identifiable, Codable, Hashable {
    let id: UUID
    var projectNumber: Int
    var name: String
    var subtitle: String
    var eventPlaybackMode: EventPlaybackMode
    var events: [SlideshowEvent]
    var createdAt: Date
    var updatedAt: Date

    var slug: String {
        Self.slug(for: projectNumber)
    }

    static func makeDefault(index: Int, kind: ProjectKind) -> SlideshowProject {
        let now = Date()
        let name = "\(kind.defaultNamePrefix) \(index)"
        return SlideshowProject(
            id: UUID(),
            projectNumber: index,
            name: name,
            subtitle: "",
            eventPlaybackMode: .playlist,
            events: [SlideshowEvent.makeDefault(index: 1, kind: kind)],
            createdAt: now,
            updatedAt: now
        )
    }

    var primaryEvent: SlideshowEvent? {
        events.first
    }

    var kind: ProjectKind {
        primaryEvent?.kind ?? .photo
    }

    var displayTitle: String {
        get { primaryEvent?.name ?? name }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].name = newValue
        }
    }

    var displaySubtitle: String {
        get { primaryEvent?.subtitle ?? subtitle }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].subtitle = newValue
        }
    }

    var textOverlayEnabled: Bool {
        get { primaryEvent?.textOverlayEnabled ?? true }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].textOverlayEnabled = newValue
        }
    }

    var overlayPosition: OverlayPosition {
        get { primaryEvent?.overlayPosition ?? .bottomLeft }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].overlayPosition = newValue
        }
    }

    var titleAppearance: TextAppearance {
        get { primaryEvent?.titleAppearance ?? .titleDefault() }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].titleAppearance = newValue
        }
    }

    var subtitleAppearance: TextAppearance {
        get { primaryEvent?.subtitleAppearance ?? .subtitleDefault() }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].subtitleAppearance = newValue
        }
    }

    var logoOverlay: LogoOverlay {
        get { primaryEvent?.logoOverlay ?? .default() }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].logoOverlay = newValue
        }
    }

    var mediaSourceKind: MediaSourceKind {
        get { primaryEvent?.mediaSourceKind ?? .localFolder }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].mediaSourceKind = newValue
        }
    }

    var mediaFolderPath: String {
        get { primaryEvent?.mediaFolderPath ?? "" }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].mediaFolderPath = newValue
        }
    }

    var cloudSourceURL: String {
        get { primaryEvent?.cloudSourceURL ?? "" }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].cloudSourceURL = newValue
        }
    }

    var playbackOrder: PlaybackOrder {
        get { primaryEvent?.playbackOrder ?? .random }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].playbackOrder = newValue
        }
    }

    var mediaFitMode: MediaFitMode {
        get { primaryEvent?.mediaFitMode ?? .fill }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].mediaFitMode = newValue
        }
    }

    var secondsPerPhoto: Double {
        get { primaryEvent?.secondsPerPhoto ?? 8 }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].secondsPerPhoto = newValue
        }
    }

    var transitionDuration: Double {
        get { primaryEvent?.transitionDuration ?? 2.6 }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].transitionDuration = newValue
        }
    }

    var imageMotionEffect: ImageMotionEffect {
        get { primaryEvent?.imageMotionEffect ?? .kenBurns }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].imageMotionEffect = newValue
        }
    }

    var transitionEffect: TransitionEffect {
        get { primaryEvent?.transitionEffect ?? .crossfade }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].transitionEffect = newValue
        }
    }

    var specialEffect: SpecialEffect {
        get { primaryEvent?.specialEffect ?? .none }
        set {
            ensurePrimaryEvent(kind: .photo)
            events[0].specialEffect = newValue
        }
    }

    var mediaFolderURL: URL? {
        primaryEvent?.mediaFolderURL
    }

    mutating func touch() {
        updatedAt = Date()
    }

    mutating func touchEvent(_ eventID: UUID) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[index].touch()
        touch()
    }

    mutating func ensurePrimaryEvent(kind: ProjectKind) {
        guard events.isEmpty else { return }
        events = [SlideshowEvent.makeDefault(index: 1, kind: kind)]
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectNumber
        case name
        case legacySlug = "slug"
        case subtitle
        case eventPlaybackMode
        case events
        case kind
        case displayTitle
        case displaySubtitle
        case textOverlayEnabled
        case textBackgroundEffect
        case overlayPosition
        case overlayOffsetX
        case overlayOffsetY
        case titleAppearance
        case subtitleAppearance
        case logoOverlay
        case backgroundAudio
        case mediaSourceKind
        case mediaFolderPath
        case cloudSourceURL
        case legacyPhotoFolderPath = "photoFolderPath"
        case playbackOrder
        case mediaFitMode
        case secondsPerPhoto
        case transitionDuration
        case imageMotionEffect
        case kenBurnsDirection
        case kenBurnsScalePercent
        case kenBurnsFocusMode
        case transitionEffect
        case specialEffect
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        projectNumber: Int,
        name: String,
        subtitle: String,
        eventPlaybackMode: EventPlaybackMode,
        events: [SlideshowEvent],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectNumber = projectNumber
        self.name = name
        self.subtitle = subtitle
        self.eventPlaybackMode = eventPlaybackMode
        self.events = events
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectNumber = try container.decodeIfPresent(Int.self, forKey: .projectNumber) ?? 0
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        eventPlaybackMode = try container.decodeIfPresent(EventPlaybackMode.self, forKey: .eventPlaybackMode) ?? .playlist
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt

        if let decodedEvents = try container.decodeIfPresent([SlideshowEvent].self, forKey: .events),
           !decodedEvents.isEmpty {
            events = decodedEvents
            return
        }

        let legacyKind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .photo
        let decodedMediaFolderPath = try container.decodeIfPresent(String.self, forKey: .mediaFolderPath)
        let decodedLegacyPhotoFolderPath = try container.decodeIfPresent(String.self, forKey: .legacyPhotoFolderPath)
        let legacyEvent = SlideshowEvent(
            id: UUID(),
            kind: legacyKind,
            name: SlideshowEvent.preferredCaption(
                primary: try container.decodeIfPresent(String.self, forKey: .displayTitle),
                fallback: name,
                defaultValue: name
            ),
            subtitle: SlideshowEvent.preferredCaption(
                primary: try container.decodeIfPresent(String.self, forKey: .displaySubtitle),
                fallback: subtitle,
                defaultValue: ""
            ),
            displayTitle: try container.decodeIfPresent(String.self, forKey: .displayTitle) ?? name,
            displaySubtitle: try container.decodeIfPresent(String.self, forKey: .displaySubtitle) ?? subtitle,
            textOverlayEnabled: try container.decodeIfPresent(Bool.self, forKey: .textOverlayEnabled) ?? true,
            textBackgroundEffect: try container.decodeIfPresent(TextBackgroundEffect.self, forKey: .textBackgroundEffect) ?? .blurBar,
            overlayPosition: try container.decodeIfPresent(OverlayPosition.self, forKey: .overlayPosition) ?? .bottomLeft,
            overlayOffsetX: try container.decodeIfPresent(Double.self, forKey: .overlayOffsetX) ?? 0,
            overlayOffsetY: try container.decodeIfPresent(Double.self, forKey: .overlayOffsetY) ?? 0,
            titleAppearance: try container.decodeIfPresent(TextAppearance.self, forKey: .titleAppearance) ?? .titleDefault(),
            subtitleAppearance: try container.decodeIfPresent(TextAppearance.self, forKey: .subtitleAppearance) ?? .subtitleDefault(),
            logoOverlay: try container.decodeIfPresent(LogoOverlay.self, forKey: .logoOverlay) ?? .default(),
            backgroundAudio: try container.decodeIfPresent(BackgroundAudio.self, forKey: .backgroundAudio) ?? .default(),
            mediaSourceKind: try container.decodeIfPresent(MediaSourceKind.self, forKey: .mediaSourceKind) ?? .localFolder,
            mediaFolderPath: decodedMediaFolderPath ?? decodedLegacyPhotoFolderPath ?? "",
            cloudSourceURL: try container.decodeIfPresent(String.self, forKey: .cloudSourceURL) ?? "",
            playbackOrder: try container.decodeIfPresent(PlaybackOrder.self, forKey: .playbackOrder) ?? .random,
            mediaFitMode: try container.decodeIfPresent(MediaFitMode.self, forKey: .mediaFitMode) ?? .fill,
            secondsPerPhoto: try container.decodeIfPresent(Double.self, forKey: .secondsPerPhoto) ?? 8,
            transitionDuration: try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 2.6,
            imageMotionEffect: try container.decodeIfPresent(ImageMotionEffect.self, forKey: .imageMotionEffect) ?? .kenBurns,
            kenBurnsDirection: try container.decodeIfPresent(KenBurnsDirection.self, forKey: .kenBurnsDirection) ?? .zoomIn,
            kenBurnsScalePercent: try container.decodeIfPresent(Double.self, forKey: .kenBurnsScalePercent) ?? 3,
            kenBurnsFocusMode: try container.decodeIfPresent(KenBurnsFocusMode.self, forKey: .kenBurnsFocusMode) ?? .center,
            transitionEffect: try container.decodeIfPresent(TransitionEffect.self, forKey: .transitionEffect) ?? .crossfade,
            specialEffect: try container.decodeIfPresent(SpecialEffect.self, forKey: .specialEffect) ?? .none,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        events = [legacyEvent]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectNumber, forKey: .projectNumber)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .legacySlug)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(eventPlaybackMode, forKey: .eventPlaybackMode)
        try container.encode(events, forKey: .events)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func slug(for projectNumber: Int) -> String {
        String(max(projectNumber, 1))
    }
}

private struct PersistResult {
    let urls: [UUID: URL]
    let revisions: [UUID: Date]
}

@MainActor
final class ProjectStore: ObservableObject {
    enum ProjectTransferError: LocalizedError {
        case noSelection
        case cancelled
        case invalidProjectFile
        case invalidFontFile

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return String(localized: "선택된 프로젝트가 없습니다.")
            case .cancelled:
                return String(localized: "사용자가 작업을 취소했습니다.")
            case .invalidProjectFile:
                return String(localized: "올바른 프로젝트 JSON 파일이 아닙니다.")
            case .invalidFontFile:
                return String(localized: "지원되는 폰트 파일이 아닙니다. ttf, otf, ttc, otc 파일을 선택해주세요.")
            }
        }
    }

    @Published var projects: [SlideshowProject] = [] {
        didSet {
            guard !isBootstrapping else { return }
            schedulePersistProjects()
        }
    }

    @Published var selectedProjectID: SlideshowProject.ID?

    private let projectsFolderURL: URL
    private let legacyStoreURL: URL
    private let persistQueue = DispatchQueue(label: "PhotoslideStudio.ProjectStore.Persist", qos: .utility)
    private var isBootstrapping = false
    private var persistWorkItem: DispatchWorkItem?
    private var persistSequence = 0
    private var persistedProjectURLs: [UUID: URL] = [:]
    private var persistedProjectRevisions: [UUID: Date] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("PhotoslideStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        projectsFolderURL = folder.appendingPathComponent("Projects", isDirectory: true)
        legacyStoreURL = folder.appendingPathComponent("projects.json")
        try? FileManager.default.createDirectory(at: projectsFolderURL, withIntermediateDirectories: true)
        loadProjects()
    }

    func createProject(kind: ProjectKind = .photo) {
        let project = SlideshowProject.makeDefault(index: nextProjectNumber(), kind: kind)
        projects.insert(project, at: 0)
        selectedProjectID = project.id
    }

    func duplicateSelectedProject() {
        guard let selectedProjectID,
              let source = projects.first(where: { $0.id == selectedProjectID }) else { return }

        let duplicate = SlideshowProject(
            id: UUID(),
            projectNumber: nextProjectNumber(),
            name: "\(source.name) Copy",
            subtitle: source.subtitle,
            eventPlaybackMode: source.eventPlaybackMode,
            events: duplicatedEvents(from: source.events),
            createdAt: Date(),
            updatedAt: Date()
        )

        projects.insert(duplicate, at: 0)
        self.selectedProjectID = duplicate.id
    }

    func deleteSelectedProject() {
        guard let selectedProjectID else { return }
        projects.removeAll { $0.id == selectedProjectID }
        self.selectedProjectID = projects.first?.id
    }

    @MainActor
    func importProjectFromJSON() throws -> SlideshowProject {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = String(localized: "프로젝트 불러오기")

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ProjectTransferError.cancelled
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try Data(contentsOf: url)
        guard let imported = try? decoder.decode(SlideshowProject.self, from: data) else {
            throw ProjectTransferError.invalidProjectFile
        }

        let now = Date()
        let importedName = uniqueProjectName(basedOn: imported.name)
        let project = SlideshowProject(
            id: UUID(),
            projectNumber: nextProjectNumber(),
            name: importedName,
            subtitle: imported.subtitle,
            eventPlaybackMode: imported.eventPlaybackMode,
            events: duplicatedEvents(from: imported.events),
            createdAt: now,
            updatedAt: now
        )

        projects.insert(project, at: 0)
        selectedProjectID = project.id
        return project
    }

    @MainActor
    func exportSelectedProjectToJSON() throws -> URL {
        guard let selectedProjectID,
              let project = projects.first(where: { $0.id == selectedProjectID }) else {
            throw ProjectTransferError.noSelection
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = String(localized: "프로젝트 내보내기")
        panel.nameFieldStringValue = "\(Self.sanitizedProjectFileStem(for: project.name)).json"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            throw ProjectTransferError.cancelled
        }

        let destinationURL = selectedURL.pathExtension.lowercased() == "json"
            ? selectedURL
            : selectedURL.appendingPathExtension("json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    @MainActor
    func chooseMediaFolderPath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "미디어 폴더 선택")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        SecurityScopedAccess.registerUserSelectedURL(url)
        return url.path
    }

    @MainActor
    func chooseLogoFilePath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png]
        panel.prompt = String(localized: "로고 PNG 선택")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        SecurityScopedAccess.registerUserSelectedURL(url)
        return url.path
    }

    @MainActor
    func chooseBackgroundAudioFilePath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mpeg4Audio]
        panel.prompt = String(localized: "배경음악 파일 선택")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        SecurityScopedAccess.registerUserSelectedURL(url)
        return url.path
    }

    @MainActor
    func importFontFiles() throws -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "폰트 추가")
        panel.message = String(localized: "ttf, otf, ttc, otc 폰트 파일을 선택하세요.")

        guard panel.runModal() == .OK else {
            throw ProjectTransferError.cancelled
        }

        let importedFamilies = try MacFontCatalog.importFontFiles(from: panel.urls)
        AppFontRegistrar.registerImportedFonts()
        guard !importedFamilies.isEmpty else {
            throw ProjectTransferError.invalidFontFile
        }
        return importedFamilies
    }

    func updateTimestamp(for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].touch()
    }

    func save(project: SlideshowProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var merged = project
        merged.name = projects[index].name
        guard projects[index] != merged else { return }
        projects[index] = merged
    }

    func renameProject(id: UUID, name: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, projects[index].name != trimmed else { return }
        projects[index].name = trimmed
        projects[index].touch()
    }

    private func loadProjects() {
        isBootstrapping = true
        defer { isBootstrapping = false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let fileManager = FileManager.default
        let projectFileURLs = (try? fileManager.contentsOfDirectory(
            at: projectsFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let jsonFiles = projectFileURLs.filter { $0.pathExtension.lowercased() == "json" }
        let decodedFiles: [(URL, SlideshowProject)] = jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let project = try? decoder.decode(SlideshowProject.self, from: data) else {
                return nil
            }
            return (url, project)
        }

        if !decodedFiles.isEmpty {
            let loadedProjects = decodedFiles.map(\.1)
            let migrated = migrateProjectNumbers(in: loadedProjects)
                .sorted { lhs, rhs in lhs.projectNumber > rhs.projectNumber }
            let fileLookup = Dictionary(uniqueKeysWithValues: decodedFiles.map { ($0.1.id, $0.0) })
            projects = migrated
            persistedProjectURLs = fileLookup
            persistedProjectRevisions = Dictionary(uniqueKeysWithValues: migrated.map { ($0.id, $0.updatedAt) })
            selectedProjectID = migrated.first?.id
            if migrated != loadedProjects.sorted(by: { $0.projectNumber > $1.projectNumber }) {
                persistProjects()
            }
            return
        }

        if let data = try? Data(contentsOf: legacyStoreURL),
           let decoded = try? decoder.decode([SlideshowProject].self, from: data),
           !decoded.isEmpty {
            let migrated = migrateProjectNumbers(in: decoded)
                .sorted { lhs, rhs in lhs.projectNumber > rhs.projectNumber }
            projects = migrated
            selectedProjectID = migrated.first?.id
            persistProjects()
            return
        }

        projects = []
        selectedProjectID = nil
        persistedProjectURLs = [:]
        persistedProjectRevisions = [:]
    }

    private func nextProjectNumber() -> Int {
        (projects.map(\.projectNumber).max() ?? 0) + 1
    }

    private func uniqueProjectName(basedOn source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Imported Project" : trimmed
        let takenNames = Set(projects.map { $0.name.lowercased() })

        guard !takenNames.contains(baseName.lowercased()) else {
            var suffix = 2
            while takenNames.contains("\(baseName) \(suffix)".lowercased()) {
                suffix += 1
            }
            return "\(baseName) \(suffix)"
        }

        return baseName
    }

    private func duplicatedEvents(from sourceEvents: [SlideshowEvent]) -> [SlideshowEvent] {
        let now = Date()
        return sourceEvents.enumerated().map { offset, event in
            let name = uniqueEventName(basedOn: event.name, against: sourceEvents.map(\.name), offset: offset)
            return SlideshowEvent(
                id: UUID(),
                kind: event.kind,
                name: name,
                subtitle: event.subtitle,
                displayTitle: event.name,
                displaySubtitle: event.subtitle,
                textOverlayEnabled: event.textOverlayEnabled,
                textBackgroundEffect: event.textBackgroundEffect,
                overlayPosition: event.overlayPosition,
                overlayOffsetX: event.overlayOffsetX,
                overlayOffsetY: event.overlayOffsetY,
                titleAppearance: event.titleAppearance,
                subtitleAppearance: event.subtitleAppearance,
                logoOverlay: event.logoOverlay,
                backgroundAudio: event.backgroundAudio,
                mediaSourceKind: event.mediaSourceKind,
                mediaFolderPath: event.mediaFolderPath,
                cloudSourceURL: event.cloudSourceURL,
                playbackOrder: event.playbackOrder,
                mediaFitMode: event.mediaFitMode,
                secondsPerPhoto: event.secondsPerPhoto,
                transitionDuration: event.transitionDuration,
                imageMotionEffect: event.imageMotionEffect,
                kenBurnsDirection: event.kenBurnsDirection,
                kenBurnsScalePercent: event.kenBurnsScalePercent,
                kenBurnsFocusMode: event.kenBurnsFocusMode,
                transitionEffect: event.transitionEffect,
                specialEffect: event.specialEffect,
                createdAt: now.addingTimeInterval(Double(offset)),
                updatedAt: now.addingTimeInterval(Double(offset))
            )
        }
    }

    private func uniqueEventName(basedOn source: String, against existing: [String], offset: Int) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Event \(offset + 1)" : trimmed
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(baseName.lowercased()) else { return baseName }
        var suffix = 2
        while taken.contains("\(baseName) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func migrateProjectNumbers(in decoded: [SlideshowProject]) -> [SlideshowProject] {
        let orderedIDs = decoded
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
            .map(\.id)

        let assigned = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { offset, id in
            (id, offset + 1)
        })

        return decoded.map { project in
            guard project.projectNumber <= 0 else { return project }
            var migrated = project
            migrated.projectNumber = assigned[project.id] ?? 1
            return migrated
        }
    }

    private func schedulePersistProjects() {
        persistWorkItem?.cancel()
        persistSequence += 1
        let sequence = persistSequence
        let snapshot = projects
        let knownURLs = persistedProjectURLs
        let knownRevisions = persistedProjectRevisions
        let projectsFolderURL = self.projectsFolderURL

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistQueue.async {
                let result = Self.persistProjects(
                    snapshot: snapshot,
                    existingURLs: knownURLs,
                    existingRevisions: knownRevisions,
                    projectsFolderURL: projectsFolderURL
                )

                Task { @MainActor [weak self] in
                    guard let self else { return }

                    switch result {
                    case let .success(result):
                        guard sequence >= self.persistSequence else { return }
                        self.persistedProjectURLs = result.urls
                        self.persistedProjectRevisions = result.revisions
                    case .failure:
                        NSSound.beep()
                    }
                }
            }
        }

        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func persistProjects() {
        let result = Self.persistProjects(
            snapshot: projects,
            existingURLs: persistedProjectURLs,
            existingRevisions: persistedProjectRevisions,
            projectsFolderURL: projectsFolderURL
        )

        switch result {
        case let .success(result):
            persistedProjectURLs = result.urls
            persistedProjectRevisions = result.revisions
        case .failure:
            NSSound.beep()
        }
    }

    nonisolated private static func persistProjects(
        snapshot: [SlideshowProject],
        existingURLs: [UUID: URL],
        existingRevisions: [UUID: Date],
        projectsFolderURL: URL
    ) -> Result<PersistResult, Error> {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var nextURLs: [UUID: URL] = [:]
            var nextRevisions: [UUID: Date] = [:]
            var reservedNames = Set<String>()

            for project in snapshot {
                let destinationURL = Self.uniqueProjectFileURL(
                    for: project,
                    reservedNames: &reservedNames,
                    existingURLs: existingURLs,
                    projectsFolderURL: projectsFolderURL
                )
                let needsWrite = existingURLs[project.id] != destinationURL || existingRevisions[project.id] != project.updatedAt
                if needsWrite {
                    let data = try encoder.encode(project)
                    try data.write(to: destinationURL, options: .atomic)
                }
                nextURLs[project.id] = destinationURL
                nextRevisions[project.id] = project.updatedAt
            }

            let removedURLs = Set(existingURLs.values).subtracting(Set(nextURLs.values))
            for url in removedURLs {
                try? FileManager.default.removeItem(at: url)
            }

            return .success(PersistResult(urls: nextURLs, revisions: nextRevisions))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func uniqueProjectFileURL(
        for project: SlideshowProject,
        reservedNames: inout Set<String>,
        existingURLs: [UUID: URL],
        projectsFolderURL: URL
    ) -> URL {
        let baseName = Self.sanitizedProjectFileStem(for: project.name)
        let currentURL = existingURLs[project.id]
        let currentStem = currentURL?.deletingPathExtension().lastPathComponent

        var candidateStem = baseName
        var suffix = 2
        while reservedNames.contains(candidateStem) ||
              Self.existingProjectFileConflict(
                for: project.id,
                stem: candidateStem,
                currentStem: currentStem,
                existingURLs: existingURLs,
                projectsFolderURL: projectsFolderURL
              ) {
            candidateStem = "\(baseName) \(suffix)"
            suffix += 1
        }

        reservedNames.insert(candidateStem)
        return projectsFolderURL.appendingPathComponent(candidateStem).appendingPathExtension("json")
    }

    nonisolated private static func existingProjectFileConflict(
        for projectID: UUID,
        stem: String,
        currentStem: String?,
        existingURLs: [UUID: URL],
        projectsFolderURL: URL
    ) -> Bool {
        let candidateURL = projectsFolderURL.appendingPathComponent(stem).appendingPathExtension("json")
        if currentStem == stem {
            return false
        }

        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return false
        }

        if let owner = existingURLs.first(where: { $0.value.lastPathComponent == candidateURL.lastPathComponent })?.key {
            return owner != projectID
        }
        return true
    }

    nonisolated private static func sanitizedProjectFileStem(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Project"
        let base = trimmed.isEmpty ? fallback : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = base.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsed = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description.ifEmpty(fallback)
    }
}

@MainActor
enum AppFontRegistrar {
    private static var didRegister = false

    static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true

        guard let resourcesURL = Bundle.module.resourceURL?.appendingPathComponent("fonts", isDirectory: true),
              let enumerator = FileManager.default.enumerator(at: resourcesURL, includingPropertiesForKeys: nil) else {
            registerImportedFonts()
            return
        }

        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" || ext == "ttc" || ext == "otc" else { continue }
            registerFont(at: url)
        }

        registerImportedFonts()
    }

    static func registerImportedFonts() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: MacFontCatalog.importedFontsDirectoryURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls {
            registerFont(at: url)
        }
    }

    static func registerFont(at url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" || ext == "ttc" || ext == "otc" else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

func genericWeightLabel(_ weight: Int) -> String {
    switch weight {
    case 100: return "100 Thin"
    case 200: return "200 ExtraLight"
    case 300: return "300 Light"
    case 400: return "400 Regular"
    case 500: return "500 Medium"
    case 600: return "600 SemiBold"
    case 700: return "700 Bold"
    case 800: return "800 ExtraBold"
    case 900: return "900 Black"
    default: return "\(weight)"
    }
}

func alignment(for position: OverlayPosition) -> Alignment {
    position.stackAlignment
}

func textAlignment(for position: OverlayPosition) -> TextAlignment {
    switch position {
    case .topLeft, .middleLeft, .bottomLeft:
        return .leading
    case .topCenter, .center, .bottomCenter:
        return .center
    case .topRight, .middleRight, .bottomRight:
        return .trailing
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

func normalizeHexColor(_ value: String) -> String {
    let uppercase = value.uppercased()
    let filtered = uppercase.filter { $0.isHexDigit }
    let sixCharacters = String(filtered.prefix(6))
    guard !sixCharacters.isEmpty else { return "#FFFFFF" }
    return "#\(sixCharacters)"
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(sanitized, radix: 16) ?? 0xFFFFFF
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
