import AppKit
import SwiftUI

enum OnboardingKeys {
    static let completed = "onboarding.completed"
}

/// 첫 실행(또는 메뉴에서 다시 열기) 시 표시되는 권한 안내 온보딩.
///
/// 이 앱이 사용하는 권한과 부여 방법을 단계별로 안내하고,
/// 각 단계에서 곧바로 권한을 요청하거나 시스템 설정을 열 수 있다.
struct OnboardingView: View {
    @EnvironmentObject private var server: LocalSlideshowServer
    @EnvironmentObject private var projectStore: ProjectStore
    @AppStorage(OnboardingKeys.completed) private var onboardingCompleted = false
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private let totalSteps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 10) {
                // 단계 표시 점
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()

                if step > 0 {
                    Button("이전") {
                        step -= 1
                    }
                    .buttonStyle(.bordered)
                }

                if step < totalSteps - 1 {
                    Button("다음") {
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("시작하기") {
                        onboardingCompleted = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 520, height: 480)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            welcomeStep
        case 1:
            localNetworkStep
        default:
            folderAccessStep
        }
    }

    // MARK: - 1. 환영

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            Text("Photo Slide Studio에 오신 것을 환영합니다")
                .font(.system(size: 22, weight: .bold))

            Text("사진·영상 폴더를 연결하면 아름다운 웹 슬라이드쇼가 완성되고, URL 하나로 같은 네트워크의 어떤 화면에서든 재생할 수 있습니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("원활한 사용을 위해 두 가지 권한이 필요합니다. 다음 단계에서 하나씩 안내해 드릴게요.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                onboardingChecklistRow(icon: "network", title: "로컬 네트워크", detail: "TV·사이니지가 슬라이드쇼에 접속할 때 필요")
                onboardingChecklistRow(icon: "folder", title: "미디어 폴더 접근", detail: "사진·영상 폴더를 읽을 때 필요")
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 2. 로컬 네트워크

    private var localNetworkStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            Text("로컬 네트워크 권한")
                .font(.system(size: 20, weight: .bold))

            Text("같은 네트워크의 TV·사이니지 플레이어가 슬라이드쇼 주소(URL)에 접속하려면 로컬 네트워크 권한이 필요합니다. 아래 버튼으로 서버를 시작하면 macOS가 권한을 물어봅니다 — \"허용\"을 눌러주세요.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    server.start()
                } label: {
                    Label("서버 시작하고 권한 요청", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.isRunning)

                if server.isRunning {
                    Label("서버 실행 중", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            Text("실수로 거부했다면 시스템 설정에서 언제든 다시 켤 수 있습니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("시스템 설정 → 로컬 네트워크 열기") {
                openSystemSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 3. 폴더 접근

    private var folderAccessStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            Text("미디어 폴더 접근")
                .font(.system(size: 20, weight: .bold))

            Text("사진·영상 폴더는 앱 안의 \"사진 폴더 선택\" 버튼으로 직접 선택하는 순간 접근 권한이 부여되고, 앱을 다시 실행해도 자동으로 기억됩니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("데스크톱·문서·외장 디스크·NAS 폴더를 처음 읽을 때 macOS가 추가로 물어볼 수 있습니다 — \"허용\"을 눌러주세요. 권한 상태는 시스템 설정에서 확인·변경할 수 있습니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("시스템 설정 → 파일 및 폴더 열기") {
                openSystemSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders")
            }
            .buttonStyle(.bordered)

            Text("모든 권한을 처음부터 다시 설정하고 싶다면 메뉴의 \"Photo Slide Studio → 권한 설정 다시 하기\"를 언제든 사용할 수 있습니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func onboardingChecklistRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
