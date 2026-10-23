import Foundation

/// 선택한 앱의 창 상태 조회 결과. 조회 실패는 "창 없음"과 반드시 구별한다.
public enum AppWindowInspection: Equatable, Sendable {
    /// 권한 없음·시간 초과·AX 오류 — 창이 있는지 모른다
    case failed
    case inspected(AppWindowState)
}

/// 한 앱의 창 상태 (창 제목 없음)
public struct AppWindowState: Equatable, Sendable {
    /// ⌘H 숨김
    public var isHidden: Bool
    /// 최소화되지 않은 일반 창 수 (AX)
    public var normalWindowCount: Int
    /// 최소화된 일반 창 수 (AX)
    public var minimizedWindowCount: Int
    /// 모달 대화상자·시트가 떠 있음
    public var hasModal: Bool
    /// 지금 화면에 없는 일반 창 수 (CG 전체 목록). 다른 데스크탑(Space)의 창과, 닫혀서 숨겨 둔 창(Teams 등)이
    /// 섞여 있어 구별할 수 없다 — 그래서 새 창을 직접 만들지 않고 Dock 클릭과 같은 다시 열기로 앱에 맡긴다.
    public var otherSpaceWindowCount: Int

    public init(isHidden: Bool, normalWindowCount: Int, minimizedWindowCount: Int, hasModal: Bool, otherSpaceWindowCount: Int) {
        self.isHidden = isHidden
        self.normalWindowCount = normalWindowCount
        self.minimizedWindowCount = minimizedWindowCount
        self.hasModal = hasModal
        self.otherSpaceWindowCount = otherSpaceWindowCount
    }
}

/// 다음에 할 일 (한 단계씩 진행하고, 상태를 바꾸는 단계 뒤에는 다시 조회한다)
public enum RevealStep: Equatable, Sendable {
    /// 숨김 해제 → 다시 조회
    case unhide
    /// 기존 일반 창(또는 모달)을 앞으로 가져와 포커스 확인
    case focusExisting
    /// 최소화된 창 하나 복원 → 포커스 확인
    case restoreMinimized
    /// 앱에 다시 열기 요청 (한 작업당 한 번) → 창 생길 때까지 기다렸다가 확인
    case reopen
    /// 창을 보여 줄 방법이 없어 앱 활성화만 하고 이유를 알린다
    case activateOnly(RevealLimit)
}

/// 창을 보여 주지 못한 이유 (안내 문구용)
public enum RevealLimit: Equatable, Sendable {
    /// 창 상태를 확인하지 못함 (권한·응답 없음) — 창이 없다고 단정하지 않는다
    case inspectionFailed
    /// 창이 다른 데스크탑에 있음 — 새 창을 만들지 않는다
    case windowsOnOtherSpace
    /// 숨긴 앱인데 "선택 시 숨김 해제"가 꺼져 있음
    case hiddenAndUnhideDisabled
    /// 최소화된 창만 있는데 "최소화 창 복원"이 꺼져 있음
    case minimizedAndRestoreDisabled
    /// 창이 없는데 "다시 열기"가 꺼져 있거나 이미 한 번 요청함
    case noWindowAndReopenUnavailable
}

/// 상태 → 다음 단계. OS 호출 없는 순수 분기라 모의 상태로 테스트한다.
/// 순서: 숨김 해제 → (다시 조회) → 기존 창 → 최소화 하나 복원 → 다른 데스크탑 확인 → 필요할 때만 다시 열기.
public enum AppRevealPlanner {
    /// alreadyUnhid: 이번 작업에서 이미 숨김을 해제함 (다시 숨김 해제하지 않는다)
    /// alreadyReopened: 이번 작업에서 이미 다시 열기를 요청함 (두 번 보내지 않는다)
    public static func nextStep(
        _ inspection: AppWindowInspection,
        settings: AppRevealSettings,
        alreadyUnhid: Bool,
        alreadyReopened: Bool
    ) -> RevealStep {
        guard case .inspected(let state) = inspection else { return .activateOnly(.inspectionFailed) }
        if state.isHidden, !alreadyUnhid {
            return settings.unhideOnSelect ? .unhide : .activateOnly(.hiddenAndUnhideDisabled)
        }
        // 보이는 창이 있으면 최소화된 다른 창은 건드리지 않는다
        if state.hasModal || state.normalWindowCount > 0 { return .focusExisting }
        if state.minimizedWindowCount > 0 {
            return settings.restoreMinimized ? .restoreMinimized : .activateOnly(.minimizedAndRestoreDisabled)
        }
        let canReopen = settings.reopenWhenNoWindow && !alreadyReopened
        // 화면 밖 창(다른 데스크탑 또는 닫혀 숨긴 창): Dock 클릭과 같은 다시 열기 — 다른 데스크탑이면 macOS가 그리로 옮겨 주고
        // 앱은 새 창을 만들지 않는다. 다시 열기를 못 쓰면 다른 데스크탑일 수 있다고 안내한다.
        if state.otherSpaceWindowCount > 0 {
            return canReopen ? .reopen : .activateOnly(.windowsOnOtherSpace)
        }
        return canReopen ? .reopen : .activateOnly(.noWindowAndReopenUnavailable)
    }
}
