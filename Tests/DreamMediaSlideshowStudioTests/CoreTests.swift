import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import DreamMediaSlideshowStudio

final class ResizedImageCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResizedImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 지정 크기의 테스트 이미지를 만들어 파일로 저장한다.
    private func writeImage(width: Int, height: Int, alpha: Bool, type: UTType, name: String) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let url = tempDir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
    }

    func testLargeJPEGIsDownscaled() throws {
        let original = try writeImage(width: 4000, height: 3000, alpha: false, type: .jpeg, name: "large.jpg")
        let resized = try XCTUnwrap(ResizedImageCache.resizedFileURL(for: original), "4000px JPEG은 리사이즈되어야 한다")
        let size = try pixelSize(of: resized)
        XCTAssertEqual(max(size.width, size.height), ResizedImageCache.maxLongEdge)

        // 두 번째 호출은 같은 캐시 파일을 반환해야 한다
        let second = try XCTUnwrap(ResizedImageCache.resizedFileURL(for: original))
        XCTAssertEqual(resized, second)
    }

    func testSmallImagePassesThrough() throws {
        let original = try writeImage(width: 1920, height: 1080, alpha: false, type: .jpeg, name: "small.jpg")
        XCTAssertNil(ResizedImageCache.resizedFileURL(for: original), "장변 2560 이하는 원본 서빙")
    }

    func testAlphaPNGPassesThrough() throws {
        let original = try writeImage(width: 4000, height: 3000, alpha: true, type: .png, name: "alpha.png")
        XCTAssertNil(ResizedImageCache.resizedFileURL(for: original), "알파 PNG는 JPEG 재인코딩 없이 원본 서빙")
    }

    func testGIFPassesThrough() throws {
        let original = try writeImage(width: 4000, height: 3000, alpha: false, type: .gif, name: "anim.gif")
        XCTAssertNil(ResizedImageCache.resizedFileURL(for: original), "GIF는 애니메이션 보존을 위해 원본 서빙")
    }
}

final class ProjectModelTests: XCTestCase {
    func testProjectJSONRoundTrip() throws {
        var project = SlideshowProject.makeDefault(index: 1, kind: .photo)
        var event = project.events[0]
        event.overlayOffsetX = 12.5
        event.overlayOffsetY = -30
        // displayTitle은 레거시 별칭이라 name과 동기화됨 — name이 저장 대상이다.
        event.name = "테스트 타이틀"
        event.displayTitle = event.name
        project.events[0] = event

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SlideshowProject.self, from: data)

        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.events.count, project.events.count)
        XCTAssertEqual(decoded.events[0].overlayOffsetX, 12.5)
        XCTAssertEqual(decoded.events[0].overlayOffsetY, -30)
        XCTAssertEqual(decoded.events[0].name, "테스트 타이틀")
        XCTAssertEqual(decoded.events[0].displayTitle, "테스트 타이틀")
        XCTAssertEqual(decoded, project)
    }

    func testLegacyJSONWithoutOffsetsDecodesToZero() throws {
        // overlayOffset 키가 없는 구버전 JSON도 0으로 디코딩되어야 한다
        let project = SlideshowProject.makeDefault(index: 1, kind: .photo)
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        var events = try XCTUnwrap(json["events"] as? [[String: Any]])
        events[0].removeValue(forKey: "overlayOffsetX")
        events[0].removeValue(forKey: "overlayOffsetY")
        json["events"] = events

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SlideshowProject.self, from: legacyData)
        XCTAssertEqual(decoded.events[0].overlayOffsetX, 0)
        XCTAssertEqual(decoded.events[0].overlayOffsetY, 0)
    }
}

final class HostAddressResolverTests: XCTestCase {
    /// 실제 이 개발 맥 구성: Wi-Fi + 유선 어댑터(다른 서브넷) + Tailscale + AirDrop.
    private let interfaces = [
        ("utun9", "100.96.130.54"),
        ("en0", "192.168.0.173"),
        ("awdl0", "169.254.31.7"),
        ("en8", "10.0.0.203")
    ]

    func testAirDropAndVirtualInterfacesAreHidden() {
        for name in ["awdl0", "llw0", "bridge100", "vmnet1", "ap1"] {
            XCTAssertTrue(HostAddressResolver.isHidden(interfaceName: name), name)
        }
        for name in ["en0", "en8", "utun9"] {
            XCTAssertFalse(HostAddressResolver.isHidden(interfaceName: name), name)
        }
    }

    func testTailscaleIsOfferedButRankedBelowPhysicalInterfaces() {
        let options = HostAddressResolver.sortedOptions(interfaces)
        XCTAssertEqual(options.map(\.address), ["192.168.0.173", "10.0.0.203", "100.96.130.54"])
        XCTAssertEqual(options.map(\.kind), [.lan, .lan, .tailscale])
    }

    func testOptionOrderIsIndependentOfEnumerationOrder() {
        let shuffled = [interfaces[3], interfaces[1], interfaces[2], interfaces[0]]
        XCTAssertEqual(
            HostAddressResolver.sortedOptions(interfaces).map(\.address),
            HostAddressResolver.sortedOptions(shuffled).map(\.address)
        )
    }

    func testTailscaleRangeDetection() {
        XCTAssertTrue(HostAddressResolver.isTailscaleAddress("100.96.130.54"))
        XCTAssertTrue(HostAddressResolver.isTailscaleAddress("100.64.0.1"))
        XCTAssertFalse(HostAddressResolver.isTailscaleAddress("100.128.0.1"))
        XCTAssertFalse(HostAddressResolver.isTailscaleAddress("100.63.0.1"))
        XCTAssertFalse(HostAddressResolver.isTailscaleAddress("10.0.0.203"))
    }

    func testChosenHostSurvivesRestartWhileAddressExists() {
        let candidates = ["192.168.0.173", "10.0.0.203", "100.96.130.54", "127.0.0.1"]
        for chosen in candidates {
            XCTAssertEqual(
                HostAddressResolver.preferredPresentationHost(remembered: chosen, candidates: candidates),
                chosen
            )
        }
    }

    func testChosenHostIsReplacedOnlyWhenItDisappears() {
        XCTAssertEqual(
            HostAddressResolver.preferredPresentationHost(
                remembered: "10.0.0.203",
                candidates: ["192.168.0.173", "127.0.0.1"]
            ),
            "192.168.0.173"
        )
    }

    func testChosenHostIsKeptWhileNetworkIsStillComingUp() {
        XCTAssertEqual(
            HostAddressResolver.preferredPresentationHost(remembered: "100.96.130.54", candidates: ["127.0.0.1"]),
            "100.96.130.54"
        )
        XCTAssertEqual(
            HostAddressResolver.preferredPresentationHost(remembered: nil, candidates: ["127.0.0.1"]),
            "127.0.0.1"
        )
    }
}
