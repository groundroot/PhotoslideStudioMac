@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Vision

enum ProjectKind: String, CaseIterable, Codable, Identifiable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return String(localized: "사진 슬라이드")
        case .video: return String(localized: "비디오 슬라이드")
        }
    }

    var shortTitle: String {
        switch self {
        case .photo: return String(localized: "사진")
        case .video: return String(localized: "비디오")
        }
    }

    var sourceLabel: String {
        switch self {
        case .photo: return String(localized: "사진 폴더")
        case .video: return String(localized: "비디오 폴더")
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .photo: return String(localized: "선택한 사진 폴더에 이미지를 추가해주세요.")
        case .video: return String(localized: "선택한 비디오 폴더에 영상을 추가해주세요.")
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .photo: return String(localized: "폴더 안 이미지는 설정한 순서대로 전체 화면 슬라이드쇼로 재생됩니다.")
        case .video: return String(localized: "폴더 안 비디오는 설정한 순서대로 전체 화면 재생목록으로 재생됩니다.")
        }
    }

    var defaultNamePrefix: String {
        switch self {
        case .photo: return String(localized: "사진 프로젝트")
        case .video: return String(localized: "비디오 프로젝트")
        }
    }

    var supportedExtensions: Set<String> {
        switch self {
        case .photo:
            return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "avif", "heic", "tiff", "tif"]
        case .video:
            return ["mp4", "m4v", "mov", "webm"]
        }
    }
}

enum MediaSourceKind: String, CaseIterable, Codable, Identifiable {
    case localFolder
    case youtubePlaylist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFolder: return String(localized: "로컬 폴더")
        case .youtubePlaylist: return String(localized: "유튜브 플레이리스트")
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "cloudSharedLink":
            // 구버전 프로젝트의 클라우드 공유링크는 유튜브 플레이리스트 옵션으로 이관.
            self = .youtubePlaylist
        default:
            self = MediaSourceKind(rawValue: raw) ?? .localFolder
        }
    }
}

enum MediaItemKind: String, Codable {
    case image
    case video
}

struct MediaPlaylistItem: Hashable {
    let kind: MediaItemKind
    let fileURL: URL
    let relativePath: String
    let name: String
    let captureDate: Date
    let durationSeconds: Double?
    let focusPoint: MediaFocusPoint?
}

struct MediaPlaybackSummary: Hashable {
    let itemCount: Int
    let totalDuration: TimeInterval

    var formattedDuration: String {
        let totalSeconds = max(Int(totalDuration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

enum MediaLibrary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var listingCache: [String: ListingCacheEntry] = [:]
    nonisolated(unsafe) private static var listingCacheOrder: [String] = []
    nonisolated(unsafe) private static var volumeLocalCache: [String: Bool] = [:]
    nonisolated(unsafe) private static var volumeLocalCacheOrder: [String] = []
    nonisolated(unsafe) private static var captureDateCache: [String: Date] = [:]
    nonisolated(unsafe) private static var captureDateCacheOrder: [String] = []
    nonisolated(unsafe) private static var videoDurationCache: [String: Double] = [:]
    nonisolated(unsafe) private static var videoDurationCacheOrder: [String] = []
    nonisolated(unsafe) private static var focusPointCache: [String: MediaFocusPoint] = [:]
    nonisolated(unsafe) private static var focusPointCacheOrder: [String] = []
    private static let listingCacheLimit = 16
    private static let volumeLocalCacheLimit = 64
    private static let captureDateCacheLimit = 2_048
    private static let videoDurationCacheLimit = 1_024
    private static let focusPointCacheLimit = 2_048

    static func orderedItems(for event: SlideshowEvent) -> [MediaPlaylistItem] {
        let entries = listingEntry(for: event).items
        let requiresCaptureDate = event.playbackOrder == .captureDateAscending
        let requiresDuration = event.kind == .video
        let requiresFocusPoint = event.kind == .photo
            && event.imageMotionEffect == .kenBurns
            && event.kenBurnsFocusMode == .subject
        let items = entries.map { entry in
            MediaPlaylistItem(
                kind: entry.kind,
                fileURL: entry.fileURL,
                relativePath: entry.relativePath,
                name: entry.name,
                captureDate: entry.captureDate ?? (requiresCaptureDate ? captureDate(for: entry.fileURL, kind: entry.kind) : .distantPast),
                durationSeconds: entry.durationSeconds ?? (requiresDuration ? videoDuration(for: entry.fileURL) : nil),
                focusPoint: entry.focusPoint ?? (requiresFocusPoint ? focusPoint(for: entry.fileURL, kind: entry.kind) : nil)
            )
        }

        switch event.playbackOrder {
        case .random:
            return items
        case .fileNameAscending:
            return items.sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        case .captureDateAscending:
            return items.sorted { lhs, rhs in
                if lhs.captureDate == rhs.captureDate {
                    return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                }
                return lhs.captureDate < rhs.captureDate
            }
        }
    }

    static func orderedItems(for project: SlideshowProject) -> [MediaPlaylistItem] {
        guard let event = project.primaryEvent else { return [] }
        return orderedItems(for: event)
    }

    static func summary(for event: SlideshowEvent) -> MediaPlaybackSummary {
        let entries = listingEntry(for: event).items
        let totalDuration: TimeInterval
        switch event.kind {
        case .photo:
            totalDuration = Double(entries.count) * event.secondsPerPhoto
        case .video:
            totalDuration = entries.reduce(0.0) { partialResult, entry in
                partialResult + max(entry.durationSeconds ?? videoDuration(for: entry.fileURL), 0)
            }
        }
        return MediaPlaybackSummary(itemCount: entries.count, totalDuration: totalDuration)
    }

    static func summary(for project: SlideshowProject) -> MediaPlaybackSummary {
        guard let event = project.primaryEvent else {
            return MediaPlaybackSummary(itemCount: 0, totalDuration: 0)
        }
        return summary(for: event)
    }

    static func fileURL(for relativePath: String, event: SlideshowEvent) -> URL? {
        guard event.mediaSourceKind == .localFolder, let folderURL = event.mediaFolderURL else { return nil }
        return localListingEntry(kind: event.kind, in: folderURL).itemMap[relativePath]?.fileURL
    }

    static func fileURL(for relativePath: String, project: SlideshowProject) -> URL? {
        guard let event = project.primaryEvent else { return nil }
        return fileURL(for: relativePath, event: event)
    }

    private static func listingEntry(for event: SlideshowEvent) -> ListingCacheEntry {
        switch event.mediaSourceKind {
        case .localFolder:
            guard let folderURL = event.mediaFolderURL else {
                return ListingCacheEntry(timestamp: .distantPast, items: [], itemMap: [:])
            }
            return localListingEntry(kind: event.kind, in: folderURL)
        case .youtubePlaylist:
            // 유튜브 플레이리스트는 웹 플레이어가 IFrame API로 직접 재생한다 —
            // 로컬 미디어 항목은 없다.
            return ListingCacheEntry(timestamp: .distantPast, items: [], itemMap: [:])
        }
    }

    private static func localListingEntry(kind: ProjectKind, in folderURL: URL) -> ListingCacheEntry {
        let cacheKey = "\(kind.rawValue)::\(folderURL.standardizedFileURL.path)"
        let now = Date()
        let cacheLifetime = isLocalVolume(for: folderURL) ? 20.0 : 60.0

        lock.lock()
        if let cached = listingCache[cacheKey],
           now.timeIntervalSince(cached.timestamp) < cacheLifetime {
            touchCacheKey(cacheKey, in: &listingCacheOrder)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var items: [ListedMediaEntry] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            autoreleasepool {
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { return }
                guard kind.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { return }

                let relativePath = relativePath(for: fileURL, baseFolderURL: folderURL)
                let itemKind: MediaItemKind = kind == .photo ? .image : .video
                items.append(
                    ListedMediaEntry(
                        kind: itemKind,
                        fileURL: fileURL,
                        relativePath: relativePath,
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        captureDate: nil,
                        durationSeconds: nil
                    )
                )
            }
        }

        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })
        let entry = ListingCacheEntry(timestamp: now, items: items, itemMap: itemMap)
        lock.lock()
        storeCachedValue(
            entry,
            forKey: cacheKey,
            in: &listingCache,
            order: &listingCacheOrder,
            limit: listingCacheLimit
        )
        lock.unlock()
        return entry
    }

    static func relativePath(for fileURL: URL, baseFolderURL: URL) -> String {
        let standardizedBasePath = baseFolderURL.standardizedFileURL.path
        let standardizedFilePath = fileURL.standardizedFileURL.path
        let prefix = standardizedBasePath.hasSuffix("/") ? standardizedBasePath : standardizedBasePath + "/"
        // 선행 prefix만 제거한다. replacingOccurrences는 경로 안에서 반복되는
        // 베이스 경로까지 모두 지워 서로 다른 파일의 relativePath가 충돌할 수
        // 있고, 그러면 itemMap의 Dictionary(uniqueKeysWithValues:)가 트랩한다.
        if standardizedFilePath.hasPrefix(prefix) {
            return String(standardizedFilePath.dropFirst(prefix.count))
        }
        return standardizedFilePath
    }

    private static func captureDate(for fileURL: URL, kind: MediaItemKind) -> Date {
        if !fileURL.isFileURL {
            return .distantPast
        }

        let cacheKey = cacheKey(for: fileURL)
        lock.lock()
        if let cached = captureDateCache[cacheKey] {
            touchCacheKey(cacheKey, in: &captureDateCacheOrder)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fileDates = (try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])).flatMap { values in
            values.creationDate ?? values.contentModificationDate
        }

        let resolvedDate: Date
        switch kind {
        case .image:
            resolvedDate = imageExifDate(for: fileURL) ?? fileDates ?? .distantPast
        case .video:
            resolvedDate = fileDates ?? quickTimeCreationDate(for: fileURL) ?? .distantPast
        }

        lock.lock()
        storeCachedValue(
            resolvedDate,
            forKey: cacheKey,
            in: &captureDateCache,
            order: &captureDateCacheOrder,
            limit: captureDateCacheLimit
        )
        lock.unlock()
        return resolvedDate
    }

    private static func imageExifDate(for fileURL: URL) -> Date? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return nil
            }

            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let rawValue = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let parsed = exifFormatter.date(from: rawValue) {
                return parsed
            }

            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let rawValue = tiff[kCGImagePropertyTIFFDateTime] as? String,
               let parsed = exifFormatter.date(from: rawValue) {
                return parsed
            }

            return nil
        }
    }

    private static func quickTimeCreationDate(for fileURL: URL) -> Date? {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let metadataItems = runAsyncAndWait {
            (try? await asset.load(.commonMetadata)) ?? []
        }
        let creationDateItems = AVMetadataItem.metadataItems(
            from: metadataItems,
            filteredByIdentifier: .commonIdentifierCreationDate
        )

        for item in creationDateItems {
            if let value = runAsyncAndWait({ try? await item.load(.stringValue) }),
               let date = iso8601Formatter.date(from: value) ?? quickTimeFormatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func videoDuration(for fileURL: URL) -> Double {
        let cacheKey = cacheKey(for: fileURL)
        lock.lock()
        if let cached = videoDurationCache[cacheKey] {
            touchCacheKey(cacheKey, in: &videoDurationCacheOrder)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let rawSeconds = CMTimeGetSeconds(runAsyncAndWait {
            (try? await asset.load(.duration)) ?? .zero
        })
        let seconds = rawSeconds.isFinite ? max(rawSeconds, 0) : 0

        lock.lock()
        storeCachedValue(
            seconds,
            forKey: cacheKey,
            in: &videoDurationCache,
            order: &videoDurationCacheOrder,
            limit: videoDurationCacheLimit
        )
        lock.unlock()
        return seconds
    }

    private static func runAsyncAndWait<T>(_ work: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        Task.detached(priority: .utility) {
            let value = await work()
            box.value = value
            semaphore.signal()
        }

        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private static func cacheKey(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    private static func focusPoint(for fileURL: URL, kind: MediaItemKind) -> MediaFocusPoint {
        guard kind == .image, fileURL.isFileURL else {
            return .fallbackCenter
        }

        let cacheKey = cacheKey(for: fileURL)
        lock.lock()
        if let cached = focusPointCache[cacheKey] {
            touchCacheKey(cacheKey, in: &focusPointCacheOrder)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = analyzeFocusPoint(for: fileURL)

        lock.lock()
        storeCachedValue(
            resolved,
            forKey: cacheKey,
            in: &focusPointCache,
            order: &focusPointCacheOrder,
            limit: focusPointCacheLimit
        )
        lock.unlock()
        return resolved
    }

    private static func analyzeFocusPoint(for fileURL: URL) -> MediaFocusPoint {
        if let faceFocus = detectFaceFocus(for: fileURL) {
            return faceFocus
        }
        return .fallbackCenter
    }

    private static func detectFaceFocus(for fileURL: URL) -> MediaFocusPoint? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(url: fileURL)

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        if observations.count >= 10 {
            return groupFocusPoint(from: observations)
        }

        let bestFace = observations.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }

        guard let bestFace else { return nil }
        return focusPoint(from: bestFace.boundingBox, source: .visionFace)
    }

    private static func groupFocusPoint(from observations: [VNFaceObservation]) -> MediaFocusPoint {
        let centers = observations.map {
            CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
        }
        let centroid = CGPoint(
            x: centers.reduce(0) { $0 + $1.x } / Double(centers.count),
            y: centers.reduce(0) { $0 + $1.y } / Double(centers.count)
        )

        let selectedCount = Swift.min(Swift.max(3, observations.count / 4), 5)
        let centralFaces = observations
            .sorted { lhs, rhs in
                let lhsDistance = squaredDistance(from: CGPoint(x: lhs.boundingBox.midX, y: lhs.boundingBox.midY), to: centroid)
                let rhsDistance = squaredDistance(from: CGPoint(x: rhs.boundingBox.midX, y: rhs.boundingBox.midY), to: centroid)
                return lhsDistance < rhsDistance
            }
            .prefix(selectedCount)

        let weightedCenter = weightedFaceCenter(for: Array(centralFaces))
        return focusPoint(x: weightedCenter.x, y: weightedCenter.y, source: .visionGroup)
    }

    private static func focusPoint(from rect: CGRect, source: MediaFocusSource) -> MediaFocusPoint {
        focusPoint(x: rect.midX, y: 1 - rect.midY, source: source)
    }

    private static func focusPoint(x: Double, y: Double, source: MediaFocusSource) -> MediaFocusPoint {
        let normalizedX = clamp(x * 100, min: 28, max: 72)
        let normalizedY = clamp(y * 100, min: 28, max: 72)
        return MediaFocusPoint(x: normalizedX, y: normalizedY, source: source)
    }

    private static func weightedFaceCenter(for observations: [VNFaceObservation]) -> CGPoint {
        guard !observations.isEmpty else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        var weightedX = 0.0
        var weightedY = 0.0
        var totalWeight = 0.0

        for observation in observations {
            let rect = observation.boundingBox
            let area = rect.width * rect.height
            let weight = max(sqrt(area), 0.0001)
            weightedX += rect.midX * weight
            weightedY += rect.midY * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        return CGPoint(x: weightedX / totalWeight, y: weightedY / totalWeight)
    }

    private static func squaredDistance(from point: CGPoint, to other: CGPoint) -> Double {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return dx * dx + dy * dy
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(max, Swift.max(min, value))
    }

    private static func isLocalVolume(for folderURL: URL) -> Bool {
        let cacheKey = folderURL.standardizedFileURL.path

        lock.lock()
        if let cached = volumeLocalCache[cacheKey] {
            touchCacheKey(cacheKey, in: &volumeLocalCacheOrder)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = (try? folderURL.resourceValues(forKeys: [.volumeIsLocalKey])).flatMap(\.volumeIsLocal) ?? true

        lock.lock()
        storeCachedValue(
            resolved,
            forKey: cacheKey,
            in: &volumeLocalCache,
            order: &volumeLocalCacheOrder,
            limit: volumeLocalCacheLimit
        )
        lock.unlock()
        return resolved
    }

    private static func touchCacheKey(_ key: String, in order: inout [String]) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func storeCachedValue<Value>(
        _ value: Value,
        forKey key: String,
        in cache: inout [String: Value],
        order: inout [String],
        limit: Int
    ) {
        cache[key] = value
        touchCacheKey(key, in: &order)

        while cache.count > limit, let oldestKey = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    private static let quickTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()
}

struct ListedMediaEntry {
    let kind: MediaItemKind
    let fileURL: URL
    let relativePath: String
    let name: String
    let captureDate: Date?
    let durationSeconds: Double?
    let focusPoint: MediaFocusPoint? = nil
}

struct ListingCacheEntry {
    let timestamp: Date
    let items: [ListedMediaEntry]
    let itemMap: [String: ListedMediaEntry]
}

enum MediaFocusSource: String, Codable, Hashable {
    case visionFace = "vision-face"
    case visionGroup = "vision-group"
    case fallbackCenter = "fallback-center"
}

struct MediaFocusPoint: Codable, Hashable {
    let x: Double
    let y: Double
    let source: MediaFocusSource

    static let fallbackCenter = MediaFocusPoint(x: 50, y: 50, source: .fallbackCenter)
}
