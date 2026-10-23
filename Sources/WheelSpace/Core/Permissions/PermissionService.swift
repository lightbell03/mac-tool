import ApplicationServices
import AppKit
import CoreGraphics

struct PermissionStatus: Equatable {
    /// 손쉬운 사용 (AXIsProcessTrusted)
    var accessibility: Bool
    /// 이벤트 감지 / 입력 모니터링 (CGPreflightListenEventAccess)
    var listenEvents: Bool
    /// 이벤트 전송 (CGPreflightPostEventAccess)
    var postEvents: Bool

    /// 권한 API 기준 충족 여부. 실제 정상 여부는 이벤트 탭 생성 성공과 함께 판단한다.
    var isSufficient: Bool {
        listenEvents && postEvents
    }
}

enum PermissionService {
    enum SettingsPane {
        case accessibility
        case inputMonitoring
    }

    static func currentStatus() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            listenEvents: CGPreflightListenEventAccess(),
            postEvents: CGPreflightPostEventAccess()
        )
    }

    /// 누락된 권한만 요청한다. 거부된 권한을 강제로 반복 요청하지 않는다.
    static func requestMissing(current: PermissionStatus) {
        if !current.listenEvents {
            CGRequestListenEventAccess()
        }
        if !current.postEvents {
            CGRequestPostEventAccess()
        } else if !current.accessibility {
            // 전송 권한 요청이 이미 손쉬운 사용 안내를 띄우므로 겹치지 않을 때만 따로 요청한다.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    static func openSystemSettings(_ pane: SettingsPane) {
        let anchor: String
        switch pane {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
