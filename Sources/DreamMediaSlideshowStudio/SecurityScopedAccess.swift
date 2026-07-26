import Foundation

/// 샌드박스(Mac App Store 빌드)에서 사용자가 직접 고른 폴더/파일 접근을
/// 앱 재실행 후에도 유지하기 위한 security-scoped bookmark 저장소.
///
/// 미디어 폴더·로고·배경음악처럼 프로젝트가 계속 참조하는 외부 경로는 경로
/// 문자열만으로는 샌드박스에서 재실행 후 접근할 수 없다. 사용자가 선택하는
/// 순간 보안 스코프 북마크를 저장하고, 앱 시작 시 resolve + 접근을 시작한다.
///
/// 비샌드박스(개발용 `swift run`, ad-hoc 서명) 빌드에서는 보안 스코프 북마크
/// 생성이 실패하는데, 그 경우 경로 직접 접근으로 충분하므로 조용히 무시한다.
enum SecurityScopedAccess {
    private static let lock = NSLock()
    // 접근을 시작한 URL을 앱 수명 동안 붙잡아 둔다(stopAccessing 호출하지 않음).
    nonisolated(unsafe) private static var activatedURLs: [URL] = []

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("PhotoslideStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("SecurityBookmarks.plist")
    }

    private static func loadBookmarks() -> [String: Data] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] else {
            return [:]
        }
        return dict
    }

    private static func saveBookmarks(_ dict: [String: Data]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// 사용자가 NSOpenPanel 등으로 직접 고른 URL의 보안 스코프 북마크를 저장하고
    /// 즉시 접근을 시작한다. 비샌드박스 빌드에서는 아무 일도 하지 않는다.
    static func registerUserSelectedURL(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        lock.lock()
        var dict = loadBookmarks()
        dict[url.standardizedFileURL.path] = bookmark
        saveBookmarks(dict)
        lock.unlock()

        if url.startAccessingSecurityScopedResource() {
            lock.lock()
            activatedURLs.append(url)
            lock.unlock()
        }
    }

    /// 앱 시작 시 저장된 모든 북마크를 resolve하고 접근을 시작한다.
    /// stale 북마크는 갱신하고, 해석 불가한 항목은 제거한다.
    static func activateStoredBookmarks() {
        lock.lock()
        defer { lock.unlock() }

        var dict = loadBookmarks()
        var changed = false

        for (path, data) in dict {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                dict.removeValue(forKey: path)
                changed = true
                continue
            }

            if url.startAccessingSecurityScopedResource() {
                activatedURLs.append(url)
            }

            if stale, let fresh = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                dict[path] = fresh
                changed = true
            }
        }

        if changed {
            saveBookmarks(dict)
        }
    }
}
