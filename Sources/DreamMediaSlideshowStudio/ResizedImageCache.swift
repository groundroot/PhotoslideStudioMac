import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사진을 재생 해상도에 맞춰 다운스케일해 서빙하기 위한 디스크 캐시.
/// 원본(수천만 화소, 8~12MB)을 그대로 보내면 브라우저가 슬라이드마다 풀
/// 디코딩해 인텔맥에서 히칭이 생긴다. 모든 실패 경로는 nil을 반환하고,
/// 호출부(Server.mediaResponse)가 원본 서빙으로 폴백한다.
enum ResizedImageCache {
    static let maxLongEdge = 2560
    private static let jpegQuality = 0.8
    private static let maxCacheBytes: Int64 = 1_073_741_824 // 1GB
    // GIF(애니메이션)·webp/avif(애니·알파 가능, 대개 이미 작음)는 원본 통과.
    // PNG는 알파가 있으면 원본 통과(JPEG 재인코딩이 알파를 깨므로).
    private static let candidateExtensions: Set<String> = ["jpg", "jpeg", "heic", "tiff", "tif", "bmp", "png"]

    private static let cacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("PhotoslideStudio", isDirectory: true)
            .appendingPathComponent("ResizedMediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// 다운스케일 대상이면 캐시된(없으면 즉석 생성한) 리사이즈 JPEG URL을 반환.
    /// nil이면 호출부가 원본을 그대로 서빙한다.
    static func resizedFileURL(for originalURL: URL) -> URL? {
        guard candidateExtensions.contains(originalURL.pathExtension.lowercased()) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: originalURL.path),
              let fileSize = attributes[.size] as? Int64,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }

        let key = "\(originalURL.path)|\(modified)|\(fileSize)|\(maxLongEdge)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let cachedURL = cacheDirectory.appendingPathComponent("\(digest).jpg")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        return encode(originalURL: originalURL, to: cachedURL)
    }

    private static func encode(originalURL: URL, to cachedURL: URL) -> URL? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        // 이미 충분히 작으면 재인코딩(비용+화질 손실)할 이유가 없다.
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > maxLongEdge else { return nil }
        // JPEG은 알파를 보존할 수 없다.
        if properties[kCGImagePropertyHasAlpha] as? Bool == true { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF 회전을 픽셀에 굽는다
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
        ] as [CFString: Any] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        // .atomic이라 동시 요청 2건이 같은 키를 인코딩해도 마지막 쓰기가 이기고
        // 둘 다 유효한 파일을 본다.
        // ponytail: 중복 인코딩 허용 — in-flight 중복 제거는 측정 후 필요 시.
        try? (data as Data).write(to: cachedURL, options: .atomic)
        return FileManager.default.fileExists(atPath: cachedURL.path) ? cachedURL : nil
    }

    /// 캐시 총량이 1GB를 넘으면 수정시각 오래된 순으로 초과분을 삭제.
    /// 서버 시작 시 백그라운드 큐에서 1회 호출된다.
    static func pruneIfNeeded() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var files: [(url: URL, size: Int64, modified: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxCacheBytes else { return }

        files.sort { $0.modified < $1.modified }
        for file in files {
            guard total > maxCacheBytes else { break }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
