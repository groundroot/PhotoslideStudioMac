import Foundation
import StoreKit

/// 무료 버전 제한값. Pro(영구 잠금해제) 구매 시 모두 해제된다.
enum FreeTierLimits {
    /// 무료로 만들 수 있는 슬라이드(프로젝트) 수.
    static let maxProjects = 1
    /// 슬라이드(프로젝트) 전체 합산으로 재생되는 사진 수.
    static let maxPhotosPerProject = 10
    /// 슬라이드(프로젝트) 전체 합산으로 재생되는 영상 수.
    static let maxVideosPerProject = 1
}

/// Photo Slide Studio Pro — 비소모성 인앱 구매(영구 잠금해제) 상태 관리.
///
/// 잠금해제 여부는 UserDefaults(`pro.unlocked`)에 캐시되어
/// 서버 스레드 등 비 UI 경로에서도 동기적으로 읽을 수 있다.
@MainActor
final class ProStore: ObservableObject {
    nonisolated static let productID = "com.dreammedia.photoslidestudio.pro"
    private nonisolated static let unlockedDefaultsKey = "pro.unlocked"

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    /// 테스트 배포용 Pro 에디션 빌드 여부 (Info.plist의 PSSProUnlocked).
    /// 스토어 배포판에는 이 키가 없고, 인앱 구매로만 Pro가 활성화된다.
    nonisolated static var isProEditionBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "PSSProUnlocked") as? Bool) == true
    }

    /// 개발 빌드 전용 잠금해제 토글 — 릴리스 빌드에서는 컴파일되지 않아
    /// defaults 조작으로 구매를 우회할 수 없다.
    nonisolated static var isDebugUnlocked: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debug.proUnlocked")
        #else
        return false
        #endif
    }

    /// 라우팅/미디어 조립 등 비 UI 스레드에서 쓰는 동기 캐시.
    nonisolated static var isProCached: Bool {
        isProEditionBuild
            || UserDefaults.standard.bool(forKey: unlockedDefaultsKey)
            || isDebugUnlocked
    }

    private var updatesTask: Task<Void, Never>?

    init() {
        isPro = Self.isProCached
        updatesTask = Task { [weak self] in
            for await _ in Transaction.updates {
                await self?.refreshEntitlement()
            }
        }
        Task {
            await refreshEntitlement()
            await loadProduct()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func refreshEntitlement() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        setUnlocked(unlocked || Self.isProEditionBuild || Self.isDebugUnlocked)
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            // 개발 빌드/오프라인에서는 상품 조회가 실패할 수 있다 — 구매 UI에서 안내.
            product = nil
        }
    }

    func purchase() async {
        guard !purchaseInProgress else { return }
        guard let product else {
            lastErrorMessage = String(localized: "스토어에서 상품 정보를 불러오지 못했습니다. 네트워크 확인 후 다시 시도해주세요.")
            await loadProduct()
            return
        }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    setUnlocked(true)
                    lastErrorMessage = nil
                } else {
                    lastErrorMessage = String(localized: "구매 확인에 실패했습니다. 다시 시도해주세요.")
                }
            case .userCancelled:
                break
            case .pending:
                lastErrorMessage = String(localized: "구매 승인 대기 중입니다. 승인되면 자동으로 잠금이 해제됩니다.")
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = String(localized: "구매를 완료하지 못했습니다: \(error.localizedDescription)")
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            lastErrorMessage = String(localized: "구매 복원에 실패했습니다: \(error.localizedDescription)")
        }
        await refreshEntitlement()
        if !isPro {
            lastErrorMessage = String(localized: "복원할 구매 내역이 없습니다.")
        }
    }

    private func setUnlocked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.unlockedDefaultsKey)
        if isPro != value {
            isPro = value
        }
    }
}
