import Combine
import CoreText
import Foundation
import Network

final class LocalSlideshowServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false
    @Published private(set) var hostOptions: [ServerHostOption] = [.loopback]
    @Published private(set) var presentationHost: String = ServerHostOption.loopback.address
    @Published private(set) var port: UInt16 = 8787

    static let presentationHostDefaultsKey = "server.presentationHost"

    var portDescription: String {
        "Port \(port)"
    }

    private let queue = DispatchQueue(label: "PhotoslideStudio.Server")
    private let snapshotLock = NSLock()
    private var listener: NWListener?
    private var projectSnapshot: [SlideshowProject] = []
    private var projectSubscription: AnyCancellable?
    private lazy var projectHTMLTemplate: String = Self.loadResource(named: "gallery-monument", withExtension: "html")
    private lazy var projectStylesheetData: Data = Self.loadResourceData(named: "gallery-monument", withExtension: "css")
    private lazy var projectScriptData: Data = Self.loadResourceData(named: "gallery-monument", withExtension: "js")

    @MainActor
    init(projectStore: ProjectStore) {
        replaceProjectSnapshot(projectStore.projects)
        projectSubscription = projectStore.$projects
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projects in
                self?.replaceProjectSnapshot(projects)
            }
        refreshAvailableHosts()
    }

    func start() {
        refreshAvailableHosts()
        guard listener == nil else { return }

        // 연결별 큐에서 동시에 접근되기 전에 lazy 리소스를 미리 초기화한다.
        // Swift의 lazy 저장 프로퍼티는 thread-safe하지 않으므로, 단일 스레드인
        // 지금 시점에 한 번 강제 로드해 초기화 레이스를 방지한다.
        _ = projectHTMLTemplate
        _ = projectStylesheetData
        _ = projectScriptData

        DispatchQueue.global(qos: .utility).async {
            ResizedImageCache.pruneIfNeeded()
        }

        do {
            let nwPort = NWEndpoint.Port(rawValue: port) ?? 8787
            let listener = try NWListener(using: .tcp, on: nwPort)

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.refreshAvailableHosts()
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    func presentationURL(for project: SlideshowProject) -> URL? {
        url(for: project, host: presentationHost, viewMode: "signage")
    }

    func url(for project: SlideshowProject, host: String, viewMode: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        let encodedSlug = project.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project.slug
        components.percentEncodedPath = "/p/\(encodedSlug)"
        if let viewMode, !viewMode.isEmpty {
            components.queryItems = [URLQueryItem(name: "view", value: viewMode)]
        }
        return components.url
    }

    /// 사용자가 고른 주소로 URL을 만든다. 보는 쪽 기기가 어느 망에 있느냐에 따라
    /// 같은 서브넷 주소, Tailscale 주소 중 무엇이 닿는지가 달라지므로 앱이 정할 수 없다.
    func selectPresentationHost(_ address: String) {
        guard hostOptions.contains(where: { $0.address == address }) else { return }
        presentationHost = address
        UserDefaults.standard.set(address, forKey: Self.presentationHostDefaultsKey)
    }

    private func refreshAvailableHosts() {
        let options = HostAddressResolver.localHostOptions() + [.loopback]
        hostOptions = options

        // 맥을 껐다 켜도 주소가 그대로여야 한다. 마지막으로 안내한 주소를 저장해
        // 두고, 그 주소가 아직 살아 있으면 계속 같은 주소를 쓴다.
        let defaults = UserDefaults.standard
        let remembered = defaults.string(forKey: Self.presentationHostDefaultsKey)
        let host = HostAddressResolver.preferredPresentationHost(
            remembered: remembered,
            candidates: options.map(\.address)
        )
        presentationHost = host
        if host != ServerHostOption.loopback.address, host != remembered {
            defaults.set(host, forKey: Self.presentationHostDefaultsKey)
        }
    }

    private func handle(connection: NWConnection) {
        // 각 연결을 전용 직렬 큐에서 처리해, 한 요청의 블로킹 작업(클라우드
        // 링크 fetch, AVAsset 분석)이 다른 연결과 리스너의 신규 연결 수락을
        // 막지 않도록 한다. NWConnection 콜백은 이 큐에서 직렬화된다.
        let connectionQueue = DispatchQueue(label: "PhotoslideStudio.Server.Connection", qos: .userInitiated)
        connection.start(queue: connectionQueue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                let request = HTTPRequest(data: nextBuffer)
                let response = self.route(request: request)
                self.send(response: response, headOnly: request.method == "HEAD", on: connection)
                return
            }

            if error == nil {
                self.receiveRequest(on: connection, buffer: nextBuffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func send(response: HTTPResponse, headOnly: Bool, on connection: NWConnection) {
        var bytes = Data(response.headerBlock.utf8)
        if !headOnly {
            bytes.append(response.body)
        }

        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func route(request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .text("Method Not Allowed", status: "405 Method Not Allowed")
        }

        guard let components = URLComponents(string: "http://localhost\(request.target)") else {
            return .text("Bad Request", status: "400 Bad Request")
        }

        let path = components.percentEncodedPath
        switch path {
        case "/":
            return landingPage()
        case "/static/gallery-monument.css":
            return .binary(projectStylesheetData, contentType: "text/css; charset=utf-8", cacheControl: "no-store, max-age=0")
        case "/static/gallery-monument.js":
            return .binary(projectScriptData, contentType: "application/javascript; charset=utf-8", cacheControl: "no-store, max-age=0")
        default:
            break
        }

        if path.hasPrefix("/static/fonts/") {
            return staticFontResponse(path: path)
        }

        if path.hasPrefix("/p/") {
            let slug = String(path.dropFirst(3)).removingPercentEncoding ?? ""
            return projectPage(slug: slug)
        }

        if path.hasPrefix("/api/project/") {
            let slug = String(path.dropFirst("/api/project/".count)).removingPercentEncoding ?? ""
            return projectJSON(slug: slug, queryItems: components.queryItems ?? [])
        }

        if path.hasPrefix("/_media/") {
            return mediaResponse(path: path, request: request)
        }

        if path.hasPrefix("/_logo/") {
            return logoResponse(path: path)
        }

        if path.hasPrefix("/_audio/") {
            return backgroundAudioResponse(path: path, request: request)
        }

        if path.hasPrefix("/_font/") {
            return installedFontResponse(path: path)
        }

        if path == "/favicon.ico" || path == "/apple-touch-icon.png" || path == "/apple-touch-icon-precomposed.png" {
            return .empty(status: "204 No Content")
        }

        return .text("Not Found", status: "404 Not Found")
    }

    private func landingPage() -> HTTPResponse {
        let cards = snapshotProjects().map { project in
            """
            <a class="card" href="/p/\(project.slug)">
              <span class="card__label">PROJECT</span>
              <strong>\(Self.escape(project.name))</strong>
              <span>\(project.events.count) events · URL \(project.slug)</span>
            </a>
            """
        }.joined(separator: "\n")

        let html = """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Dream Media Slideshow Studio</title>
          <style>
            :root { color-scheme: light; }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              font-family: "Pretendard Variable", sans-serif;
              background:
                radial-gradient(circle at top left, rgba(245, 158, 11, 0.18), transparent 30%),
                linear-gradient(160deg, #fffdfa 0%, #f3f0eb 100%);
              color: #121212;
              padding: 48px 28px;
            }
            .shell { max-width: 1100px; margin: 0 auto; }
            h1 { font-size: clamp(3rem, 7vw, 6rem); line-height: 0.92; margin: 0 0 12px; letter-spacing: -0.04em; }
            p { margin: 0; color: rgba(18, 18, 18, 0.72); max-width: 44rem; }
            .grid {
              margin-top: 32px;
              display: grid;
              gap: 16px;
              grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            }
            .card {
              color: inherit;
              text-decoration: none;
              padding: 20px;
              border-radius: 24px;
              background: rgba(255, 255, 255, 0.72);
              border: 1px solid rgba(0, 0, 0, 0.08);
              backdrop-filter: blur(20px);
              display: grid;
              gap: 8px;
            }
            .card__label { font-size: 0.72rem; letter-spacing: 0.22em; color: rgba(18, 18, 18, 0.54); }
          </style>
        </head>
        <body>
          <main class="shell">
            <p>Project</p>
            <h1>Local media slideshow links for OptiSigns.</h1>
            <p>사진 폴더 또는 비디오 폴더를 넣으면 각 프로젝트가 고유 웹 주소로 열립니다.</p>
            <section class="grid">\(cards)</section>
          </main>
        </body>
        </html>
        """

        return .html(html)
    }

    private func projectPage(slug: String) -> HTTPResponse {
        guard snapshotProjects().contains(where: { $0.slug == slug }) else {
            return .text("Project Not Found", status: "404 Not Found")
        }

        let html = projectHTMLTemplate.replacingOccurrences(of: "__PROJECT_SLUG__", with: Self.escape(slug))
        return .html(html)
    }

    private func projectJSON(slug: String, queryItems: [URLQueryItem]) -> HTTPResponse {
        guard let project = snapshotProjects().first(where: { $0.slug == slug }) else {
            return .text("Project Not Found", status: "404 Not Found")
        }

        let viewMode = queryItems.first(where: { $0.name == "view" })?.value ?? "browser"
        let previewScope = queryItems.first(where: { $0.name == "previewScope" })?.value ?? "selected"
        let previewEventID = queryItems.first(where: { $0.name == "eventID" })?.value ?? ""

        var scopedEvents = project.events
        if viewMode == "browser",
           previewScope != "playlist",
           !previewEventID.isEmpty,
           let selectedEvent = scopedEvents.first(where: { $0.id.uuidString.caseInsensitiveCompare(previewEventID) == .orderedSame }) {
            scopedEvents = [selectedEvent]
        }

        // 무료 버전: 프로젝트 전체 합산으로 사진 10장·영상 1개까지만 재생한다.
        // (프로젝트 이벤트 순서 기준으로 예산을 소진 — 프리뷰/사이니지 공통 적용)
        var freeTierItems: [UUID: [MediaPlaylistItem]]?
        if !ProStore.isProCached {
            var photoBudget = FreeTierLimits.maxPhotosPerProject
            var videoBudget = FreeTierLimits.maxVideosPerProject
            var capped: [UUID: [MediaPlaylistItem]] = [:]
            for event in project.events {
                var kept: [MediaPlaylistItem] = []
                for item in MediaLibrary.orderedItems(for: event) {
                    switch item.kind {
                    case .image:
                        guard photoBudget > 0 else { continue }
                        photoBudget -= 1
                        kept.append(item)
                    case .video:
                        guard videoBudget > 0 else { continue }
                        videoBudget -= 1
                        kept.append(item)
                    }
                }
                capped[event.id] = kept
            }
            freeTierItems = capped
        }

        let eventPayloads = scopedEvents.map { event in
            EventPayload(
                id: event.id.uuidString,
                name: event.name,
                subtitle: event.subtitle,
                createdAt: event.createdAt.timeIntervalSince1970,
                projectKind: event.kind.rawValue,
                title: event.name,
                displaySubtitle: event.subtitle,
                textEnabled: event.textOverlayEnabled,
                textBackgroundEffect: event.textBackgroundEffect.rawValue,
                emptyStateTitle: event.kind.emptyStateTitle,
                emptyStateSubtitle: event.kind.emptyStateSubtitle,
                overlayPosition: event.overlayPosition.rawValue,
                overlayOffsetX: event.overlayOffsetX,
                overlayOffsetY: event.overlayOffsetY,
                titleStyle: TextStylePayload(
                    fontFamily: event.titleAppearance.cssFontFamily,
                    fontFaces: fontFacePayloads(for: project, event: event, appearance: event.titleAppearance, styleKey: "title"),
                    size: event.titleAppearance.size,
                    color: event.titleAppearance.colorHex,
                    weightEnabled: event.titleAppearance.weightEnabled,
                    weight: event.titleAppearance.resolvedWeight,
                    italicEnabled: event.titleAppearance.italicEnabled,
                    letterSpacingEnabled: event.titleAppearance.letterSpacingEnabled,
                    letterSpacing: event.titleAppearance.resolvedLetterSpacing,
                    lineHeightEnabled: event.titleAppearance.lineHeightEnabled,
                    lineHeight: event.titleAppearance.resolvedLineHeight,
                    shadowEnabled: event.titleAppearance.shadowEnabled,
                    shadowStrength: event.titleAppearance.shadowStrength,
                    shadowOpacity: event.titleAppearance.shadowOpacity,
                    shadowDistance: event.titleAppearance.shadowDistance,
                    shadowBlur: event.titleAppearance.shadowBlur,
                    shadowFeather: event.titleAppearance.shadowFeather
                ),
                subtitleStyle: TextStylePayload(
                    fontFamily: event.subtitleAppearance.cssFontFamily,
                    fontFaces: fontFacePayloads(for: project, event: event, appearance: event.subtitleAppearance, styleKey: "subtitle"),
                    size: event.subtitleAppearance.size,
                    color: event.subtitleAppearance.colorHex,
                    weightEnabled: event.subtitleAppearance.weightEnabled,
                    weight: event.subtitleAppearance.resolvedWeight,
                    italicEnabled: event.subtitleAppearance.italicEnabled,
                    letterSpacingEnabled: event.subtitleAppearance.letterSpacingEnabled,
                    letterSpacing: event.subtitleAppearance.resolvedLetterSpacing,
                    lineHeightEnabled: event.subtitleAppearance.lineHeightEnabled,
                    lineHeight: event.subtitleAppearance.resolvedLineHeight,
                    shadowEnabled: event.subtitleAppearance.shadowEnabled,
                    shadowStrength: event.subtitleAppearance.shadowStrength,
                    shadowOpacity: event.subtitleAppearance.shadowOpacity,
                    shadowDistance: event.subtitleAppearance.shadowDistance,
                    shadowBlur: event.subtitleAppearance.shadowBlur,
                    shadowFeather: event.subtitleAppearance.shadowFeather
                ),
                slideSeconds: event.secondsPerPhoto,
                transitionSeconds: event.transitionEffect == .none ? 0 : event.transitionDuration,
                playbackOrder: event.playbackOrder.rawValue,
                mediaFitMode: event.mediaFitMode.rawValue,
                imageMotionEffect: event.imageMotionEffect.rawValue,
                kenBurnsDirection: event.kenBurnsDirection.rawValue,
                kenBurnsScalePercent: event.kenBurnsScalePercent,
                kenBurnsFocusMode: event.kenBurnsFocusMode.rawValue,
                transitionEffect: event.transitionEffect.rawValue,
                specialEffect: SpecialEffect.none.rawValue,
                youtubePlaylist: event.mediaSourceKind == .youtubePlaylist
                    ? event.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                logo: logoPayload(for: project, event: event),
                backgroundAudio: backgroundAudioPayload(for: project, event: event),
                items: mediaPayloads(for: project, event: event, capped: freeTierItems?[event.id])
            )
        }

        let newestTimestamp = max(
            project.updatedAt.timeIntervalSince1970,
            scopedEvents.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        )
        let version = "\(project.id.uuidString.lowercased())-\(Int(newestTimestamp * 1000))-\(eventPayloads.map { "\($0.id):\($0.items.count)" }.joined(separator: "|"))"

        let payload = ProjectPayload(
            version: version,
            projectName: project.name,
            projectSubtitle: "",
            eventPlaybackMode: project.eventPlaybackMode.rawValue,
            emptyStateTitle: String(localized: "이벤트에 미디어를 추가해주세요."),
            emptyStateSubtitle: String(localized: "프로젝트 URL 하나로 이벤트 여러 개가 순차, 랜덤 또는 플레이리스트 방식으로 재생됩니다."),
            events: eventPayloads
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            return .binary(data, contentType: "application/json; charset=utf-8")
        } catch {
            return .text("Encoding Error", status: "500 Internal Server Error")
        }
    }

    private func mediaResponse(path: String, request: HTTPRequest) -> HTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count >= 4 else {
            return .text("Bad Request", status: "400 Bad Request")
        }

        let projectID = String(pieces[1])
        let eventID = String(pieces[2])
        let relativeSegments = pieces.dropFirst(3).map { String($0).removingPercentEncoding ?? String($0) }

        guard let (_, event) = projectAndEvent(projectID: projectID, eventID: eventID),
              event.mediaFolderURL != nil else {
            return .text("Not Found", status: "404 Not Found")
        }

        let requestedRelativePath = relativeSegments.joined(separator: "/")
        guard let matchedURL = MediaLibrary.fileURL(for: requestedRelativePath, event: event) else {
            return .text("Not Found", status: "404 Not Found")
        }

        // 사진은 장변 2560 JPEG으로 다운스케일 서빙 — 원본(8~12MB)을 그대로
        // 보내면 브라우저가 매 슬라이드마다 풀 디코딩해 인텔맥에서 히칭이
        // 생긴다. Range 요청은 원본 바이트 오프셋 기준이라 제외한다.
        if request.headers["range"] == nil,
           let resizedURL = ResizedImageCache.resizedFileURL(for: matchedURL) {
            return fileResponse(
                fileURL: resizedURL,
                request: request,
                contentType: "image/jpeg",
                cacheControl: "public, max-age=3600"
            )
        }

        return fileResponse(
            fileURL: matchedURL,
            request: request,
            contentType: Self.mimeType(for: matchedURL.pathExtension),
            cacheControl: "public, max-age=3600"
        )
    }

    private func logoResponse(path: String) -> HTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count >= 4 else {
            return .text("Bad Request", status: "400 Bad Request")
        }

        let projectID = String(pieces[1])
        let eventID = String(pieces[2])
        guard let (_, event) = projectAndEvent(projectID: projectID, eventID: eventID),
              let logoURL = event.logoOverlay.fileURL,
              logoURL.pathExtension.lowercased() == "png",
              let data = try? Data(contentsOf: logoURL, options: [.mappedIfSafe]) else {
            return .text("Not Found", status: "404 Not Found")
        }

        return .binary(data, contentType: "image/png", cacheControl: "public, max-age=3600")
    }

    private func backgroundAudioResponse(path: String, request: HTTPRequest) -> HTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count >= 4 else {
            return .text("Bad Request", status: "400 Bad Request")
        }

        let projectID = String(pieces[1])
        let eventID = String(pieces[2])
        guard let (_, event) = projectAndEvent(projectID: projectID, eventID: eventID),
              let sourceURL = event.backgroundAudio.fileURL else {
            return .text("Not Found", status: "404 Not Found")
        }

        return fileResponse(
            fileURL: sourceURL,
            request: request,
            contentType: Self.mimeType(for: sourceURL.pathExtension),
            cacheControl: "public, max-age=3600"
        )
    }

    private func fileResponse(fileURL: URL, request: HTTPRequest, contentType: String, cacheControl: String) -> HTTPResponse {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return .text("Not Found", status: "404 Not Found")
        }

        let fileSize = max(0, fileSizeNumber.int64Value)
        let acceptRangesHeader = "Accept-Ranges: bytes"

        guard let rangeHeader = request.headers["range"], !rangeHeader.isEmpty else {
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                return .text("Not Found", status: "404 Not Found")
            }

            return .binary(
                data,
                contentType: contentType,
                cacheControl: cacheControl,
                extraHeaders: [acceptRangesHeader]
            )
        }

        guard let range = HTTPByteRange(header: rangeHeader, fileSize: fileSize) else {
            return HTTPResponse(
                status: "416 Range Not Satisfiable",
                contentType: contentType,
                cacheControl: cacheControl,
                body: Data(),
                extraHeaders: [
                    acceptRangesHeader,
                    "Content-Range: bytes */\(fileSize)"
                ]
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .text("Not Found", status: "404 Not Found")
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: UInt64(range.start))
            let chunk = try handle.read(upToCount: Int(range.length)) ?? Data()
            return HTTPResponse(
                status: "206 Partial Content",
                contentType: contentType,
                cacheControl: cacheControl,
                body: chunk,
                extraHeaders: [
                    acceptRangesHeader,
                    "Content-Range: bytes \(range.start)-\(range.end)/\(fileSize)"
                ]
            )
        } catch {
            return .text("Not Found", status: "404 Not Found")
        }
    }

    private func installedFontResponse(path: String) -> HTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count >= 5 else {
            return .text("Bad Request", status: "400 Bad Request")
        }

        let projectID = String(pieces[1])
        let eventID = String(pieces[2])
        let styleKey = String(pieces[3])
        let postScriptName = String(pieces[4]).removingPercentEncoding ?? String(pieces[4])

        guard let (_, event) = projectAndEvent(projectID: projectID, eventID: eventID) else {
            return .text("Not Found", status: "404 Not Found")
        }

        let appearance = styleKey == "subtitle" ? event.subtitleAppearance : event.titleAppearance
        guard let source = fontSources(for: appearance).first(where: { $0.postScriptName == postScriptName }),
              let data = try? Data(contentsOf: source.fileURL) else {
            return .text("Not Found", status: "404 Not Found")
        }

        return .binary(data, contentType: Self.mimeType(for: source.fileURL.pathExtension), cacheControl: "public, max-age=604800, immutable")
    }

    private func staticFontResponse(path: String) -> HTTPResponse {
        let fileName = String(path.dropFirst("/static/fonts/".count))
        let nsFileName = fileName as NSString
        let baseName = nsFileName.deletingPathExtension
        let fileExtension = nsFileName.pathExtension

        guard !baseName.isEmpty, !fileExtension.isEmpty else {
            return .text("Not Found", status: "404 Not Found")
        }

        let data = Self.loadResourceData(named: baseName, withExtension: fileExtension, subdirectory: "fonts")
        guard !data.isEmpty else {
            return .text("Not Found", status: "404 Not Found")
        }

        return .binary(data, contentType: Self.mimeType(for: fileExtension), cacheControl: "public, max-age=604800, immutable")
    }

    private func snapshotProjects() -> [SlideshowProject] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return projectSnapshot
    }

    private func replaceProjectSnapshot(_ projects: [SlideshowProject]) {
        snapshotLock.lock()
        projectSnapshot = projects
        snapshotLock.unlock()
    }

    private func projectAndEvent(projectID: String, eventID: String) -> (SlideshowProject, SlideshowEvent)? {
        guard let project = snapshotProjects().first(where: { $0.id.uuidString.lowercased() == projectID.lowercased() }),
              let event = project.events.first(where: { $0.id.uuidString.lowercased() == eventID.lowercased() }) else {
            return nil
        }
        return (project, event)
    }

    private func fontFacePayloads(for project: SlideshowProject, event: SlideshowEvent, appearance: TextAppearance, styleKey: String) -> [FontFacePayload] {
        let alias = "project-font-\(styleKey)-\(event.id.uuidString.lowercased())"
        return fontSources(for: appearance).map { source in
            FontFacePayload(
                familyAlias: alias,
                postScriptName: source.postScriptName,
                weight: source.weight,
                url: "/_font/\(project.id.uuidString)/\(event.id.uuidString)/\(styleKey)/\(source.postScriptName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.postScriptName)",
                format: Self.cssFontFormat(for: source.fileURL.pathExtension)
            )
        }
    }

    private func fontSources(for appearance: TextAppearance) -> [InstalledFontSource] {
        guard !MacFontCatalog.isBundledWebFont(appearance.resolvedFontFamilyName) else { return [] }

        let importedFaces = MacFontCatalog.importedFontFaces(for: appearance.resolvedFontFamilyName)
        if !importedFaces.isEmpty {
            return importedFaces.map {
                InstalledFontSource(
                    postScriptName: $0.postScriptName,
                    weight: $0.weight,
                    fileURL: $0.fileURL
                )
            }
        }

        return []
    }

    private func mediaPayloads(for project: SlideshowProject, event: SlideshowEvent, capped: [MediaPlaylistItem]? = nil) -> [MediaPayload] {
        (capped ?? MediaLibrary.orderedItems(for: event))
            .map { item in
                let encodedRelativePath = item.relativePath
                    .split(separator: "/")
                    .map { segment in
                        String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String(segment)
                    }
                    .joined(separator: "/")

                return MediaPayload(
                    type: item.kind.rawValue,
                    name: item.name,
                    url: item.fileURL.isFileURL
                        ? "/_media/\(project.id.uuidString)/\(event.id.uuidString)/\(encodedRelativePath)"
                        : item.fileURL.absoluteString,
                    durationSeconds: item.durationSeconds,
                    focusPoint: item.focusPoint.map {
                        FocusPointPayload(
                            x: $0.x,
                            y: $0.y,
                            source: $0.source.rawValue
                        )
                    }
                )
            }
    }

    private func logoPayload(for project: SlideshowProject, event: SlideshowEvent) -> LogoPayload {
        let url: String?
        if let logoURL = event.logoOverlay.fileURL, logoURL.pathExtension.lowercased() == "png" {
            let encodedName = logoURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? logoURL.lastPathComponent
            url = "/_logo/\(project.id.uuidString)/\(event.id.uuidString)/\(encodedName)"
        } else {
            url = nil
        }

        return LogoPayload(
            enabled: event.logoOverlay.enabled,
            url: url,
            position: event.logoOverlay.position.rawValue,
            size: event.logoOverlay.size,
            offsetX: event.logoOverlay.offsetX,
            offsetY: event.logoOverlay.offsetY,
            opacity: event.logoOverlay.opacity
        )
    }

    private func backgroundAudioPayload(for project: SlideshowProject, event: SlideshowEvent) -> BackgroundAudioPayload {
        switch event.backgroundAudio.sourceKind {
        case .none:
            return BackgroundAudioPayload(
                sourceKind: BackgroundAudioSourceKind.none.rawValue,
                url: nil,
                mediaType: nil,
                volume: clampVolume(event.backgroundAudio.volume)
            )
        case .localFile:
            guard let sourceURL = event.backgroundAudio.fileURL else {
                return BackgroundAudioPayload(
                    sourceKind: BackgroundAudioSourceKind.none.rawValue,
                    url: nil,
                    mediaType: nil,
                    volume: clampVolume(event.backgroundAudio.volume)
                )
            }
            let encodedName = sourceURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceURL.lastPathComponent
            return BackgroundAudioPayload(
                sourceKind: BackgroundAudioSourceKind.localFile.rawValue,
                url: "/_audio/\(project.id.uuidString)/\(event.id.uuidString)/\(encodedName)",
                mediaType: Self.backgroundAudioMediaKind(for: sourceURL.pathExtension),
                volume: clampVolume(event.backgroundAudio.volume)
            )
        }
    }

    private func clampVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }


    private static func loadResource(named name: String, withExtension fileExtension: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }

    private static func loadResourceData(named name: String, withExtension fileExtension: String, subdirectory: String? = nil) -> Data {
        // SwiftPM의 .process 규칙은 리소스를 번들 루트로 평탄화할 수 있으므로
        // 하위 폴더 조회가 실패하면 루트에서 한 번 더 찾는다. (예: fonts/*.woff2)
        let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
        guard let url, let data = try? Data(contentsOf: url) else {
            return Data()
        }
        return data
    }

    private static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "oga", "ogg": return "audio/ogg"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf", "ttc": return "font/ttf"
        case "otf", "otc": return "font/otf"
        default: return "application/octet-stream"
        }
    }

    private static func backgroundAudioMediaKind(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp4", "m4v", "mov", "webm":
            return "video"
        default:
            return "audio"
        }
    }

    private static func cssFontFormat(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "woff2": return "woff2"
        case "woff": return "woff"
        case "ttf", "ttc": return "truetype"
        case "otf", "otc": return "opentype"
        default: return "truetype"
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct ProjectPayload: Encodable {
    let version: String
    let projectName: String
    let projectSubtitle: String
    let eventPlaybackMode: String
    let emptyStateTitle: String
    let emptyStateSubtitle: String
    let events: [EventPayload]
}

private struct EventPayload: Encodable {
    let id: String
    let name: String
    let subtitle: String
    let createdAt: TimeInterval
    let projectKind: String
    let title: String
    let displaySubtitle: String
    let textEnabled: Bool
    let textBackgroundEffect: String
    let emptyStateTitle: String
    let emptyStateSubtitle: String
    let overlayPosition: String
    let overlayOffsetX: Double
    let overlayOffsetY: Double
    let titleStyle: TextStylePayload
    let subtitleStyle: TextStylePayload
    let slideSeconds: Double
    let transitionSeconds: Double
    let playbackOrder: String
    let mediaFitMode: String
    let imageMotionEffect: String
    let kenBurnsDirection: String
    let kenBurnsScalePercent: Double
    let kenBurnsFocusMode: String
    let transitionEffect: String
    let specialEffect: String
    let youtubePlaylist: String?
    let logo: LogoPayload
    let backgroundAudio: BackgroundAudioPayload
    let items: [MediaPayload]
}

private struct TextStylePayload: Encodable {
    let fontFamily: String
    let fontFaces: [FontFacePayload]
    let size: Double
    let color: String
    let weightEnabled: Bool
    let weight: Int
    let italicEnabled: Bool
    let letterSpacingEnabled: Bool
    let letterSpacing: Double
    let lineHeightEnabled: Bool
    let lineHeight: Double
    let shadowEnabled: Bool
    let shadowStrength: Double
    let shadowOpacity: Double
    let shadowDistance: Double
    let shadowBlur: Double
    let shadowFeather: Double
}

private struct FontFacePayload: Encodable {
    let familyAlias: String
    let postScriptName: String
    let weight: Int
    let url: String
    let format: String
}

private struct MediaPayload: Encodable {
    let type: String
    let name: String
    let url: String
    let durationSeconds: Double?
    let focusPoint: FocusPointPayload?
}

private struct FocusPointPayload: Encodable {
    let x: Double
    let y: Double
    let source: String
}

private struct LogoPayload: Encodable {
    let enabled: Bool
    let url: String?
    let position: String
    let size: Double
    let offsetX: Double
    let offsetY: Double
    let opacity: Double
}

private struct BackgroundAudioPayload: Encodable {
    let sourceKind: String
    let url: String?
    let mediaType: String?
    let volume: Double
}

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]

    init(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            method = "GET"
            target = "/"
            headers = [:]
            return
        }

        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            method = "GET"
            target = "/"
            headers = [:]
            return
        }

        let parts = firstLine.split(separator: " ")
        method = parts.count > 0 ? String(parts[0]) : "GET"
        target = parts.count > 1 ? String(parts[1]) : "/"
        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                parsedHeaders[key] = value
            }
        }
        headers = parsedHeaders
    }
}

private struct HTTPResponse {
    let status: String
    let contentType: String
    let cacheControl: String
    let body: Data
    let extraHeaders: [String]

    var headerBlock: String {
        (
        [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: \(cacheControl)",
        ] + extraHeaders + [
            "Connection: close",
            "",
            ""
        ]).joined(separator: "\r\n")
    }

    static func html(_ string: String) -> HTTPResponse {
        .binary(Data(string.utf8), contentType: "text/html; charset=utf-8")
    }

    static func text(_ string: String, status: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", cacheControl: "no-store, max-age=0", body: Data(string.utf8), extraHeaders: [])
    }

    static func binary(_ data: Data, contentType: String, cacheControl: String = "no-store, max-age=0", extraHeaders: [String] = []) -> HTTPResponse {
        HTTPResponse(status: "200 OK", contentType: contentType, cacheControl: cacheControl, body: data, extraHeaders: extraHeaders)
    }

    static func empty(status: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", cacheControl: "no-store, max-age=0", body: Data(), extraHeaders: [])
    }
}

private struct HTTPByteRange {
    let start: Int64
    let end: Int64

    var length: Int64 {
        end - start + 1
    }

    init?(header: String, fileSize: Int64) {
        guard header.lowercased().hasPrefix("bytes="), fileSize > 0 else {
            return nil
        }

        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffixLength = Int64(endText), suffixLength > 0 else {
                return nil
            }
            let safeLength = min(suffixLength, fileSize)
            self.start = max(0, fileSize - safeLength)
            self.end = fileSize - 1
            return
        }

        guard let parsedStart = Int64(startText), parsedStart >= 0, parsedStart < fileSize else {
            return nil
        }

        let parsedEnd = endText.isEmpty ? (fileSize - 1) : (Int64(endText) ?? -1)
        guard parsedEnd >= parsedStart else {
            return nil
        }

        self.start = parsedStart
        self.end = min(parsedEnd, fileSize - 1)
    }
}

private struct InstalledFontSource {
    let postScriptName: String
    let weight: Int
    let fileURL: URL
}

/// 슬라이드쇼 주소로 안내할 수 있는 이 맥의 IPv4 주소 하나.
struct ServerHostOption: Identifiable, Hashable {
    enum Kind: Int, Hashable {
        /// 같은 서브넷에 있는 기기가 바로 붙을 수 있는 유선/무선 주소.
        case lan = 0
        /// Tailscale(100.64.0.0/10). 서브넷이 달라도, 밖에 나가 있어도 붙는다.
        case tailscale = 1
        /// 그 밖의 VPN·터널 인터페이스.
        case vpn = 2
        /// 이 맥 안에서만.
        case loopback = 3
    }

    let address: String
    let interfaceName: String
    let kind: Kind

    var id: String { address }

    static let loopback = ServerHostOption(address: "127.0.0.1", interfaceName: "lo0", kind: .loopback)

    var label: String {
        switch kind {
        case .lan: return String(localized: "같은 네트워크") + " · \(address)"
        case .tailscale: return "Tailscale · \(address)"
        case .vpn: return "VPN · \(address)"
        case .loopback: return String(localized: "이 맥에서만") + " · \(address)"
        }
    }
}

enum HostAddressResolver {
    /// AirDrop(awdl/llw/ap)·인터넷 공유(bridge)·가상머신(vmnet) 인터페이스는
    /// 슬라이드쇼 주소로 쓸 일이 없어 목록에서 아예 뺀다.
    private static let hiddenInterfacePrefixes = [
        "awdl", "llw", "ap", "anpi", "bridge", "vmnet", "vnic"
    ]

    /// VPN·터널 인터페이스. 서브넷이 다른 기기나 외부에서 접속할 때 쓸 수 있으니
    /// 목록에는 남기고, 물리 인터페이스보다 뒤로만 민다.
    private static let tunnelInterfacePrefixes = [
        "utun", "ipsec", "ppp", "gif", "stf", "tap", "tun"
    ]

    static func isHidden(interfaceName: String) -> Bool {
        hiddenInterfacePrefixes.contains { interfaceName.hasPrefix($0) }
    }

    /// Tailscale은 CGNAT 대역(100.64.0.0/10)에서 기기마다 고정 주소를 준다.
    static func isTailscaleAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    static func kind(interfaceName: String, address: String) -> ServerHostOption.Kind {
        if isTailscaleAddress(address) { return .tailscale }
        if tunnelInterfacePrefixes.contains(where: { interfaceName.hasPrefix($0) }) { return .vpn }
        return .lan
    }

    /// getifaddrs가 돌려주는 순서는 부팅마다 달라진다. 종류 → 인터페이스 이름 →
    /// 주소 순으로 결정적 정렬해, 구성이 같으면 항상 같은 목록·같은 첫 번째가 되게 한다.
    static func sortedOptions(_ candidates: [(name: String, address: String)]) -> [ServerHostOption] {
        candidates
            .filter { !isHidden(interfaceName: $0.name) }
            .map {
                ServerHostOption(
                    address: $0.address,
                    interfaceName: $0.name,
                    kind: kind(interfaceName: $0.name, address: $0.address)
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                if lhs.interfaceName != rhs.interfaceName { return lhs.interfaceName < rhs.interfaceName }
                return lhs.address < rhs.address
            }
    }

    /// 고른 주소가 아직 살아 있으면 그대로 유지한다 — 맥을 껐다 켜도 URL이 안 바뀌게.
    /// 없어졌을 때만 새로 고르고, 네트워크가 아직 안 올라왔으면 마지막 주소를 계속 보여준다.
    static func preferredPresentationHost(remembered: String?, candidates: [String]) -> String {
        if let remembered, candidates.contains(remembered) { return remembered }
        if let firstNetwork = candidates.first(where: { $0 != ServerHostOption.loopback.address }) {
            return firstNetwork
        }
        return remembered ?? ServerHostOption.loopback.address
    }

    /// 루프백을 뺀, 이 맥의 IPv4 주소 목록.
    static func localHostOptions() -> [ServerHostOption] {
        var candidates: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let firstAddress = pointer else {
            return []
        }

        defer { freeifaddrs(pointer) }

        for interface in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            // 주소가 없는 인터페이스가 반환될 수 있다 — 역참조 전에 반드시 확인.
            guard let interfaceAddress = interface.pointee.ifa_addr else { continue }
            let addressFamily = interfaceAddress.pointee.sa_family
            guard addressFamily == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let interfaceName = String(cString: interface.pointee.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interfaceAddress,
                socklen_t(interfaceAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let addressBytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: addressBytes, as: UTF8.self)
            if !address.isEmpty {
                candidates.append((interfaceName, address))
            }
        }

        return sortedOptions(candidates)
    }
}
