import Carbon

struct InputSourceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Text Input Source Services로 설치된 키보드 입력 소스를 조회·선택한다. ID는 하드코딩하지 않는다.
enum InputSourceService {
    /// 선택 가능한 한국어 키보드 입력 소스 (두벌식 등)
    static func koreanSources() -> [InputSourceInfo] {
        selectableKeyboardSources()
            .filter { primaryLanguage(of: $0.source) == "ko" }
            .map(\.info)
    }

    /// 선택 가능한 영문 키보드 입력 소스 (ABC, U.S. 등)
    static func englishSources() -> [InputSourceInfo] {
        selectableKeyboardSources()
            .filter { boolProperty($0.source, kTISPropertyInputSourceIsASCIICapable) && primaryLanguage(of: $0.source) == "en" }
            .map(\.info)
    }

    static func currentSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    /// 선택 요청 후 현재 소스를 다시 조회해 실제로 바뀌었는지 판정한다.
    static func select(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else {
            return false
        }
        guard TISSelectInputSource(source) == noErr else { return false }
        return currentSourceID() == id
    }

    /// 활성화돼 있고 선택 가능한 키보드 입력 소스(입력 모드 포함) 목록.
    private static func selectableKeyboardSources() -> [(source: TISInputSource, info: InputSourceInfo)] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
            let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
            return (source, InputSourceInfo(id: id, name: name))
        }
    }

    private static func primaryLanguage(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}
