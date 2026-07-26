import AppKit
import ServiceManagement
import SwiftUI

enum AppPreferenceKeys {
    static let appearanceMode = "app.appearanceMode"
    static let hideOnClose = "app.hideOnClose"
    static let startServerOnLaunch = "app.startServerOnLaunch"
    static let confirmDelete = "app.confirmDeleteBeforeRemove"
    static let showMenuBarExtra = "app.showMenuBarExtra"
    static let launchAtLogin = "app.launchAtLogin"
    static let preventSleep = "app.preventSleepWhileRunning"
    static let runFocusShortcut = "app.runFocusShortcutOnLaunch"
    static let focusShortcutName = "app.focusShortcutName"
}

/// 앱 실행 중 Mac이 잠들지 않도록 전원 어설션을 관리한다.
/// (사이니지 플레이어가 서버에 접속하려면 Mac이 깨어 있어야 한다)
@MainActor
final class SleepPreventionManager {
    static let shared = SleepPreventionManager()
    private var activity: NSObjectProtocol?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "슬라이드쇼 서버 유지"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// 로그인 시 자동 시작 등록 (정식 번들로 실행 중일 때만 동작).
@MainActor
enum LoginItemManager {
    static func setEnabled(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 개발 실행(비번들) 등에서는 실패할 수 있다 — 무해.
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

/// 집중 모드(방해금지)는 공개 API가 없어, 사용자가 만든 단축어를 실행한다.
@MainActor
enum FocusShortcutRunner {
    static func runIfConfigured() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppPreferenceKeys.runFocusShortcut) else { return }
        let name = (defaults.string(forKey: AppPreferenceKeys.focusShortcutName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "시스템")
        case .light: return String(localized: "라이트")
        case .dark: return String(localized: "다크")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단일 인스턴스 강제: 중복 실행되면 한쪽이 포트(8787)를 못 열어
        // 재생 페이지가 옛 인스턴스의 낡은 데이터를 서빙하는 사고가 난다.
        // 이미 실행 중인 인스턴스가 있으면 그쪽을 앞으로 가져오고 종료한다.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [])
                NSApp.terminate(nil)
                return
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configureWindow(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    @objc private func configureWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard !(window is NSPanel) else { return }
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hideOnClose = UserDefaults.standard.object(forKey: AppPreferenceKeys.hideOnClose) as? Bool ?? true
        if hideOnClose {
            NSApp.hide(nil)
            return false
        }
        return true
    }
}

@main
struct DreamMediaSlideshowStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var projectStore: ProjectStore
    @StateObject private var server: LocalSlideshowServer
    @StateObject private var mediaSummaryStore = MediaSummaryStore()
    @StateObject private var proStore = ProStore()
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    init() {
        // 샌드박스에서 이전에 선택한 미디어 폴더/파일 접근을 먼저 복원한다.
        SecurityScopedAccess.activateStoredBookmarks()
        AppFontRegistrar.registerBundledFonts()
        let store = ProjectStore()
        _projectStore = StateObject(wrappedValue: store)
        _server = StateObject(wrappedValue: LocalSlideshowServer(projectStore: store))
    }

    var body: some Scene {
        WindowGroup {
            StudioRootView()
                .environmentObject(projectStore)
                .environmentObject(server)
                .environmentObject(mediaSummaryStore)
                .environmentObject(proStore)
                .preferredColorScheme(resolvedAppearanceMode.colorScheme)
                .frame(minWidth: 1080, minHeight: 740)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 860)
        Settings {
            AppPreferencesView()
                .environmentObject(server)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("권한 설정 다시 하기…") {
                    // 온보딩 완료 플래그를 되돌리면 루트 뷰가 온보딩 시트를 다시 띄운다.
                    UserDefaults.standard.set(false, forKey: OnboardingKeys.completed)
                }
            }
            CommandGroup(after: .newItem) {
                Button("새 사진 프로젝트") {
                    projectStore.createProject(kind: .photo)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canCreateProject)

                Button("새 비디오 프로젝트") {
                    projectStore.createProject(kind: .video)
                }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .disabled(!canCreateProject)
            }
        }
    }

    private var canCreateProject: Bool {
        proStore.isPro || projectStore.projects.count < FreeTierLimits.maxProjects
    }

    private var resolvedAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
}

struct AppPreferencesView: View {
    @EnvironmentObject private var server: LocalSlideshowServer
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @AppStorage(AppPreferenceKeys.hideOnClose) private var hideOnClose = true
    @AppStorage(AppPreferenceKeys.startServerOnLaunch) private var startServerOnLaunch = true
    @AppStorage(AppPreferenceKeys.confirmDelete) private var confirmDeleteBeforeRemove = true
    @AppStorage(AppPreferenceKeys.launchAtLogin) private var launchAtLogin = false
    @AppStorage(AppPreferenceKeys.preventSleep) private var preventSleep = true
    @AppStorage(AppPreferenceKeys.runFocusShortcut) private var runFocusShortcut = false
    @AppStorage(AppPreferenceKeys.focusShortcutName) private var focusShortcutName = ""

    var body: some View {
        Form {
            Picker("테마", selection: $appearanceModeRaw) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }

            Toggle("창 닫기 시 백그라운드로 숨김", isOn: $hideOnClose)
            Toggle("앱 실행 시 서버 자동 시작", isOn: $startServerOnLaunch)
                .onChange(of: startServerOnLaunch) { enabled in
                    if enabled {
                        server.start()
                    } else {
                        server.stop()
                    }
                }
            Toggle("프로젝트 삭제 전 확인", isOn: $confirmDeleteBeforeRemove)

            Section("자동화") {
                Toggle("로그인 시 자동 시작", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        LoginItemManager.setEnabled(enabled)
                    }

                Toggle("앱 실행 중 Mac 잠자기 방지", isOn: $preventSleep)
                    .onChange(of: preventSleep) { enabled in
                        SleepPreventionManager.shared.setEnabled(enabled)
                    }

                Toggle("앱 시작 시 집중 모드 단축어 실행", isOn: $runFocusShortcut)
                TextField("단축어 이름 (예: 방해금지 켜기)", text: $focusShortcutName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!runFocusShortcut)
                Text("단축어 앱에서 \"집중 모드 설정\" 동작으로 단축어를 만들고 그 이름을 입력하세요. 앱이 시작될 때 자동 실행됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("버전")
                Spacer()
                Text(Bundle.main.appVersionText)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 460)
        .onAppear {
            // 시스템 등록 상태와 토글을 동기화
            launchAtLogin = LoginItemManager.isEnabled
        }
    }
}

extension Bundle {
    var appVersionText: String {
        let shortVersion = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(shortVersion) (\(build))"
    }
}
