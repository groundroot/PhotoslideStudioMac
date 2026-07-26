import Foundation

enum CloudSourceResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ListingCacheEntry] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []
    private static let cacheLifetime: TimeInterval = 300
    private static let cacheLimit = 16

    static func listingEntry(for event: SlideshowEvent) -> ListingCacheEntry {
        let sharedLink = event.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sharedLink.isEmpty else {
            return ListingCacheEntry(timestamp: .distantPast, items: [], itemMap: [:])
        }

        let cacheKey = "\(event.kind.rawValue)::\(sharedLink)"
        let now = Date()

        lock.lock()
        if let cached = cache[cacheKey], now.timeIntervalSince(cached.timestamp) < cacheLifetime {
            touchCacheKey(cacheKey)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let items = resolveItems(kind: event.kind, sharedLink: sharedLink)
        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })
        let entry = ListingCacheEntry(timestamp: now, items: items, itemMap: itemMap)

        lock.lock()
        cache[cacheKey] = entry
        touchCacheKey(cacheKey)
        while cache.count > cacheLimit, let oldestKey = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }
        lock.unlock()
        return entry
    }

    private static func touchCacheKey(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    static func listingEntry(for project: SlideshowProject) -> ListingCacheEntry {
        guard let event = project.primaryEvent else {
            return ListingCacheEntry(timestamp: .distantPast, items: [], itemMap: [:])
        }
        return listingEntry(for: event)
    }

    private static func resolveItems(kind: ProjectKind, sharedLink: String) -> [ListedMediaEntry] {
        guard let sourceURL = URL(string: sharedLink) else { return [] }

        if let directEntry = directMediaEntry(for: sourceURL, kind: kind) {
            return [directEntry]
        }

        if sourceURL.pathExtension.lowercased() == "json",
           let response = fetch(sourceURL) {
            let manifestItems = parseManifest(data: response.data, baseURL: sourceURL, kind: kind)
            if !manifestItems.isEmpty {
                return manifestItems
            }
        }

        let candidateURLs = normalizedCandidateURLs(for: sourceURL)
        for candidate in candidateURLs {
            // 직접 다운로드 미디어 URL은 본문을 내려받지 않고 URL만으로 판정한다.
            // (대용량 영상을 통째로 메모리에 받아야 플레이리스트가 만들어지는 문제 방지)
            if let directEntry = directMediaEntry(for: candidate, kind: kind) {
                return [directEntry]
            }

            if let response = fetch(candidate) {
                if response.mimeType.contains("json") {
                    let manifestItems = parseManifest(data: response.data, baseURL: candidate, kind: kind)
                    if !manifestItems.isEmpty {
                        return manifestItems
                    }
                }

                if response.mimeType.contains("html") || response.mimeType.contains("text/plain") {
                    let htmlItems = parseHTML(data: response.data, baseURL: candidate, kind: kind)
                    if !htmlItems.isEmpty {
                        return htmlItems
                    }
                }

            }
        }

        return []
    }

    private static func normalizedCandidateURLs(for url: URL) -> [URL] {
        var candidates: [URL] = []

        if let googleFileURL = googleDriveDirectMediaURL(from: url) {
            candidates.append(googleFileURL)
        }

        if let oneDriveDownloadURL = oneDriveDownloadURL(from: url) {
            candidates.append(oneDriveDownloadURL)
        }

        candidates.append(url)

        var unique: [URL] = []
        var seen = Set<String>()
        for candidate in candidates {
            let key = candidate.absoluteString
            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }
        return unique
    }

    private static func googleDriveDirectMediaURL(from url: URL) -> URL? {
        let urlString = url.absoluteString

        if let match = urlString.range(of: #"/file/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            let id = String(urlString[match]).components(separatedBy: "/").last ?? ""
            return URL(string: "https://drive.google.com/uc?export=download&id=\(id)")
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let fileID = components.queryItems?.first(where: { $0.name == "id" })?.value,
           !fileID.isEmpty {
            return URL(string: "https://drive.google.com/uc?export=download&id=\(fileID)")
        }

        return nil
    }

    private static func oneDriveDownloadURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host.contains("onedrive") || host.contains("1drv.ms") || host.contains("sharepoint") else {
            return nil
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name.lowercased() == "download" }) {
            queryItems[index] = URLQueryItem(name: "download", value: "1")
        } else {
            queryItems.append(URLQueryItem(name: "download", value: "1"))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func directMediaEntry(for url: URL, kind: ProjectKind) -> ListedMediaEntry? {
        guard isDirectMediaURL(url, projectKind: kind) else { return nil }
        guard inferredKind(for: url, projectKind: kind) != nil else { return nil }
        return makeEntry(from: url, fallbackKind: kind, index: 0)
    }

    private static func parseManifest(data: Data, baseURL: URL, kind: ProjectKind) -> [ListedMediaEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(RemoteManifest.self, from: data) {
            return payload.items.enumerated().compactMap { offset, item in
                guard let url = resolvedURL(from: item.url, baseURL: baseURL) else { return nil }
                return makeEntry(
                    from: url,
                    fallbackKind: kind,
                    index: offset,
                    explicitName: item.name,
                    captureDate: item.captureDate,
                    durationSeconds: item.durationSeconds
                )
            }
        }

        if let urls = try? decoder.decode([String].self, from: data) {
            return urls.enumerated().compactMap { offset, item in
                guard let url = resolvedURL(from: item, baseURL: baseURL) else { return nil }
                return makeEntry(from: url, fallbackKind: kind, index: offset)
            }
        }

        return []
    }

    private static func parseHTML(data: Data, baseURL: URL, kind: ProjectKind) -> [ListedMediaEntry] {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return []
        }

        let unescapedHTML = html.replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"(?i)(https?:\/\/[^"'<>\s]+|\/[^"'<>\s]+)(\.(jpg|jpeg|png|webp|gif|bmp|avif|heic|tiff|tif|mp4|m4v|mov|webm)(\?[^"'<>\s]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(unescapedHTML.startIndex..., in: unescapedHTML)
        let matches = regex.matches(in: unescapedHTML, range: range)

        var urls: [URL] = []
        var seen = Set<String>()
        for match in matches {
            guard let matchRange = Range(match.range(at: 0), in: unescapedHTML) else { continue }
            let raw = String(unescapedHTML[matchRange])
            guard let resolved = resolvedURL(from: raw, baseURL: baseURL) else { continue }
            if seen.insert(resolved.absoluteString).inserted {
                urls.append(resolved)
            }
        }

        return urls.enumerated().compactMap { offset, url in
            makeEntry(from: url, fallbackKind: kind, index: offset)
        }
    }

    private static func resolvedURL(from rawValue: String, baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private static func makeEntry(
        from url: URL,
        fallbackKind: ProjectKind,
        index: Int,
        explicitName: String? = nil,
        captureDate: Date? = nil,
        durationSeconds: Double? = nil
    ) -> ListedMediaEntry? {
        guard let kind = inferredKind(for: url, projectKind: fallbackKind) else { return nil }

        let cleanedName = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = {
            if let cleanedName, !cleanedName.isEmpty {
                return cleanedName
            }
            let lastComponent = url.deletingPathExtension().lastPathComponent
            return lastComponent.isEmpty ? "\(fallbackKind.shortTitle) \(index + 1)" : lastComponent
        }()

        return ListedMediaEntry(
            kind: kind,
            fileURL: url,
            relativePath: "remote-\(index)-\(url.absoluteString)",
            name: name,
            captureDate: captureDate,
            durationSeconds: durationSeconds
        )
    }

    private static func inferredKind(for url: URL, projectKind: ProjectKind) -> MediaItemKind? {
        let extensionName = url.pathExtension.lowercased()
        if projectKind == .photo {
            if ProjectKind.photo.supportedExtensions.contains(extensionName) {
                return .image
            }
            return isKnownDirectDownloadEndpoint(url) ? .image : nil
        }
        if ProjectKind.video.supportedExtensions.contains(extensionName) {
            return .video
        }
        return isKnownDirectDownloadEndpoint(url) ? .video : nil
    }

    private static func isDirectMediaURL(_ url: URL, projectKind: ProjectKind) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        if projectKind.supportedExtensions.contains(extensionName) {
            return true
        }
        return isKnownDirectDownloadEndpoint(url)
    }

    private static func isKnownDirectDownloadEndpoint(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        if raw.contains("export=download") || raw.contains("download=1") || raw.contains("raw=1") {
            return true
        }
        let host = url.host?.lowercased() ?? ""
        return host.contains("googleusercontent.com")
    }

    private static func fetch(_ url: URL) -> (data: Data, mimeType: String)? {
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: makeConfiguration())
        let box = FetchResultBox()

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 PhotoslideStudio/1.0", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode),
                  let data else {
                return
            }
            box.store(data: data, mimeType: http.mimeType?.lowercased() ?? "")
        }
        task.resume()
        semaphore.wait()
        session.invalidateAndCancel()

        return box.value
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

private final class FetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (data: Data, mimeType: String)?

    func store(data: Data, mimeType: String) {
        lock.lock()
        stored = (data, mimeType)
        lock.unlock()
    }

    var value: (data: Data, mimeType: String)? {
        lock.lock()
        let snapshot = stored
        lock.unlock()
        return snapshot
    }
}

private struct RemoteManifest: Decodable {
    let items: [RemoteManifestItem]
}

private struct RemoteManifestItem: Decodable {
    let url: String
    let name: String?
    let captureDate: Date?
    let durationSeconds: Double?
}
