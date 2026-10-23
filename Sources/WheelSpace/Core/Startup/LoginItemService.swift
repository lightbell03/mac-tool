import ServiceManagement

/// SMAppService.mainApp으로 로그인 시 실행을 관리한다. 저장값 대신 실제 등록 상태를 조회한다.
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자 승인이 필요한 상태(.requiresApproval)인지
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
