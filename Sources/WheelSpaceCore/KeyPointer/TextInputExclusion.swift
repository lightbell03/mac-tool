import Foundation

/// 입력란으로 판단된 요소의 특징 (내용·제목 없음). 앱이 알려 주는 만큼만 채워진다.
public struct FocusSignature: Equatable, Sendable {
    /// 포커스가 있는 앱
    public var bundleID: String?
    /// AXTextArea 등
    public var role: String
    /// 웹 페이지면 주소의 scheme·호스트 (devtools / https, 예: portal.example.com)
    public var urlScheme: String?
    public var urlHost: String?
    /// 웹 요소의 클래스 (Chromium·WebKit이 알려 줄 때만)
    public var domClasses: [String]

    public init(bundleID: String?, role: String, urlScheme: String?, urlHost: String?, domClasses: [String]) {
        self.bundleID = bundleID
        self.role = role
        self.urlScheme = urlScheme
        self.urlHost = urlHost
        self.domClasses = domClasses
    }

    /// 웹 페이지 안의 요소인지 (모든 브라우저에 적용할 수 있는지)
    public var isWebContent: Bool {
        urlScheme != nil
    }
}

/// 입력란으로 보지 않을 영역 규칙 — "방금 해제된 곳은 앞으로 해제하지 않기"로 사용자가 만든다.
/// 정한 항목만 비교하고 비워 둔 항목은 아무것이나 맞는다. 클래스는 규칙의 클래스가 모두 요소에 있으면 맞는다.
public struct TextInputExclusionRule: Codable, Equatable, Hashable, Sendable {
    /// nil = 모든 앱(브라우저)
    public var bundleID: String?
    public var role: String
    public var urlScheme: String?
    public var urlHost: String?
    public var domClasses: [String]

    public init(bundleID: String?, role: String, urlScheme: String?, urlHost: String?, domClasses: [String]) {
        self.bundleID = bundleID
        self.role = role
        self.urlScheme = urlScheme
        self.urlHost = urlHost
        self.domClasses = domClasses
    }

    /// 기본 규칙: Chrome 등 개발자 도구의 코드 편집기(Response·Preview·Console 입력 줄) — 읽기 전용 여부를 알려 주지 않는다
    public static let devToolsCodeEditor = TextInputExclusionRule(
        bundleID: nil, role: "AXTextArea", urlScheme: "devtools", urlHost: nil, domClasses: ["cm-content"]
    )

    /// 방금 해제된 요소로 규칙 만들기. allBrowsers면 앱 대신 페이지(scheme·호스트)로 맞춘다 (웹 페이지일 때만 의미 있음).
    public static func learned(from signature: FocusSignature, allBrowsers: Bool) -> TextInputExclusionRule {
        TextInputExclusionRule(
            bundleID: allBrowsers && signature.isWebContent ? nil : signature.bundleID,
            role: signature.role,
            urlScheme: signature.urlScheme,
            urlHost: signature.urlHost,
            domClasses: signature.domClasses
        )
    }

    public func matches(_ signature: FocusSignature) -> Bool {
        if let bundleID, bundleID != signature.bundleID { return false }
        guard role == signature.role else { return false }
        func same(_ expected: String?, _ actual: String?) -> Bool {
            guard let expected else { return true }
            return expected.caseInsensitiveCompare(actual ?? "") == .orderedSame
        }
        guard same(urlScheme, signature.urlScheme), same(urlHost, signature.urlHost) else { return false }
        return Set(domClasses).isSubset(of: Set(signature.domClasses))
    }

    /// 규칙이 넓은지 (웹 정보·클래스 없이 앱 + 역할만) — 저장할 때 "이 앱의 모든 텍스트 영역" 같은 안내에 쓴다
    public var isBroad: Bool {
        urlScheme == nil && urlHost == nil && domClasses.isEmpty
    }
}
