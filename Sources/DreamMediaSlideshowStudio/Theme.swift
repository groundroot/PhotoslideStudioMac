import SwiftUI

/// 앱 전반의 시각 토큰을 한곳에 모은 디자인 시스템.
///
/// 지금까지 뷰 곳곳에 흩어져 있던 곡률·간격·표면 불투명도 매직 넘버를
/// 합리적인 스케일로 통일한다. 값은 기존 디자인을 보존하도록 시드했고,
/// 앞으로 시각/구조 개선은 이 토큰을 조정하는 것으로 일관되게 반영한다.
enum Theme {
    /// 8pt 기반 간격 스케일.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    /// 연속 곡률 반경 스케일 (필드 → 카드 → 패널 → 사이드바).
    /// 클로드 데스크톱 앱처럼 절제된 곡률로 통일한다.
    enum Radius {
        static let field: CGFloat = 10
        static let card: CGFloat = 12
        static let panel: CGFloat = 14
        static let sidebar: CGFloat = 14
    }

    /// 리퀴드 글래스 패널의 그림자 강도.
    enum Shadow {
        static let subtle: Double = 0.06
        static let card: Double = 0.08
        static let panel: Double = 0.1
        static let sidebar: Double = 0.14
    }

    /// 표면(인라인 필드/카드) 채움 불투명도. 기존 0.04/0.05/0.06을 통일.
    enum Surface {
        /// 인라인 필드/카드의 기본 채움.
        static let fill = Color.primary.opacity(0.05)
        /// 선택/강조되지 않은 보조 표면.
        static let subtle = Color.primary.opacity(0.04)
    }
}
