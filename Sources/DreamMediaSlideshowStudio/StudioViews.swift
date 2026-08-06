import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct StudioRootView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var mediaSummaryStore: MediaSummaryStore
    @EnvironmentObject private var server: LocalSlideshowServer
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppPreferenceKeys.startServerOnLaunch) private var startServerOnLaunch = true
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @AppStorage(OnboardingKeys.completed) private var onboardingCompleted = false
    @State private var sidebarVisible = true
    private let sidebarWidth: CGFloat = 304

    private var selectedProject: SlideshowProject? {
        guard let selectedID = projectStore.selectedProjectID else {
            return nil
        }
        return projectStore.projects.first(where: { $0.id == selectedID })
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 0) {
                if sidebarVisible {
                    // 노션처럼 사이드바를 창 가장자리에 붙이고,
                    // 라운드 패널 대신 면 분할 + 헤어라인으로 구분한다.
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.Surface.subtle)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1)
                        }
                }

                Group {
                    if let project = selectedProject {
                        ProjectWorkspaceView(project: project, sidebarVisible: $sidebarVisible)
                            .id(project.id)
                    } else {
                        EmptyStateView(sidebarVisible: $sidebarVisible)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
                .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: sidebarVisible)
        }
        .onAppear {
            if startServerOnLaunch {
                server.start()
            }
            // 잠자기 방지 (기본 켜짐 — 사이니지 서버 유지)
            let preventSleep = UserDefaults.standard.object(forKey: AppPreferenceKeys.preventSleep) as? Bool ?? true
            SleepPreventionManager.shared.setEnabled(preventSleep)
            // 집중 모드 단축어 자동 실행 (설정 시)
            FocusShortcutRunner.runIfConfigured()
        }
        .onChange(of: startServerOnLaunch) { enabled in
            if enabled {
                server.start()
            } else {
                server.stop()
            }
        }
        // 첫 실행(또는 메뉴 "권한 설정 다시 하기") 시 권한 온보딩 표시
        .sheet(isPresented: Binding(
            get: { !onboardingCompleted },
            set: { onboardingCompleted = !$0 }
        )) {
            OnboardingView()
        }
    }

    private var contentBackground: Color {
        Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.68 : 0.78)
    }

    private var resolvedAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
}

/// 콘텐츠 영역 좌측 상단(노션의 패널 토글 위치)에 놓이는 컨트롤 묶음.
/// 사이드바가 접힌 상태에서는 신호등 버튼을 피해 오른쪽으로 밀려난다.
struct WorkspaceTitlebarControls: View {
    @Binding var sidebarVisible: Bool
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    var body: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: sidebarVisible ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .help(sidebarVisible ? String(localized: "사이드바 접기") : String(localized: "사이드바 펼치기"))

            Button(action: toggleAppearanceMode) {
                Image(systemName: resolvedAppearanceMode == .dark ? "sun.max" : "moon")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .help("라이트/다크 전환")
        }
    }

    private var resolvedAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private func toggleAppearanceMode() {
        appearanceModeRaw = resolvedAppearanceMode == .dark
            ? AppAppearanceMode.light.rawValue
            : AppAppearanceMode.dark.rawValue
    }
}

struct SidebarView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var mediaSummaryStore: MediaSummaryStore
    @EnvironmentObject private var server: LocalSlideshowServer
    @EnvironmentObject private var proStore: ProStore
    @AppStorage(AppPreferenceKeys.confirmDelete) private var confirmDeleteBeforeRemove = true
    @State private var showDeleteAlert = false
    @State private var showUpgradeSheet = false

    private var selectedProject: SlideshowProject? {
        guard let selectedID = projectStore.selectedProjectID else { return nil }
        return projectStore.projects.first(where: { $0.id == selectedID })
    }

    /// 무료 버전 슬라이드 개수 제한 내에서 새 슬라이드를 만들 수 있는지.
    private var canCreateProject: Bool {
        proStore.isPro || projectStore.projects.count < FreeTierLimits.maxProjects
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(.bottom, Theme.Spacing.lg)

            HStack {
                Text("프로젝트")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(projectStore.projects.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(projectStore.projects) { project in
                        SidebarProjectRow(
                            project: project,
                            isSelected: projectStore.selectedProjectID == project.id,
                            onRename: { newValue in
                                projectStore.renameProject(id: project.id, name: newValue)
                            }
                        ) {
                            projectStore.selectedProjectID = project.id
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 12) {
                if let selectedProject {
                    sidebarProjectOverviewCard(for: selectedProject)
                }

                sidebarActionBar

                if !proStore.isPro {
                    Button {
                        showUpgradeSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Pro로 업그레이드")
                            Spacer(minLength: 0)
                            ProBadge()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftControlButtonStyle())
                    .help("무제한 슬라이드·사진·영상")
                }

                Text(Bundle.main.appVersionText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showUpgradeSheet) {
            ProUpgradeView()
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "debug.showUpgradeSheet") {
                showUpgradeSheet = true
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            refreshSelectedProjectSummaries()
        }
        .onChange(of: projectStore.selectedProjectID) { _ in
            refreshSelectedProjectSummaries()
        }
        .onChange(of: projectStore.projects) { _ in
            refreshSelectedProjectSummaries()
        }
        .alert("슬라이드를 삭제할까요?", isPresented: $showDeleteAlert) {
            Button("삭제", role: .destructive) {
                projectStore.deleteSelectedProject()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제한 슬라이드는 되돌릴 수 없습니다.")
        }
    }

    private func runSidebarOperation(_ action: () throws -> Void) {
        do {
            try action()
        } catch let error as ProjectStore.ProjectTransferError {
            guard error != .cancelled else { return }
            presentSidebarAlert(message: error.localizedDescription)
        } catch {
            presentSidebarAlert(message: error.localizedDescription)
        }
    }

    private func presentSidebarAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "작업을 완료할 수 없습니다")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "확인"))
        alert.runModal()
    }

    private func refreshSelectedProjectSummaries() {
        guard let selectedProject else { return }
        for event in selectedProject.events {
            mediaSummaryStore.refresh(for: event)
        }
    }

    @ViewBuilder
    private func sidebarProjectOverviewCard(for project: SlideshowProject) -> some View {
        let summary = projectOverviewSummary(for: project)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("프로젝트 개요")
                    .font(.system(size: 15, weight: .semibold))
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(spacing: 8) {
                SidebarMetricRow(icon: "square.stack.3d.up.fill", title: String(localized: "총 이벤트"), value: "\(summary.eventCount)")
                SidebarMetricRow(icon: "clock.fill", title: String(localized: "총 재생시간"), value: summary.formattedDuration)
                SidebarMetricRow(icon: "photo.fill", title: String(localized: "사진 수"), value: "\(summary.photoCount)")
                SidebarMetricRow(icon: "video.fill", title: String(localized: "비디오 수"), value: "\(summary.videoCount)")
            }
        }
        .padding(12)
        .liquidPanel(cornerRadius: Theme.Radius.card, material: .thinMaterial, shadowStrength: 0.06)
    }

    private func projectOverviewSummary(for project: SlideshowProject) -> ProjectOverviewSummary {
        var photoCount = 0
        var videoCount = 0
        var totalDuration: TimeInterval = 0

        for event in project.events {
            let summary = mediaSummaryStore.summary(for: event.id)
            totalDuration += summary.totalDuration
            switch event.kind {
            case .photo:
                photoCount += summary.itemCount
            case .video:
                videoCount += summary.itemCount
            }
        }

        return ProjectOverviewSummary(
            eventCount: project.events.count,
            photoCount: photoCount,
            videoCount: videoCount,
            totalDuration: totalDuration
        )
    }

    @ViewBuilder
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 노션처럼 신호등 버튼 바로 옆에 앱 아이콘과 이름을 배치한다.
            // (신호등은 네이티브 오버레이라 그 폭만큼 왼쪽을 비워 둔다.)
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Photo Slide Studio")
                    .font(.system(size: 15, weight: .bold))
                if proStore.isPro {
                    ProBadge()
                } else {
                    FreeBadge()
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 86)
            .padding(.top, 6)
            .frame(height: 30)

            HStack(spacing: 6) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(server.isRunning ? String(localized: "서버 실행 중 · 포트 \(String(server.port))") : String(localized: "서버 중지됨"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var sidebarActionBar: some View {
        VStack(spacing: 8) {
            Button {
                if canCreateProject {
                    projectStore.createProject(kind: .photo)
                } else {
                    showUpgradeSheet = true
                }
            } label: {
                HStack(spacing: 6) {
                    Label("새 슬라이드", systemImage: "plus")
                    if !canCreateProject {
                        ProBadge()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftControlButtonStyle(tone: .accent))
            .accessibilityLabel("새 슬라이드")

            HStack(spacing: 8) {
                Button {
                    if canCreateProject {
                        projectStore.duplicateSelectedProject()
                    } else {
                        showUpgradeSheet = true
                    }
                } label: {
                    Label("복제", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SoftControlButtonStyle())
                .disabled(projectStore.selectedProjectID == nil)
                .help(canCreateProject ? String(localized: "복제") : String(localized: "복제 — Pro에서 무제한"))
                .accessibilityLabel("복제")

                Button {
                    if canCreateProject {
                        runSidebarOperation {
                            _ = try projectStore.importProjectFromJSON()
                        }
                    } else {
                        showUpgradeSheet = true
                    }
                } label: {
                    Label("불러오기", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SoftControlButtonStyle())
                .help(canCreateProject ? String(localized: "불러오기") : String(localized: "불러오기 — Pro에서 무제한"))
                .accessibilityLabel("불러오기")

                Button {
                    runSidebarOperation {
                        _ = try projectStore.exportSelectedProjectToJSON()
                    }
                } label: {
                    Label("내보내기", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SoftControlButtonStyle())
                .disabled(projectStore.selectedProjectID == nil)
                .help("내보내기")
                .accessibilityLabel("내보내기")

                Button(role: .destructive) {
                    if confirmDeleteBeforeRemove {
                        showDeleteAlert = true
                    } else {
                        projectStore.deleteSelectedProject()
                    }
                } label: {
                    Label("삭제", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SoftControlButtonStyle(tone: .destructive))
                .disabled(projectStore.selectedProjectID == nil)
                .help("삭제")
                .accessibilityLabel("삭제")
            }
        }
    }
}

struct ProjectWorkspaceView: View {
    enum WorkspaceTab: String, CaseIterable, Identifiable, Hashable {
        case events
        case text
        case logo
        case media
        case playback

        var id: String { rawValue }

        var title: String {
            switch self {
            case .events: return String(localized: "이벤트")
            case .text: return String(localized: "텍스트")
            case .logo: return String(localized: "로고")
            case .media: return String(localized: "미디어")
            case .playback: return String(localized: "재생")
            }
        }

        var iconName: String {
            switch self {
            case .events: return "list.bullet.rectangle"
            case .text: return "textformat"
            case .logo: return "seal"
            case .media: return "photo.on.rectangle"
            case .playback: return "play.square"
            }
        }
    }

    enum BackgroundAudioStatus: Equatable {
        case disabled
        case localReady
        case localMissing

        var title: String {
            switch self {
            case .disabled: return String(localized: "배경음악 꺼짐")
            case .localReady: return String(localized: "로컬 파일 준비됨")
            case .localMissing: return String(localized: "로컬 파일 없음")
            }
        }

        var subtitle: String {
            switch self {
            case .disabled:
                return String(localized: "현재 이벤트에서는 배경음악이 비활성화되어 있습니다.")
            case .localReady:
                return String(localized: "선택한 로컬 mp3/mp4 파일이 반복 재생됩니다.")
            case .localMissing:
                return String(localized: "파일 경로가 비어 있거나 현재 접근할 수 없습니다.")
            }
        }

        var symbolName: String {
            switch self {
            case .disabled: return "speaker.slash.fill"
            case .localReady: return "checkmark.circle.fill"
            case .localMissing: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .disabled: return .secondary
            case .localReady: return .green
            case .localMissing: return .orange
            }
        }
    }

    let projectID: SlideshowProject.ID
    @Binding var sidebarVisible: Bool

    @State private var project: SlideshowProject
    @State private var selectedEventID: SlideshowEvent.ID?
    @State private var activeTab: WorkspaceTab = Self.initialTab
    @State private var previewVersion = UUID().uuidString
    @State private var fontLibraryRefreshToken = UUID()
    @State private var draggedEventID: SlideshowEvent.ID?
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var commitTask: Task<Void, Never>?
    @State private var backgroundAudioStatusTask: Task<Void, Never>?
    @State private var previewShowsEntireProject = false
    @State private var previewMuted = false
    @State private var backgroundAudioStatus: BackgroundAudioStatus = .disabled

    /// 개발/검증용: `defaults write <bundle-id> debug.initialTab <rawValue>`로 시작 탭 지정.
    private static var initialTab: WorkspaceTab {
        if let raw = UserDefaults.standard.string(forKey: "debug.initialTab"),
           let tab = WorkspaceTab(rawValue: raw) {
            return tab
        }
        return .events
    }

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var server: LocalSlideshowServer
    @EnvironmentObject private var mediaSummaryStore: MediaSummaryStore
    @EnvironmentObject private var proStore: ProStore
    @AppStorage("previewEnabled") private var previewEnabled = false
    @AppStorage("previewPortrait") private var previewPortrait = false
    @State private var showUpgradeSheet = false

    /// 무료 버전 재생 제한(사진 10장·영상 1개)을 넘는 미디어가 연결됐는지.
    /// 서버 측 제한과 동일하게 프로젝트 전체 이벤트 합산으로 판단한다.
    private var freeTierMediaLimitExceeded: Bool {
        guard !proStore.isPro else { return false }
        var photoCount = 0
        var videoCount = 0
        for event in project.events {
            let count = mediaSummaryStore.summary(for: event.id).itemCount
            switch event.kind {
            case .photo: photoCount += count
            case .video: videoCount += count
            }
        }
        return photoCount > FreeTierLimits.maxPhotosPerProject
            || videoCount > FreeTierLimits.maxVideosPerProject
    }

    private static let supportedImageMotionEffects: [ImageMotionEffect] = [.none, .kenBurns]
    private static let supportedTransitionEffects: [TransitionEffect] = [
        .none, .crossfade, .slideLeft, .slideRight, .slideUp, .slideDown
    ]

    init(project: SlideshowProject, sidebarVisible: Binding<Bool>) {
        projectID = project.id
        _sidebarVisible = sidebarVisible
        _project = State(initialValue: project)
        _selectedEventID = State(initialValue: project.events.first?.id)
    }

    private var selectedEventIndex: Int? {
        guard let selectedEventID else { return nil }
        return project.events.firstIndex(where: { $0.id == selectedEventID })
    }

    private var selectedEvent: SlideshowEvent? {
        guard let selectedEventIndex else { return nil }
        return project.events[selectedEventIndex]
    }

    private var mediaSummary: MediaPlaybackSummary {
        guard let selectedEventID else {
            return MediaPlaybackSummary(itemCount: 0, totalDuration: 0)
        }
        return mediaSummaryStore.summary(for: selectedEventID)
    }

    private var backgroundAudioStatusKey: String {
        guard let event = selectedEvent else { return "none" }
        return [
            event.id.uuidString,
            event.backgroundAudio.sourceKind.rawValue,
            event.backgroundAudio.filePath
        ].joined(separator: "|")
    }

    private var browserPreviewURL: URL? {
        guard let baseURL = server.previewURL(for: project),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { ["previewScope", "eventID", "previewMuted", "previewDebug"].contains($0.name) })
        queryItems.append(URLQueryItem(name: "previewScope", value: previewShowsEntireProject ? "playlist" : "selected"))
        if !previewShowsEntireProject, let selectedEventID {
            queryItems.append(URLQueryItem(name: "eventID", value: selectedEventID.uuidString))
        }
        queryItems.append(URLQueryItem(name: "previewMuted", value: previewMuted ? "1" : "0"))
        components.queryItems = queryItems
        return components.url
    }

    private var appPreviewURL: URL? {
        guard var components = URLComponents(url: browserPreviewURL ?? URL(string: "about:blank")!, resolvingAgainstBaseURL: false),
              components.scheme != "about" else {
            return browserPreviewURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { $0.name == "previewDebug" })
        queryItems.append(URLQueryItem(name: "previewDebug", value: "1"))
        components.queryItems = queryItems
        return components.url
    }

    private var presentationURL: URL? {
        server.presentationURL(for: project)
    }

    var body: some View {
        GeometryReader { geometry in
            let editorColumnWidth = min(max(geometry.size.width * 0.34, 420), 560)

            // 프리뷰는 우측에 항상 고정. 왼쪽 메뉴(탭 콘텐츠)만 독립적으로
            // 스크롤되고, 탭바는 전체 폭 상단에 고정되어 탭을 오가도 프리뷰가 유지된다.
            VStack(alignment: .leading, spacing: 14) {
                inspectorTabBar

                HStack(alignment: .top, spacing: 12) {
                    ScrollView(.vertical) {
                        inspectorCard(compactLayout: true)
                            .padding(.bottom, 24)
                    }
                    .frame(width: editorColumnWidth)

                    ScrollView(.vertical) {
                        previewColumn(compactLayout: false)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                }
            }
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            normalizeSelectedEventIfNeeded()
            normalizeFontSelectionsIfNeeded()
            normalizeProjectEventsIfNeeded()
            normalizePlaybackSelectionsIfNeeded()
            refreshSelectedEventSummary()
            scheduleBackgroundAudioStatusRefresh()
            if previewEnabled {
                server.start()
                refreshPreviewNow()
            }
        }
        .onDisappear {
            previewRefreshTask?.cancel()
            backgroundAudioStatusTask?.cancel()
            commitProjectNow()
        }
        .onChange(of: selectedEventID) { _ in
            normalizeSelectedEventIfNeeded()
            normalizeFontSelectionsIfNeeded()
            normalizeProjectEventsIfNeeded()
            normalizePlaybackSelectionsIfNeeded()
            refreshSelectedEventSummary()
            scheduleBackgroundAudioStatusRefresh()
            schedulePreviewRefresh()
        }
        .onChange(of: backgroundAudioStatusKey) { _ in
            scheduleBackgroundAudioStatusRefresh()
        }
        .onChange(of: previewEnabled) { enabled in
            if enabled {
                server.start()
                refreshPreviewNow()
            } else {
                previewRefreshTask?.cancel()
            }
        }
        .onChange(of: previewShowsEntireProject) { _ in
            schedulePreviewRefresh()
        }
        .sheet(isPresented: $showUpgradeSheet) {
            ProUpgradeView()
        }
        .onChange(of: previewMuted) { _ in
            schedulePreviewRefresh()
        }
        .onReceive(projectStore.$projects) { projects in
            guard let latest = projects.first(where: { $0.id == projectID }) else { return }
            if project.name != latest.name {
                project.name = latest.name
            }
            scheduleBackgroundAudioStatusRefresh()
        }
    }

    private func previewColumn(compactLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            previewCard
            linkCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var backgroundAudioStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: backgroundAudioStatus.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(backgroundAudioStatus.tint)
                .frame(width: 28, height: 28)
                .background(backgroundAudioStatus.tint.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(backgroundAudioStatus.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(backgroundAudioStatus.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.Surface.fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var cardTitle: String {
        let event = selectedEvent
        switch activeTab {
        case .events: return String(localized: "이벤트 관리")
        case .text: return String(localized: "이벤트 텍스트")
        case .logo: return String(localized: "로고 오버레이")
        case .media: return event?.kind.sourceLabel ?? String(localized: "미디어")
        case .playback: return String(localized: "재생 옵션")
        }
    }

    private var cardSubtitle: String {
        switch activeTab {
        case .events:
            return String(localized: "이벤트를 생성, 복제, 삭제하고 플레이리스트 순서와 슬라이드 재생 방식을 설정합니다.")
        case .text:
            return String(localized: "선택한 이벤트의 이름과 서브타이틀이 실제 슬라이드 자막으로 표시됩니다.")
        case .logo:
            return String(localized: "PNG 로고를 화면 위에 올리고 위치, 크기, 투명도를 조정합니다.")
        case .media:
            return (selectedEvent?.kind ?? .photo) == .photo
                ? String(localized: "사진 폴더 또는 클라우드 공유링크를 연결합니다.")
                : String(localized: "비디오 폴더 또는 클라우드 공유링크를 연결합니다.")
        case .playback:
            return String(localized: "선택한 이벤트의 재생 순서, 슬라이드 스타일, 트랜지션을 설정합니다.")
        }
    }

    private func inspectorCard(compactLayout: Bool) -> some View {
        WorkspaceCard(title: cardTitle, subtitle: cardSubtitle) {
            VStack(alignment: .leading, spacing: 16) {
                if showsTabReset {
                    resetActiveTabButton
                }

                activeContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: compactLayout ? nil : .infinity,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var inspectorTabBar: some View {
        HStack(spacing: 14) {
            WorkspaceTitlebarControls(sidebarVisible: $sidebarVisible)
                .padding(.leading, sidebarVisible ? 0 : 64)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Button {
                            activeTab = tab
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(tab.title)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(activeTab == tab ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .fill(activeTab == tab ? Color.accentColor : Theme.Surface.fill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .stroke(activeTab == tab ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .liquidPanel(cornerRadius: Theme.Radius.panel, material: .thinMaterial, shadowStrength: 0.08)
    }

    private var showsTabReset: Bool {
        switch activeTab {
        case .events:
            return false
        case .text, .logo, .media, .playback:
            return true
        }
    }

    private var activeContent: some View {
        // 활성 탭만 렌더링한다. 방문한 탭을 전부 살려두면(ZStack + opacity 0)
        // 슬라이더 틱·키 입력 등 모든 상태 변경마다 숨은 탭까지 재평가/레이아웃되어
        // 조작감이 무거워진다. 탭 전환 시 재구성 비용이 훨씬 싸다.
        activeTabContent(for: activeTab)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var textPositionField: some View {
        LabeledField(title: String(localized: "텍스트 위치")) {
            Picker("", selection: eventBinding(\.overlayPosition, default: .topRight)) {
                ForEach(OverlayPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textOffsetFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SliderRow(title: String(localized: "가로 이동"), value: eventBinding(\.overlayOffsetX, default: 0), range: -400...400, step: 0.5, suffix: "px")
                Stepper("", value: eventBinding(\.overlayOffsetX, default: 0), in: -400...400, step: 0.5)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                SliderRow(title: String(localized: "세로 이동"), value: eventBinding(\.overlayOffsetY, default: 0), range: -400...400, step: 0.5, suffix: "px")
                Stepper("", value: eventBinding(\.overlayOffsetY, default: 0), in: -400...400, step: 0.5)
                    .labelsHidden()
            }
        }
    }

    private var textBackgroundEffectField: some View {
        LabeledField(title: String(localized: "텍스트 배경 이펙트")) {
            Picker("", selection: eventBinding(\.textBackgroundEffect, default: .blurBar)) {
                ForEach(TextBackgroundEffect.allCases) { effect in
                    Text(effect.title).tag(effect)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fontLibrarySection: some View {
        WorkspaceInlineSection(title: String(localized: "폰트 라이브러리"), subtitle: String(localized: "앱 안에 포함된 폰트를 추가하거나 관리합니다.")) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    importFontButton
                    openFontFolderButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    importFontButton
                    openFontFolderButton
                }
            }
        }
    }

    @ViewBuilder
    private func activeTabContent(for tab: WorkspaceTab) -> some View {
        switch tab {
        case .events:
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        eventManagementButtons
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            addPhotoEventButton
                            duplicateEventButton
                        }
                        HStack(spacing: 10) {
                            addVideoEventButton
                            deleteEventButton
                        }
                    }
                }

                LabeledField(title: String(localized: "이벤트 재생 방식")) {
                    Picker("", selection: projectBinding(\.eventPlaybackMode, refreshPreview: true)) {
                        ForEach(EventPlaybackMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Button("선택 이벤트 전체 초기화") {
                    resetSelectedEvent()
                }
                .buttonStyle(.bordered)
                .disabled(selectedEvent == nil)

                Divider()

                WorkspaceInlineSection(title: String(localized: "이벤트 플레이리스트"), subtitle: String(localized: "이벤트를 드래그해서 순서를 자유롭게 바꾸고 재생 순서를 구성합니다.")) {
                    if project.events.isEmpty {
                        Text("이벤트가 없습니다. 새 이벤트를 추가해주세요.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(project.events.enumerated()), id: \.element.id) { offset, event in
                                WorkspaceEventRow(
                                    index: offset + 1,
                                    event: event,
                                    isSelected: selectedEventID == event.id,
                                    onRename: { newName in
                                        renameEvent(id: event.id, to: newName)
                                    },
                                    action: {
                                        selectedEventID = event.id
                                    }
                                )
                                .onDrag {
                                    draggedEventID = event.id
                                    return NSItemProvider(object: event.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: EventPlaylistDropDelegate(
                                        targetEventID: event.id,
                                        events: $project.events,
                                        draggedEventID: $draggedEventID,
                                        selectedEventID: $selectedEventID,
                                        onCommit: {
                                            markUpdated()
                                        }
                                    )
                                )
                            }
                        }
                    }
                }
            }

        case .text:
            VStack(alignment: .leading, spacing: 14) {
                // 공통 설정: 표시 여부 · 위치 · 배경 이펙트
                WorkspaceInlineSection(title: String(localized: "이벤트 텍스트"), subtitle: String(localized: "이벤트 이름과 서브타이틀, 텍스트 위치를 설정합니다.")) {
                    Toggle("텍스트 표시", isOn: eventBinding(\.textOverlayEnabled, default: true))
                        .toggleStyle(.switch)
                        .disabled(selectedEvent == nil)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            textPositionField
                            textBackgroundEffectField
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            textPositionField
                            textBackgroundEffectField
                        }
                    }

                    textOffsetFields
                }

                // 제목: 입력 → 스타일 → 드랍쉐도우를 한 흐름으로 편집
                WorkspaceInlineSection(title: String(localized: "제목"), subtitle: String(localized: "제목을 입력하고 이어서 스타일과 드랍쉐도우까지 설정합니다.")) {
                    LabeledField(title: String(localized: "이벤트 이름")) {
                        TextField("화면 제목", text: eventBinding(\.name, default: ""))
                            .textFieldStyle(.roundedBorder)
                    }

                    TypographyControlGroup(
                        heading: String(localized: "스타일"),
                        fontFamilyName: eventNestedBinding(\.titleAppearance, \.fontFamilyName, default: "Pretendard Variable"),
                        size: eventNestedBinding(\.titleAppearance, \.size, default: 50),
                        colorHex: eventNestedBinding(\.titleAppearance, \.colorHex, default: "#FFFFFF"),
                        weightEnabled: eventNestedBinding(\.titleAppearance, \.weightEnabled, default: true),
                        weight: eventNestedBinding(\.titleAppearance, \.weight, default: 800),
                        italicEnabled: eventNestedBinding(\.titleAppearance, \.italicEnabled, default: false),
                        letterSpacingEnabled: eventNestedBinding(\.titleAppearance, \.letterSpacingEnabled, default: false),
                        letterSpacing: eventNestedBinding(\.titleAppearance, \.letterSpacing, default: -1.5),
                        lineHeightEnabled: eventNestedBinding(\.titleAppearance, \.lineHeightEnabled, default: false),
                        lineHeight: eventNestedBinding(\.titleAppearance, \.lineHeight, default: 0.92),
                        shadowEnabled: eventNestedBinding(\.titleAppearance, \.shadowEnabled, default: true),
                        shadowStrength: eventNestedBinding(\.titleAppearance, \.shadowStrength, default: 0.36),
                        shadowOpacity: eventNestedBinding(\.titleAppearance, \.shadowOpacity, default: 0.42),
                        shadowDistance: eventNestedBinding(\.titleAppearance, \.shadowDistance, default: 20),
                        shadowBlur: eventNestedBinding(\.titleAppearance, \.shadowBlur, default: 34),
                        shadowFeather: eventNestedBinding(\.titleAppearance, \.shadowFeather, default: 14),
                        sizeRange: 1...200,
                        showsShadowControls: false
                    )
                    .id("title-\(fontLibraryRefreshToken.uuidString)")

                    ShadowControlGroup(
                        heading: String(localized: "드랍쉐도우"),
                        shadowEnabled: eventNestedBinding(\.titleAppearance, \.shadowEnabled, default: true),
                        shadowStrength: eventNestedBinding(\.titleAppearance, \.shadowStrength, default: 0.36),
                        shadowOpacity: eventNestedBinding(\.titleAppearance, \.shadowOpacity, default: 0.42),
                        shadowDistance: eventNestedBinding(\.titleAppearance, \.shadowDistance, default: 20),
                        shadowBlur: eventNestedBinding(\.titleAppearance, \.shadowBlur, default: 34),
                        shadowFeather: eventNestedBinding(\.titleAppearance, \.shadowFeather, default: 14)
                    )
                }

                // 서브타이틀: 입력 → 스타일 → 드랍쉐도우
                WorkspaceInlineSection(title: String(localized: "서브타이틀"), subtitle: String(localized: "서브타이틀을 입력하고 이어서 스타일과 드랍쉐도우까지 설정합니다.")) {
                    LabeledField(title: String(localized: "서브타이틀")) {
                        TextField("화면 소제목", text: eventBinding(\.subtitle, default: ""))
                            .textFieldStyle(.roundedBorder)
                    }

                    TypographyControlGroup(
                        heading: String(localized: "스타일"),
                        fontFamilyName: eventNestedBinding(\.subtitleAppearance, \.fontFamilyName, default: "Pretendard Variable"),
                        size: eventNestedBinding(\.subtitleAppearance, \.size, default: 30),
                        colorHex: eventNestedBinding(\.subtitleAppearance, \.colorHex, default: "#FFFFFF"),
                        weightEnabled: eventNestedBinding(\.subtitleAppearance, \.weightEnabled, default: true),
                        weight: eventNestedBinding(\.subtitleAppearance, \.weight, default: 600),
                        italicEnabled: eventNestedBinding(\.subtitleAppearance, \.italicEnabled, default: false),
                        letterSpacingEnabled: eventNestedBinding(\.subtitleAppearance, \.letterSpacingEnabled, default: false),
                        letterSpacing: eventNestedBinding(\.subtitleAppearance, \.letterSpacing, default: -0.6),
                        lineHeightEnabled: eventNestedBinding(\.subtitleAppearance, \.lineHeightEnabled, default: false),
                        lineHeight: eventNestedBinding(\.subtitleAppearance, \.lineHeight, default: 1.18),
                        shadowEnabled: eventNestedBinding(\.subtitleAppearance, \.shadowEnabled, default: true),
                        shadowStrength: eventNestedBinding(\.subtitleAppearance, \.shadowStrength, default: 0.28),
                        shadowOpacity: eventNestedBinding(\.subtitleAppearance, \.shadowOpacity, default: 0.34),
                        shadowDistance: eventNestedBinding(\.subtitleAppearance, \.shadowDistance, default: 12),
                        shadowBlur: eventNestedBinding(\.subtitleAppearance, \.shadowBlur, default: 24),
                        shadowFeather: eventNestedBinding(\.subtitleAppearance, \.shadowFeather, default: 10),
                        sizeRange: 1...200,
                        showsShadowControls: false
                    )
                    .id("subtitle-\(fontLibraryRefreshToken.uuidString)")

                    ShadowControlGroup(
                        heading: String(localized: "드랍쉐도우"),
                        shadowEnabled: eventNestedBinding(\.subtitleAppearance, \.shadowEnabled, default: true),
                        shadowStrength: eventNestedBinding(\.subtitleAppearance, \.shadowStrength, default: 0.28),
                        shadowOpacity: eventNestedBinding(\.subtitleAppearance, \.shadowOpacity, default: 0.34),
                        shadowDistance: eventNestedBinding(\.subtitleAppearance, \.shadowDistance, default: 12),
                        shadowBlur: eventNestedBinding(\.subtitleAppearance, \.shadowBlur, default: 24),
                        shadowFeather: eventNestedBinding(\.subtitleAppearance, \.shadowFeather, default: 10)
                    )
                }

                // 폰트 라이브러리 (제목/서브타이틀 공용)
                fontLibrarySection
            }

        case .logo:
            VStack(alignment: .leading, spacing: 14) {
                Toggle("로고 표시", isOn: eventNestedBinding(\.logoOverlay, \.enabled, default: false))
                    .toggleStyle(.switch)

                Text((selectedEvent?.logoOverlay.filePath ?? "").isEmpty ? String(localized: "선택된 PNG 로고가 없습니다.") : (selectedEvent?.logoOverlay.filePath ?? ""))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle((selectedEvent?.logoOverlay.filePath ?? "").isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.Surface.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        logoActionButtons
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        logoActionButtons
                    }
                }

                LabeledField(title: String(localized: "로고 위치")) {
                    Picker("", selection: eventNestedBinding(\.logoOverlay, \.position, default: .topRight)) {
                        ForEach(OverlayPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SliderRow(title: String(localized: "로고 크기"), value: eventNestedBinding(\.logoOverlay, \.size, default: 160), range: 60...420, suffix: "px")
                SliderRow(title: String(localized: "가로 이동"), value: eventNestedBinding(\.logoOverlay, \.offsetX, default: 0), range: -400...400, suffix: "px")
                SliderRow(title: String(localized: "세로 이동"), value: eventNestedBinding(\.logoOverlay, \.offsetY, default: 0), range: -400...400, suffix: "px")
                SliderRow(
                    title: String(localized: "투명도"),
                    value: Binding(get: {
                        (selectedEvent?.logoOverlay.opacity ?? 1) * 100
                    }, set: { newValue in
                        updateSelectedEvent(refreshPreview: true) { event in
                            event.logoOverlay.opacity = newValue / 100
                        }
                    }),
                    range: 0...100,
                    suffix: "%"
                )
            }

        case .media:
            VStack(alignment: .leading, spacing: 14) {
                if (selectedEvent?.mediaSourceKind ?? .localFolder) == .localFolder {
                    HStack(spacing: 10) {
                        SummaryChip(label: (selectedEvent?.kind ?? .photo) == .photo ? String(localized: "사진 수") : String(localized: "비디오 수"), value: "\(mediaSummary.itemCount)\((selectedEvent?.kind ?? .photo) == .photo ? String(localized: "장") : String(localized: "개"))")
                        SummaryChip(label: String(localized: "총 재생시간"), value: mediaSummary.formattedDuration)
                    }
                }

                if freeTierMediaLimitExceeded {
                    FreeTierLimitBanner {
                        showUpgradeSheet = true
                    }
                }

                LabeledField(title: String(localized: "소스 유형")) {
                    Picker("", selection: eventBinding(\.mediaSourceKind, default: .localFolder, refreshSummary: true)) {
                        ForEach(MediaSourceKind.allCases) { sourceKind in
                            Text(sourceKind.title).tag(sourceKind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if (selectedEvent?.mediaSourceKind ?? .localFolder) == .localFolder {
                    Text((selectedEvent?.mediaFolderPath ?? "").isEmpty ? String(localized: "선택된 폴더가 없습니다.") : (selectedEvent?.mediaFolderPath ?? ""))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle((selectedEvent?.mediaFolderPath ?? "").isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.Surface.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            localMediaButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            localMediaButtons
                        }
                    }
                } else {
                    TextField("유튜브 재생목록 링크를 붙여넣으세요", text: eventBinding(\.cloudSourceURL, default: "", refreshSummary: true))
                        .textFieldStyle(.roundedBorder)

                    Text((selectedEvent?.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                         ? String(localized: "유튜브 재생목록 링크(list= 포함)를 넣으면 재생목록의 영상이 순서대로 재생됩니다. 이 이벤트가 유일한 항목이면 재생목록이 무한 반복됩니다.")
                         : (selectedEvent?.cloudSourceURL ?? ""))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle((selectedEvent?.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.Surface.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            cloudMediaButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            cloudMediaButtons
                        }
                    }
                }

                Divider()

                WorkspaceInlineSection(title: String(localized: "배경음악"), subtitle: String(localized: "로컬 mp3/mp4 파일을 이벤트 배경음으로 무한 루프 재생합니다.")) {
                    LabeledField(title: String(localized: "배경음악 소스")) {
                        Picker("", selection: eventNestedBinding(\.backgroundAudio, \.sourceKind, default: .none)) {
                            ForEach(BackgroundAudioSourceKind.allCases) { sourceKind in
                                Text(sourceKind.title).tag(sourceKind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    backgroundAudioStatusCard

                    switch selectedEvent?.backgroundAudio.sourceKind ?? .none {
                    case .none:
                        Text("배경음악이 꺼져 있습니다.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                    case .localFile:
                        Text((selectedEvent?.backgroundAudio.filePath ?? "").isEmpty ? String(localized: "선택된 배경음악 파일이 없습니다.") : (selectedEvent?.backgroundAudio.filePath ?? ""))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle((selectedEvent?.backgroundAudio.filePath ?? "").isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.Surface.fill)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                localBackgroundAudioButtons
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                localBackgroundAudioButtons
                            }
                        }
                    }

                    SliderRow(
                        title: String(localized: "볼륨"),
                        value: Binding(
                            get: { (selectedEvent?.backgroundAudio.volume ?? 0.72) * 100 },
                            set: { newValue in
                                updateSelectedEvent(refreshPreview: true) { event in
                                    event.backgroundAudio.volume = newValue / 100
                                }
                            }
                        ),
                        range: 0...100,
                        step: 1,
                        suffix: "%",
                        decimals: 0
                    )

                    Text("배경음악은 이벤트가 바뀔 때 해당 이벤트 기준으로 교체되고, 같은 이벤트 안에서는 계속 반복됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .playback:
            VStack(alignment: .leading, spacing: 14) {
                LabeledField(title: String(localized: "재생 순서")) {
                    Picker("", selection: eventBinding(\.playbackOrder, default: .random, refreshSummary: true)) {
                        ForEach(PlaybackOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SliderRow(title: String(localized: "사진당 표시 시간"), value: eventBinding(\.secondsPerPhoto, default: 8, refreshSummary: true), range: 0.5...30, step: 0.5, suffix: String(localized: "초"))

                LabeledField(title: String(localized: "비율 설정")) {
                    Picker("", selection: eventBinding(\.mediaFitMode, default: .fill)) {
                        ForEach(MediaFitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                LabeledField(title: String(localized: "슬라이드 스타일")) {
                    Picker("", selection: eventBinding(\.imageMotionEffect, default: .kenBurns)) {
                        ForEach(Self.supportedImageMotionEffects) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if selectedEvent?.imageMotionEffect == .kenBurns {
                    HStack(alignment: .top, spacing: 12) {
                        LabeledField(title: String(localized: "줌 방향")) {
                            Picker("", selection: eventBinding(\.kenBurnsDirection, default: .zoomIn)) {
                                ForEach(KenBurnsDirection.allCases) { direction in
                                    Text(direction.title).tag(direction)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        LabeledField(title: String(localized: "범위")) {
                            Picker("", selection: eventBinding(\.kenBurnsFocusMode, default: .center)) {
                                ForEach(KenBurnsFocusMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    SliderRow(
                        title: String(localized: "줌 비율"),
                        value: Binding(
                            get: {
                                guard let selectedEvent else { return 3 }
                                return min(max(selectedEvent.kenBurnsScalePercent, 0), 20)
                            },
                            set: { newValue in
                                updateSelectedEvent(refreshPreview: true) { event in
                                    event.kenBurnsScalePercent = newValue
                                }
                            }
                        ),
                        range: 0...20,
                        step: 0.5,
                        suffix: "%",
                        decimals: 1
                    )
                }

                LabeledField(title: String(localized: "트랜지션")) {
                    Picker("", selection: eventBinding(\.transitionEffect, default: .crossfade)) {
                        ForEach(Self.supportedTransitionEffects) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SliderRow(
                    title: String(localized: "트랜지션 시간"),
                    value: Binding(
                        get: {
                            guard let selectedEvent else { return 1.4 }
                            return max(selectedEvent.transitionDuration, 0.2)
                        },
                        set: { newValue in
                            updateSelectedEvent(refreshPreview: true) { event in
                                event.transitionDuration = newValue
                            }
                        }
                    ),
                    range: 0.2...max(0.2, min(4.0, selectedEvent?.secondsPerPhoto ?? 4.0)),
                    suffix: String(localized: "초")
                )
            }
        }
    }

    private var previewCard: some View {
        WorkspaceCard(title: String(localized: "실시간 미리보기"), subtitle: String(localized: "실제 웹 출력과 같은 결과를 확인합니다.")) {
            VStack(alignment: .leading, spacing: 14) {
                previewControlStrip
                previewInfoStrip

                Group {
                    if previewEnabled, let appPreviewURL {
                        WebPreviewView(
                            url: appPreviewURL,
                            reloadToken: previewVersion,
                            referenceSize: previewPortrait ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("프리뷰가 꺼져 있습니다.")
                                .font(.headline)
                            Text("필요할 때만 프리뷰를 켜서 앱 리소스를 줄일 수 있습니다.")
                                .foregroundStyle(.secondary)
                            Text("기본값은 선택한 이벤트만 미리보기하고, 전체 프리뷰 보기를 켜면 플레이리스트 전체를 재생합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.primary.opacity(0.04))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .aspectRatio(previewPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                // 세로(9:16)에서는 컨테이너가 가로로 남지 않도록 프리뷰 크기에 맞춰 수축시킨다.
                .frame(
                    maxWidth: previewPortrait ? 380 : .infinity,
                    maxHeight: previewPortrait ? 676 : nil,
                    alignment: .topLeading
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var previewInfoStrip: some View {
        if let selectedEvent {
            let isKenBurns = selectedEvent.imageMotionEffect == .kenBurns

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    SummaryChip(label: String(localized: "모션"), value: selectedEvent.imageMotionEffect.title)
                    if isKenBurns {
                        SummaryChip(label: String(localized: "줌"), value: selectedEvent.kenBurnsDirection.title)
                        SummaryChip(label: String(localized: "깊이"), value: formattedPercent(selectedEvent.kenBurnsScalePercent))
                        SummaryChip(label: String(localized: "범위"), value: selectedEvent.kenBurnsFocusMode.title)
                    }
                    SummaryChip(
                        label: String(localized: "트랜지션"),
                        value: "\(selectedEvent.transitionEffect.title) · \(formattedSeconds(selectedEvent.transitionDuration))"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SummaryChip(label: String(localized: "모션"), value: selectedEvent.imageMotionEffect.title)
                        SummaryChip(
                            label: String(localized: "트랜지션"),
                            value: "\(selectedEvent.transitionEffect.title) · \(formattedSeconds(selectedEvent.transitionDuration))"
                        )
                    }

                    if isKenBurns {
                        HStack(spacing: 8) {
                            SummaryChip(label: String(localized: "줌"), value: selectedEvent.kenBurnsDirection.title)
                            SummaryChip(label: String(localized: "깊이"), value: formattedPercent(selectedEvent.kenBurnsScalePercent))
                            SummaryChip(label: String(localized: "범위"), value: selectedEvent.kenBurnsFocusMode.title)
                        }
                    }
                }
            }
        }
    }

    private var previewControlStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Toggle("프리뷰", isOn: $previewEnabled)
                    .toggleStyle(.switch)

                Toggle("전체", isOn: $previewShowsEntireProject)
                    .toggleStyle(.switch)
                    .disabled(!previewEnabled)

                Toggle("뮤트", isOn: $previewMuted)
                    .toggleStyle(.switch)
                    .disabled(!previewEnabled)

                Toggle("세로", isOn: $previewPortrait)
                    .toggleStyle(.switch)
                    .disabled(!previewEnabled)
                    .help("9:16 세로 화면으로 미리보기")

                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("프리뷰", isOn: $previewEnabled)
                    .toggleStyle(.switch)

                HStack(spacing: 12) {
                    Toggle("전체", isOn: $previewShowsEntireProject)
                        .toggleStyle(.switch)
                        .disabled(!previewEnabled)

                    Toggle("뮤트", isOn: $previewMuted)
                        .toggleStyle(.switch)
                        .disabled(!previewEnabled)

                    Toggle("세로", isOn: $previewPortrait)
                        .toggleStyle(.switch)
                        .disabled(!previewEnabled)
                }
            }
        }
        .padding(12)
        .background(Theme.Surface.fill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var linkCard: some View {
        WorkspaceCard(title: "Links", subtitle: String(localized: "브라우저 뷰와 OptiSigns용 주소입니다.")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("브라우저 뷰 URL")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("보기") {
                            openPreviewURL()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(browserPreviewURL == nil)

                        Button("복사") {
                            copyPreviewURL()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(browserPreviewURL == nil)
                        .accessibilityLabel(String(localized: "브라우저 뷰 URL 복사"))
                    }
                }
                AddressField(title: "OptiSigns URL", value: presentationURL?.absoluteString ?? "", showsValue: false, actionTitle: String(localized: "복사"), actionAccessibilityLabel: String(localized: "OptiSigns URL 복사")) {
                    copyPresentationURL()
                }
                Text("브라우저 뷰에는 전체화면 버튼과 프리뷰용 뮤트 설정이 적용되고, OptiSigns URL에서는 버튼이 숨겨집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitProjectMetadataOnly() {
        project.touch()
        scheduleProjectCommit()
    }

    private func markUpdated() {
        if let selectedEventIndex {
            project.events[selectedEventIndex].touch()
        }
        project.touch()
        scheduleProjectCommit()
        schedulePreviewRefresh()
    }

    private func copyPreviewURL() {
        guard let browserPreviewURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(browserPreviewURL.absoluteString, forType: .string)
    }

    private func formattedPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func formattedSeconds(_ value: Double) -> String {
        String(format: String(localized: "%.1f초"), value)
    }

    private func openPreviewURL() {
        guard let browserPreviewURL else { return }
        NSWorkspace.shared.open(browserPreviewURL)
    }

    @ViewBuilder
    private var addPhotoEventButton: some View {
        Button {
            addEvent(kind: .photo)
        } label: {
            Label("새 사진 이벤트", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    @ViewBuilder
    private var addVideoEventButton: some View {
        Button {
            addEvent(kind: .video)
        } label: {
            Label("새 비디오 이벤트", systemImage: "film")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    @ViewBuilder
    private var duplicateEventButton: some View {
        Button {
            duplicateSelectedEvent()
        } label: {
            Label("복제", systemImage: "plus.square.on.square")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedEvent == nil)
    }

    @ViewBuilder
    private var deleteEventButton: some View {
        Button(role: .destructive) {
            deleteSelectedEvent()
        } label: {
            Label("삭제", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(project.events.count <= 1 || selectedEvent == nil)
    }

    @ViewBuilder
    private var eventManagementButtons: some View {
        addPhotoEventButton
        duplicateEventButton
        addVideoEventButton
        deleteEventButton
    }

    @ViewBuilder
    private var resetActiveTabButton: some View {
        Button("현재 탭 초기화") {
            resetActiveTab()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedEvent == nil)
    }

    @ViewBuilder
    private var importFontButton: some View {
        Button {
            do {
                let imported = try projectStore.importFontFiles()
                if let first = imported.first, let selectedEventIndex, !MacFontCatalog.containsFamily(project.events[selectedEventIndex].titleAppearance.fontFamilyName) {
                    project.events[selectedEventIndex].titleAppearance.fontFamilyName = first
                }
                if let first = imported.first, let selectedEventIndex, !MacFontCatalog.containsFamily(project.events[selectedEventIndex].subtitleAppearance.fontFamilyName) {
                    project.events[selectedEventIndex].subtitleAppearance.fontFamilyName = first
                }
                fontLibraryRefreshToken = UUID()
                markUpdated()
            } catch let error as ProjectStore.ProjectTransferError {
                guard error != .cancelled else { return }
                presentWorkspaceAlert(message: error.localizedDescription)
            } catch {
                presentWorkspaceAlert(message: error.localizedDescription)
            }
        } label: {
            Label("폰트 추가", systemImage: "plus.rectangle.on.folder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    @ViewBuilder
    private var openFontFolderButton: some View {
        Button("폰트 폴더 열기") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: MacFontCatalog.importedFontsDirectoryURL().path)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var logoActionButtons: some View {
        Button {
            if let selectedPath = projectStore.chooseLogoFilePath() {
                updateSelectedEvent(refreshPreview: true) { event in
                    event.logoOverlay.filePath = selectedPath
                    if !event.logoOverlay.enabled {
                        event.logoOverlay.enabled = true
                    }
                }
            }
        } label: {
            Label("PNG 로고 선택", systemImage: "photo")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Finder에서 보기") {
            guard let fileURL = selectedEvent?.logoOverlay.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedEvent?.logoOverlay.fileURL == nil)

        Button("비우기") {
            updateSelectedEvent(refreshPreview: true) { event in
                event.logoOverlay.filePath = ""
                event.logoOverlay.enabled = false
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled((selectedEvent?.logoOverlay.filePath ?? "").isEmpty)
    }

    @ViewBuilder
    private var localMediaButtons: some View {
        Button {
            if let selectedPath = projectStore.chooseMediaFolderPath() {
                updateSelectedEvent(refreshPreview: true, refreshSummary: true) { event in
                    event.mediaFolderPath = selectedPath
                }
            }
        } label: {
            Label((selectedEvent?.kind ?? .photo).sourceLabel + " 선택", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("폴더 열기") {
            guard let mediaFolderPath = selectedEvent?.mediaFolderPath, !mediaFolderPath.isEmpty else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mediaFolderPath)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled((selectedEvent?.mediaFolderPath ?? "").isEmpty)

        Button("비우기") {
            updateSelectedEvent(refreshPreview: true, refreshSummary: true) { event in
                event.mediaFolderPath = ""
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled((selectedEvent?.mediaFolderPath ?? "").isEmpty)
    }

    @ViewBuilder
    private var cloudMediaButtons: some View {
        Button("링크 열기") {
            guard let raw = selectedEvent?.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw) else { return }
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(URL(string: selectedEvent?.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == nil)

        Button("비우기") {
            updateSelectedEvent(refreshPreview: true, refreshSummary: true) { event in
                event.cloudSourceURL = ""
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled((selectedEvent?.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty)
    }

    @ViewBuilder
    private var localBackgroundAudioButtons: some View {
        Button {
            if let selectedPath = projectStore.chooseBackgroundAudioFilePath() {
                updateSelectedEvent(refreshPreview: true) { event in
                    event.backgroundAudio.filePath = selectedPath
                    event.backgroundAudio.sourceKind = .localFile
                }
            }
        } label: {
            Label("배경음악 파일 선택", systemImage: "music.note")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Finder에서 보기") {
            guard let fileURL = selectedEvent?.backgroundAudio.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedEvent?.backgroundAudio.fileURL == nil)

        Button("비우기") {
            updateSelectedEvent(refreshPreview: true) { event in
                event.backgroundAudio.filePath = ""
                event.backgroundAudio.sourceKind = .none
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled((selectedEvent?.backgroundAudio.filePath ?? "").isEmpty)
    }

    private func copyPresentationURL() {
        guard let presentationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(presentationURL.absoluteString, forType: .string)
    }

    private func openPresentationURL() {
        guard let presentationURL else { return }
        NSWorkspace.shared.open(presentationURL)
    }

    private func refreshPreviewNow() {
        previewRefreshTask?.cancel()
        previewVersion = UUID().uuidString
    }

    private func commitProjectNow() {
        commitTask?.cancel()
        projectStore.save(project: project)
    }

    private func scheduleProjectCommit(delay: Duration = .milliseconds(450)) {
        commitTask?.cancel()
        let snapshot = project
        commitTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                projectStore.save(project: snapshot)
            }
        }
    }

    private func schedulePreviewRefresh(delay: Duration = .milliseconds(120)) {
        guard previewEnabled else { return }
        previewRefreshTask?.cancel()
        previewRefreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewVersion = UUID().uuidString
            }
        }
    }

    private func presentWorkspaceAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "작업을 완료할 수 없습니다")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "확인"))
        alert.runModal()
    }

    private func normalizeFontSelectionsIfNeeded() {
        let availableFamilies = MacFontCatalog.availableFamilies()
        guard let fallback = availableFamilies.first else { return }
        guard let selectedEventIndex else { return }

        var didChange = false
        if !MacFontCatalog.containsFamily(project.events[selectedEventIndex].titleAppearance.fontFamilyName) {
            project.events[selectedEventIndex].titleAppearance.fontFamilyName = fallback
            didChange = true
        }
        if !MacFontCatalog.containsFamily(project.events[selectedEventIndex].subtitleAppearance.fontFamilyName) {
            project.events[selectedEventIndex].subtitleAppearance.fontFamilyName = fallback
            didChange = true
        }

        if didChange {
            markUpdated()
        }
    }

    private func normalizePlaybackSelectionsIfNeeded() {
        guard let selectedEventIndex else { return }

        var didChange = false
        if !Self.supportedImageMotionEffects.contains(project.events[selectedEventIndex].imageMotionEffect) {
            project.events[selectedEventIndex].imageMotionEffect = .kenBurns
            didChange = true
        }
        if !Self.supportedTransitionEffects.contains(project.events[selectedEventIndex].transitionEffect) {
            project.events[selectedEventIndex].transitionEffect = .crossfade
            didChange = true
        }
        if project.events[selectedEventIndex].specialEffect != .none {
            project.events[selectedEventIndex].specialEffect = .none
            didChange = true
        }
        let clampedSeconds = min(max(project.events[selectedEventIndex].secondsPerPhoto, 0.5), 30)
        if project.events[selectedEventIndex].secondsPerPhoto != clampedSeconds {
            project.events[selectedEventIndex].secondsPerPhoto = clampedSeconds
            didChange = true
        }
        if project.events[selectedEventIndex].transitionDuration < 0.6 {
            project.events[selectedEventIndex].transitionDuration = 1.4
            didChange = true
        }
        let clampedKenBurnsPercent = min(max(project.events[selectedEventIndex].kenBurnsScalePercent, 0), 20)
        if project.events[selectedEventIndex].kenBurnsScalePercent != clampedKenBurnsPercent {
            project.events[selectedEventIndex].kenBurnsScalePercent = clampedKenBurnsPercent
            didChange = true
        }

        if didChange {
            markUpdated()
        }
    }

    private func normalizedPlaybackEvent(_ event: SlideshowEvent) -> SlideshowEvent {
        var normalized = event

        if !Self.supportedImageMotionEffects.contains(normalized.imageMotionEffect) {
            normalized.imageMotionEffect = .kenBurns
        }
        if !Self.supportedTransitionEffects.contains(normalized.transitionEffect) {
            normalized.transitionEffect = .crossfade
        }
        if normalized.specialEffect != .none {
            normalized.specialEffect = .none
        }

        normalized.secondsPerPhoto = min(max(normalized.secondsPerPhoto, 0.5), 30)
        // 트랜지션은 사진 표시 시간(=전환 주기)보다 길 수 없다 —
        // 표시 시간을 줄이면 트랜지션 시간도 자동으로 따라 줄어든다.
        let transitionCap = min(4.0, normalized.secondsPerPhoto)
        normalized.transitionDuration = min(max(normalized.transitionDuration, 0.2), transitionCap)
        normalized.kenBurnsScalePercent = min(max(normalized.kenBurnsScalePercent, 0), 20)

        return normalized
    }

    private func normalizeProjectEventsIfNeeded() {
        var didChange = false

        for index in project.events.indices {
            let current = project.events[index]
            let normalized = normalizedPlaybackEvent(current)
            if current != normalized {
                project.events[index] = normalized
                project.events[index].touch()
                didChange = true
            }
        }

        if didChange {
            project.touch()
            scheduleProjectCommit()
            schedulePreviewRefresh()
        }
    }

    private func normalizeSelectedEventIfNeeded() {
        if let selectedEventID,
           project.events.contains(where: { $0.id == selectedEventID }) {
            return
        }
        selectedEventID = project.events.first?.id
    }

    private func refreshSelectedEventSummary() {
        guard let selectedEvent else { return }
        mediaSummaryStore.refresh(for: selectedEvent)
    }

    private func addEvent(kind: ProjectKind) {
        let index = (project.events.filter { $0.kind == kind }.count) + 1
        var event = SlideshowEvent.makeDefault(index: index, kind: kind)
        event.specialEffect = .none
        project.events.append(event)
        selectedEventID = event.id
        markUpdated()
        refreshSelectedEventSummary()
    }

    private func resetSelectedEvent() {
        guard let selectedEventIndex else { return }
        let current = project.events[selectedEventIndex]
        let reset = resetEvent(current, keepingID: true, for: selectedEventIndex)
        project.events[selectedEventIndex] = reset
        selectedEventID = reset.id
        markUpdated()
        refreshSelectedEventSummary()
    }

    private func resetActiveTab() {
        guard let selectedEventIndex else { return }
        let current = project.events[selectedEventIndex]
        let defaults = defaultEventTemplate(for: selectedEventIndex, kind: current.kind)
        var updated = current

        switch activeTab {
        case .events:
            return
        case .text:
            updated.name = defaults.name
            updated.subtitle = defaults.subtitle
            updated.displayTitle = defaults.displayTitle
            updated.displaySubtitle = defaults.displaySubtitle
            updated.textOverlayEnabled = defaults.textOverlayEnabled
            updated.textBackgroundEffect = defaults.textBackgroundEffect
            updated.overlayPosition = defaults.overlayPosition
            updated.overlayOffsetX = defaults.overlayOffsetX
            updated.overlayOffsetY = defaults.overlayOffsetY
            updated.titleAppearance = defaults.titleAppearance
            updated.subtitleAppearance = defaults.subtitleAppearance
        case .logo:
            updated.logoOverlay = defaults.logoOverlay
        case .media:
            updated.mediaSourceKind = defaults.mediaSourceKind
            updated.mediaFolderPath = defaults.mediaFolderPath
            updated.cloudSourceURL = defaults.cloudSourceURL
            updated.backgroundAudio = defaults.backgroundAudio
        case .playback:
            updated.playbackOrder = defaults.playbackOrder
            updated.mediaFitMode = defaults.mediaFitMode
            updated.secondsPerPhoto = defaults.secondsPerPhoto
            updated.transitionDuration = defaults.transitionDuration
            updated.imageMotionEffect = defaults.imageMotionEffect
            updated.transitionEffect = defaults.transitionEffect
            updated.specialEffect = defaults.specialEffect
        }

        updated.touch()
        project.events[selectedEventIndex] = updated
        project.touch()
        scheduleProjectCommit()
        schedulePreviewRefresh()
        refreshSelectedEventSummary()
    }

    private func duplicateSelectedEvent() {
        guard let selectedEvent else { return }
        let duplicate = selectedEvent.duplicated(defaultName: uniqueEventName(basedOn: "\(selectedEvent.name) Copy"))
        project.events.append(duplicate)
        selectedEventID = duplicate.id
        markUpdated()
        refreshSelectedEventSummary()
    }

    private func deleteSelectedEvent() {
        guard let selectedEventIndex, project.events.count > 1 else { return }
        project.events.remove(at: selectedEventIndex)
        let fallbackIndex = min(selectedEventIndex, project.events.count - 1)
        selectedEventID = project.events[safe: fallbackIndex]?.id
        markUpdated()
        refreshSelectedEventSummary()
    }

    private func uniqueEventName(basedOn source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Event" : trimmed
        let taken = Set(project.events.map { $0.name.lowercased() })
        guard taken.contains(baseName.lowercased()) else { return baseName }
        var suffix = 2
        while taken.contains("\(baseName) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func defaultEventTemplate(for index: Int, kind: ProjectKind) -> SlideshowEvent {
        SlideshowEvent.makeDefault(index: index + 1, kind: kind)
    }

    private func resetEvent(_ event: SlideshowEvent, keepingID: Bool, for index: Int) -> SlideshowEvent {
        var defaults = defaultEventTemplate(for: index, kind: event.kind)
        if keepingID {
            defaults = SlideshowEvent(
                id: event.id,
                kind: defaults.kind,
                name: defaults.name,
                subtitle: defaults.subtitle,
                displayTitle: defaults.displayTitle,
                displaySubtitle: defaults.displaySubtitle,
                textOverlayEnabled: defaults.textOverlayEnabled,
                textBackgroundEffect: defaults.textBackgroundEffect,
                overlayPosition: defaults.overlayPosition,
                overlayOffsetX: defaults.overlayOffsetX,
                overlayOffsetY: defaults.overlayOffsetY,
                titleAppearance: defaults.titleAppearance,
                subtitleAppearance: defaults.subtitleAppearance,
                logoOverlay: defaults.logoOverlay,
                backgroundAudio: defaults.backgroundAudio,
                mediaSourceKind: defaults.mediaSourceKind,
                mediaFolderPath: defaults.mediaFolderPath,
                cloudSourceURL: defaults.cloudSourceURL,
                playbackOrder: defaults.playbackOrder,
                mediaFitMode: defaults.mediaFitMode,
                secondsPerPhoto: defaults.secondsPerPhoto,
                transitionDuration: defaults.transitionDuration,
                imageMotionEffect: defaults.imageMotionEffect,
                kenBurnsDirection: defaults.kenBurnsDirection,
                kenBurnsScalePercent: defaults.kenBurnsScalePercent,
                kenBurnsFocusMode: defaults.kenBurnsFocusMode,
                transitionEffect: defaults.transitionEffect,
                specialEffect: defaults.specialEffect,
                createdAt: event.createdAt,
                updatedAt: Date()
            )
        }
        return defaults
    }

    private func projectBinding<T>(_ keyPath: WritableKeyPath<SlideshowProject, T>, refreshPreview: Bool = true, refreshSummary: Bool = false) -> Binding<T> {
        Binding(
            get: {
                project[keyPath: keyPath]
            },
            set: { newValue in
                project[keyPath: keyPath] = newValue
                project.touch()
                scheduleProjectCommit()
                if refreshPreview {
                    schedulePreviewRefresh()
                }
                if refreshSummary {
                    refreshSelectedEventSummary()
                }
            }
        )
    }

    private func eventBinding<T>(_ keyPath: WritableKeyPath<SlideshowEvent, T>, default defaultValue: T, refreshSummary: Bool = false, refreshPreview: Bool = true) -> Binding<T> {
        Binding(
            get: {
                guard let selectedEventIndex else { return defaultValue }
                return project.events[selectedEventIndex][keyPath: keyPath]
            },
            set: { newValue in
                updateSelectedEvent(refreshPreview: refreshPreview, refreshSummary: refreshSummary) { event in
                    event[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func eventNestedBinding<T, Value>(_ rootKeyPath: WritableKeyPath<SlideshowEvent, T>, _ nestedKeyPath: WritableKeyPath<T, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: {
                guard let selectedEventIndex else { return defaultValue }
                return project.events[selectedEventIndex][keyPath: rootKeyPath][keyPath: nestedKeyPath]
            },
            set: { newValue in
                updateSelectedEvent(refreshPreview: true, refreshSummary: false) { event in
                    event[keyPath: rootKeyPath][keyPath: nestedKeyPath] = newValue
                }
            }
        )
    }

    private func scheduleBackgroundAudioStatusRefresh() {
        backgroundAudioStatusTask?.cancel()

        guard let event = selectedEvent else {
            backgroundAudioStatus = .disabled
            return
        }

        switch event.backgroundAudio.sourceKind {
        case .none:
            backgroundAudioStatus = .disabled
        case .localFile:
            guard let fileURL = event.backgroundAudio.fileURL else {
                backgroundAudioStatus = .localMissing
                return
            }
            // 파일 존재 확인은 디스크/NAS IO라 메인 스레드에서 하면
            // 이벤트·프로젝트 클릭이 IO 시간만큼 막힌다 — 백그라운드에서 확인.
            backgroundAudioStatusTask = Task.detached(priority: .utility) {
                let exists = FileManager.default.fileExists(atPath: fileURL.path)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    backgroundAudioStatus = exists ? .localReady : .localMissing
                }
            }
        }
    }

    /// 플레이리스트 행에서 이벤트 이름을 직접 변경한다.
    private func renameEvent(id: SlideshowEvent.ID, to newName: String) {
        guard let index = project.events.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, project.events[index].name != trimmed else { return }
        project.events[index].name = trimmed
        project.events[index].touch()
        project.touch()
        scheduleProjectCommit()
        schedulePreviewRefresh()
    }

    private func updateSelectedEvent(refreshPreview: Bool, refreshSummary: Bool = false, _ update: (inout SlideshowEvent) -> Void) {
        guard let selectedEventIndex else { return }
        update(&project.events[selectedEventIndex])
        project.events[selectedEventIndex] = normalizedPlaybackEvent(project.events[selectedEventIndex])
        project.events[selectedEventIndex].touch()
        project.touch()
        if refreshPreview {
            // 프리뷰 리로드(120ms)가 커밋 디바운스(450ms)보다 먼저 실행되면
            // 서버가 아직 옛 설정을 서빙해 "다음 변경 때에야 반영"되는 문제가 생긴다.
            // 프리뷰를 갱신할 변경은 즉시 커밋한다(디스크 저장은 스토어가 자체 디바운스).
            commitProjectNow()
            schedulePreviewRefresh()
        } else {
            scheduleProjectCommit()
        }
        if refreshSummary {
            refreshSelectedEventSummary()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @Binding var sidebarVisible: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("새 슬라이드를 시작하세요.")
                .font(.system(size: 34, weight: .bold))
            Text("슬라이드를 만든 뒤 사진 폴더를 선택하고, 화면에 보일 텍스트를 별도로 설정하면 됩니다.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button {
                    projectStore.createProject(kind: .photo)
                } label: {
                    Label("새 슬라이드", systemImage: "plus")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .overlay(alignment: .topLeading) {
            WorkspaceTitlebarControls(sidebarVisible: $sidebarVisible)
                .padding(.leading, sidebarVisible ? 14 : 78)
                .padding(.top, 14)
        }
    }
}

struct WorkspaceCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(20)
        .liquidPanel(cornerRadius: Theme.Radius.panel, material: .regularMaterial, shadowStrength: 0.1)
    }
}

struct SidebarProjectRow: View {
    let project: SlideshowProject
    let isSelected: Bool
    let onRename: (String) -> Void
    let action: () -> Void

    @State private var draftProjectName = ""
    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(project.slug)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isRenaming {
                        // 테두리 없는(plain) 텍스트필드는 배경 드래그로 창을 옮기는 설정과
                        // 충돌해 클릭이 먹히지 않는다 — 편집 중에만 테두리 필드를 띄운다.
                        TextField("슬라이드 이름", text: $draftProjectName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14, weight: .semibold))
                            .focused($nameFieldFocused)
                            .onSubmit {
                                commitProjectName()
                                isRenaming = false
                            }
                            .onAppear {
                                nameFieldFocused = true
                            }
                    } else {
                        Text(project.name)
                            .font(.system(size: 15, weight: .semibold))
                            .multilineTextAlignment(.leading)
                        if isSelected {
                            // 이름 변경 진입점: 연필을 누르면 편집 필드가 열린다.
                            Button {
                                draftProjectName = project.name
                                isRenaming = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.Surface.fill)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("이름 변경")
                        }
                    }
                    Text("\(project.events.count) 이벤트")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background((isSelected ? Color.accentColor.opacity(0.12) : Theme.Surface.fill))
                        .clipShape(Capsule())
                }
                Text("/p/\(project.slug)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture {
            // 선택된 행에서는 탭이 편집 필드/연필 클릭을 방해하지 않도록 한다.
            if !isSelected {
                action()
            }
        }
        // 이름 변경 중에는 텍스트필드가 개별 요소로 남아야 하므로 병합하지 않는다.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            if !isSelected {
                action()
            }
        }
        .onChange(of: nameFieldFocused) { focused in
            if !focused && isRenaming {
                commitProjectName()
                isRenaming = false
            }
        }
        .onChange(of: isSelected) { selected in
            if !selected {
                isRenaming = false
            }
        }
    }

    private func commitProjectName() {
        let trimmedName = draftProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != project.name else { return }
        onRename(trimmedName)
    }
}

struct WorkspaceEventRow: View {
    let index: Int
    let event: SlideshowEvent
    let isSelected: Bool
    let onRename: (String) -> Void
    let action: () -> Void

    @State private var draftEventName = ""
    @State private var isRenaming = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 30, height: 30)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isRenaming {
                        TextField("이벤트 이름", text: $draftEventName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($nameFieldFocused)
                            .onSubmit {
                                commitEventName()
                                isRenaming = false
                            }
                            .onAppear {
                                nameFieldFocused = true
                            }
                    } else {
                        Text(event.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        if isSelected {
                            Button {
                                draftEventName = event.name
                                isRenaming = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.Surface.fill)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("이름 변경")
                        }
                    }
                    Text(event.kind.shortTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background((isSelected ? Color.accentColor.opacity(0.12) : Theme.Surface.fill))
                        .clipShape(Capsule())
                }

                Text(event.subtitle.isEmpty ? String(localized: "서브타이틀 없음") : event.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Theme.Surface.subtle)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture {
            // 선택된 행에서는 탭이 편집 필드/연필 클릭을 방해하지 않도록 한다.
            if !isSelected {
                action()
            }
        }
        // 이름 변경 중에는 텍스트필드가 개별 요소로 남아야 하므로 병합하지 않는다.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            if !isSelected {
                action()
            }
        }
        .onChange(of: nameFieldFocused) { focused in
            if !focused && isRenaming {
                commitEventName()
                isRenaming = false
            }
        }
        .onChange(of: isSelected) { selected in
            if !selected {
                isRenaming = false
            }
        }
    }

    private func commitEventName() {
        let trimmedName = draftEventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != event.name else { return }
        onRename(trimmedName)
    }
}

struct EventPlaylistDropDelegate: DropDelegate {
    let targetEventID: SlideshowEvent.ID
    @Binding var events: [SlideshowEvent]
    @Binding var draggedEventID: SlideshowEvent.ID?
    @Binding var selectedEventID: SlideshowEvent.ID?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedEventID,
              draggedEventID != targetEventID,
              let fromIndex = events.firstIndex(where: { $0.id == draggedEventID }),
              let toIndex = events.firstIndex(where: { $0.id == targetEventID }) else {
            return
        }

        withAnimation(.spring(duration: 0.24)) {
            events.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        selectedEventID = draggedEventID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedEventID = nil
        onCommit()
        return true
    }

    func dropExited(info: DropInfo) {}
}

struct StatusBadge: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Surface.fill)
        .clipShape(Capsule())
    }
}

struct SummaryChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Surface.fill)
        .clipShape(Capsule())
    }
}

private struct ProjectOverviewSummary {
    let eventCount: Int
    let photoCount: Int
    let videoCount: Int
    let totalDuration: TimeInterval

    var formattedDuration: String {
        let totalSeconds = max(Int(totalDuration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct SidebarMetricRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SidebarMetricCard: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.Surface.fill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct WorkspaceInlineSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .liquidPanel(cornerRadius: Theme.Radius.card, material: .thinMaterial, shadowStrength: 0.06)
    }
}

struct TypographyControlGroup: View {
    let heading: String
    @Binding var fontFamilyName: String
    @Binding var size: Double
    @Binding var colorHex: String
    @Binding var weightEnabled: Bool
    @Binding var weight: Int
    @Binding var italicEnabled: Bool
    @Binding var letterSpacingEnabled: Bool
    @Binding var letterSpacing: Double
    @Binding var lineHeightEnabled: Bool
    @Binding var lineHeight: Double
    @Binding var shadowEnabled: Bool
    @Binding var shadowStrength: Double
    @Binding var shadowOpacity: Double
    @Binding var shadowDistance: Double
    @Binding var shadowBlur: Double
    @Binding var shadowFeather: Double
    let sizeRange: ClosedRange<Double>
    let showsShadowControls: Bool

    private var families: [String] { MacFontCatalog.availableFamilies() }
    private let weights = [100, 200, 300, 400, 500, 600, 700, 800, 900]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.system(size: 15, weight: .semibold))

            LabeledField(title: String(localized: "폰트")) {
                Picker("폰트", selection: $fontFamilyName) {
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            LabeledField(title: String(localized: "굵기")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("굵기 사용", isOn: $weightEnabled)
                        .toggleStyle(.checkbox)

                    if weightEnabled {
                        Picker("굵기", selection: $weight) {
                            ForEach(weights, id: \.self) { option in
                                Text(genericWeightLabel(option)).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            SliderRow(title: String(localized: "크기"), value: $size, range: sizeRange, suffix: "px")
            ColorPaletteField(title: String(localized: "색상"), colorHex: $colorHex)

            WorkspaceInlineSection(title: String(localized: "타이포 설정"), subtitle: String(localized: "자간, 줄간, 기울임, 굵기 사용 여부를 체크박스로 제어합니다.")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("기울기", isOn: $italicEnabled)
                        .toggleStyle(.checkbox)

                    Toggle("자간 조정", isOn: $letterSpacingEnabled)
                        .toggleStyle(.checkbox)
                    if letterSpacingEnabled {
                        SliderRow(title: String(localized: "자간"), value: $letterSpacing, range: -8...24, step: 0.5, suffix: "px")
                    }

                    Toggle("줄간 조정", isOn: $lineHeightEnabled)
                        .toggleStyle(.checkbox)
                    if lineHeightEnabled {
                        SliderRow(title: String(localized: "줄간"), value: $lineHeight, range: 0.8...2.4, step: 0.05, suffix: "x", decimals: 2)
                    }
                }
            }

            if showsShadowControls {
                Toggle("드랍 쉐도우", isOn: $shadowEnabled)
                    .toggleStyle(.switch)

                if shadowEnabled {
                    SliderRow(title: String(localized: "쉐도우 강도"), value: $shadowStrength, range: 0.05...1.0, step: 0.01, suffix: "", decimals: 2)
                    SliderRow(
                        title: String(localized: "불투명도"),
                        value: Binding(
                            get: { shadowOpacity * 100 },
                            set: { shadowOpacity = $0 / 100 }
                        ),
                        range: 0...100,
                        step: 1,
                        suffix: "%",
                        decimals: 0
                    )
                    SliderRow(title: String(localized: "거리"), value: $shadowDistance, range: 0...60, step: 1, suffix: "px", decimals: 0)
                    SliderRow(title: String(localized: "크기"), value: $shadowBlur, range: 0...80, step: 1, suffix: "px", decimals: 0)
                    SliderRow(title: String(localized: "페더"), value: $shadowFeather, range: 0...40, step: 1, suffix: "px", decimals: 0)
                }
            }
        }
    }
}

struct ShadowControlGroup: View {
    let heading: String
    @Binding var shadowEnabled: Bool
    @Binding var shadowStrength: Double
    @Binding var shadowOpacity: Double
    @Binding var shadowDistance: Double
    @Binding var shadowBlur: Double
    @Binding var shadowFeather: Double

    var body: some View {
        WorkspaceInlineSection(title: heading, subtitle: String(localized: "드랍쉐도우 세부 값을 개별적으로 조정합니다.")) {
            Toggle("드랍 쉐도우", isOn: $shadowEnabled)
                .toggleStyle(.switch)

            if shadowEnabled {
                SliderRow(title: String(localized: "쉐도우 강도"), value: $shadowStrength, range: 0.05...1.0, step: 0.01, suffix: "", decimals: 2)
                SliderRow(
                    title: String(localized: "불투명도"),
                    value: Binding(
                        get: { shadowOpacity * 100 },
                        set: { shadowOpacity = $0 / 100 }
                    ),
                    range: 0...100,
                    step: 1,
                    suffix: "%",
                    decimals: 0
                )
                SliderRow(title: String(localized: "거리"), value: $shadowDistance, range: 0...60, step: 1, suffix: "px", decimals: 0)
                SliderRow(title: String(localized: "크기"), value: $shadowBlur, range: 0...80, step: 1, suffix: "px", decimals: 0)
                SliderRow(title: String(localized: "페더"), value: $shadowFeather, range: 0...40, step: 1, suffix: "px", decimals: 0)
            }
        }
    }
}

struct ColorPaletteField: View {
    let title: String
    @Binding var colorHex: String

    private let swatches: [(hex: String, name: String)] = [
        ("#FFFFFF", String(localized: "흰색")),
        ("#121212", String(localized: "검정")),
        ("#2F2F2F", String(localized: "진회색")),
        ("#6B7280", String(localized: "회색")),
        ("#B91C1C", String(localized: "빨강")),
        ("#1D4ED8", String(localized: "파랑")),
        ("#0F766E", String(localized: "청록")),
        ("#9333EA", String(localized: "보라")),
        ("#D97706", String(localized: "주황"))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(swatches, id: \.hex) { swatch in
                    let isSelected = colorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                    Button {
                        colorHex = swatch.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(isSelected ? Color.primary : Color.primary.opacity(0.16), lineWidth: isSelected ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityValue(swatch.hex)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .help("\(swatch.name) \(swatch.hex)")
                }
            }

            TextField("#FFFFFF", text: Binding(
                get: { colorHex },
                set: { colorHex = normalizeHexColor($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let decimals: Int
    @State private var draftValue: String
    @State private var sliderValue: Double
    @State private var isEditingSlider = false
    @FocusState private var valueFieldFocused: Bool

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0.1, suffix: String, decimals: Int? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.suffix = suffix
        if let decimals {
            self.decimals = decimals
        } else if step >= 1 {
            self.decimals = 0
        } else if step >= 0.1 {
            self.decimals = 1
        } else {
            self.decimals = 2
        }
        _draftValue = State(initialValue: SliderRow.formattedValue(value.wrappedValue, decimals: self.decimals))
        _sliderValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                TextField("", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 88)
                    .focused($valueFieldFocused)
                    .onSubmit {
                        applyDraftValue()
                    }

                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // step을 Slider에 직접 주면 macOS가 스텝마다 눈금을 그린다 —
            // 범위 -400~400·step 0.1이면 눈금 8,000개가 생성되어 탭 진입이
            // 눈에 띄게 느려진다. 연속 슬라이더로 두고 값만 step에 스냅한다.
            Slider(
                value: $sliderValue,
                in: range,
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing {
                        commitSliderValue()
                    }
                }
            )
            .controlSize(.small)
            .onChange(of: sliderValue) { newValue in
                guard isEditingSlider else { return }
                let snapped = snappedValue(newValue)
                if value != snapped {
                    value = snapped
                }
                draftValue = Self.formattedValue(snapped, decimals: decimals)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: value) { newValue in
            if !valueFieldFocused && !isEditingSlider {
                draftValue = SliderRow.formattedValue(newValue, decimals: decimals)
                sliderValue = newValue
            }
        }
        .onChange(of: valueFieldFocused) { focused in
            if !focused {
                applyDraftValue()
            }
        }
    }

    private static func formattedValue(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private func applyDraftValue() {
        let sanitized = draftValue
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsed = Double(sanitized) else {
            draftValue = Self.formattedValue(value, decimals: decimals)
            sliderValue = value
            return
        }

        let snapped = snappedValue(parsed)
        value = snapped
        sliderValue = snapped
        draftValue = Self.formattedValue(snapped, decimals: decimals)
    }

    private func commitSliderValue() {
        let snapped = snappedValue(sliderValue)
        sliderValue = snapped
        value = snapped
        draftValue = Self.formattedValue(snapped, decimals: decimals)
    }

    private func snappedValue(_ rawValue: Double) -> Double {
        let snapped = (rawValue / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

struct AddressField: View {
    let title: String
    let value: String
    let showsValue: Bool
    let actionTitle: String?
    let actionAccessibilityLabel: String?
    let action: (() -> Void)?

    init(title: String, value: String, showsValue: Bool = true, actionTitle: String? = nil, actionAccessibilityLabel: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.showsValue = showsValue
        self.actionTitle = actionTitle
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(actionAccessibilityLabel ?? actionTitle)
                }
            }
            if showsValue {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.Surface.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct LiquidPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let material: Material
    let shadowStrength: Double

    // 플랫 디자인: 라운드 유리 패널(재질·그림자·테두리)을 모두 제거하고
    // 섹션 구분은 여백과 헤어라인에 맡긴다.
    func body(content: Content) -> some View {
        content
    }
}

private extension View {
    func liquidPanel(cornerRadius: CGFloat, material: Material, shadowStrength: Double = 0.1) -> some View {
        modifier(LiquidPanelModifier(cornerRadius: cornerRadius, material: material, shadowStrength: shadowStrength))
    }
}

private struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.62 : 0.9)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct SoftControlButtonStyle: ButtonStyle {
    enum Tone {
        case neutral
        case accent
        case destructive
    }

    @Environment(\.colorScheme) private var colorScheme
    let tone: Tone

    init(tone: Tone = .neutral) {
        self.tone = tone
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.06)
        case .accent:
            return Color.accentColor
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.75 : 0.84)
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .neutral:
            return .primary
        case .accent, .destructive:
            return .white
        }
    }
}

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    let reloadToken: String
    // 프리뷰 패널은 실제 사이니지 화면(예: 1920x1080 TV/OptiSigns)보다 훨씬
    // 작아서, 웹뷰를 패널 크기 그대로 렌더링하면 고정 px 폰트가 실제 출력보다
    // 크게 보인다. pageZoom을 (패널 폭 ÷ 기준 폭)으로 맞추면 레이아웃 뷰포트가
    // 기준 해상도와 같아져 실제 화면과 동일한 비율로 표시된다.
    var referenceSize: CGSize = CGSize(width: 1920, height: 1080)

    final class PassthroughPreviewWebView: WKWebView {
        var referenceWidth: CGFloat = 1920 {
            didSet { applyPreviewZoom() }
        }

        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }

        override func layout() {
            super.layout()
            applyPreviewZoom()
        }

        private func applyPreviewZoom() {
            guard referenceWidth > 0, bounds.width > 0 else { return }
            let zoom = bounds.width / referenceWidth
            if abs(pageZoom - zoom) > 0.001 {
                pageZoom = zoom
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRequestedURL: String?
        var lastReloadToken: String?
        var lastFailedURL: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastFailedURL = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            lastFailedURL = webView.url?.absoluteString
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            lastFailedURL = webView.url?.absoluteString
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughPreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let webView = PassthroughPreviewWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if let internalScrollView = webView.subviews.compactMap({ $0 as? NSScrollView }).first {
            internalScrollView.hasVerticalScroller = false
            internalScrollView.hasHorizontalScroller = false
            internalScrollView.drawsBackground = false
        }
        webView.referenceWidth = referenceSize.width
        return webView
    }

    func updateNSView(_ webView: PassthroughPreviewWebView, context: Context) {
        webView.referenceWidth = referenceSize.width

        let targetURL = url.absoluteString
        let didChangeURL = context.coordinator.lastRequestedURL != targetURL
        let didFailCurrentURL = context.coordinator.lastFailedURL == targetURL
        let didChangeReloadToken = context.coordinator.lastReloadToken != reloadToken

        if !didChangeURL && !didFailCurrentURL && !didChangeReloadToken {
            return
        }

        context.coordinator.lastRequestedURL = targetURL
        context.coordinator.lastReloadToken = reloadToken

        if !didChangeURL && !didFailCurrentURL {
            webView.reloadFromOrigin()
            return
        }

        let request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 15
        )
        webView.load(request)
    }

    static func dismantleNSView(_ webView: PassthroughPreviewWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pro (인앱 구매)

/// 무료 버전임을 나타내는 "FREE" 마크.
struct FreeBadge: View {
    var body: some View {
        Text("FREE")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// 구매 시 사용할 수 있는 기능임을 나타내는 "PRO" 마크.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
    }
}

/// 무료 재생 제한을 초과했을 때 미디어 탭에 노출되는 안내 배너.
struct FreeTierLimitBanner: View {
    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("무료 버전 재생 제한")
                        .font(.system(size: 12, weight: .semibold))
                    ProBadge()
                }
                Text("무료 버전은 사진 \(FreeTierLimits.maxPhotosPerProject)장 · 영상 \(FreeTierLimits.maxVideosPerProject)개까지만 재생됩니다. Pro로 업그레이드하면 무제한 재생됩니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("업그레이드", action: onUpgrade)
                .buttonStyle(SoftControlButtonStyle(tone: .accent))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Pro 영구 잠금해제 구매/복원 화면.
struct ProUpgradeView: View {
    @EnvironmentObject private var proStore: ProStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Photo Slide Studio Pro")
                            .font(.system(size: 18, weight: .bold))
                        ProBadge()
                    }
                    Text("한 번 구매로 영구 잠금해제")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            comparisonTable

            if proStore.isPro {
                Label("Pro가 활성화되어 있습니다. 감사합니다!", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await proStore.purchase() }
                    } label: {
                        HStack {
                            Spacer()
                            if proStore.purchaseInProgress {
                                ProgressView().controlSize(.small)
                            } else if let product = proStore.product {
                                Text("\(product.displayPrice)에 구매")
                            } else {
                                Text("구매")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(SoftControlButtonStyle(tone: .accent))
                    .disabled(proStore.purchaseInProgress)

                    Button("구매 복원") {
                        Task { await proStore.restorePurchases() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                    if let message = proStore.lastErrorMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .buttonStyle(SoftControlButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if proStore.product == nil {
                Task { await proStore.loadProduct() }
            }
        }
    }

    private static let valueColumnWidth: CGFloat = 72

    /// 무료 vs PRO 기능 비교표.
    private var comparisonTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("기능")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("무료")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.valueColumnWidth)
                ProBadge()
                    .frame(width: Self.valueColumnWidth)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            comparisonRow(icon: "square.stack.3d.up.fill", title: String(localized: "슬라이드 생성"), free: String(localized: "\(FreeTierLimits.maxProjects)개"), pro: String(localized: "무제한"))
            comparisonRow(icon: "photo.fill", title: String(localized: "사진 재생"), free: String(localized: "\(FreeTierLimits.maxPhotosPerProject)장"), pro: String(localized: "무제한"))
            comparisonRow(icon: "video.fill", title: String(localized: "영상 재생"), free: String(localized: "\(FreeTierLimits.maxVideosPerProject)개"), pro: String(localized: "무제한"))
            comparisonRow(icon: "music.note", title: String(localized: "배경음악"), free: String(localized: "포함"), pro: String(localized: "포함"))
            comparisonRow(icon: "wand.and.stars", title: String(localized: "텍스트·로고·모션 연출"), free: String(localized: "포함"), pro: String(localized: "포함"), isLast: true)
        }
        .background(Theme.Surface.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            // PRO 열 강조 밴드
            HStack(spacing: 0) {
                Spacer()
                Color.accentColor.opacity(0.07)
                    .frame(width: Self.valueColumnWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private func comparisonRow(icon: String, title: String, free: String, pro: String, isLast: Bool = false) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(free)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.valueColumnWidth)

            Text(pro)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.valueColumnWidth)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        if !isLast {
            Divider().padding(.leading, 12)
        }
    }
}
