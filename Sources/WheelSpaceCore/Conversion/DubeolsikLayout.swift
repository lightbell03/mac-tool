import Foundation

/// 영문 QWERTY ↔ 한국어 표준 두벌식 키 배열 표. 자모는 호환 자모(U+3131~U+318E)로 다룬다.
enum DubeolsikLayout {
    /// Shift 의미가 있는 키. 그 밖의 대문자는 소문자와 같은 자모로 처리한다.
    private static let lowercaseKeys: [Character: Character] = [
        "r": "ㄱ", "s": "ㄴ", "e": "ㄷ", "f": "ㄹ", "a": "ㅁ", "q": "ㅂ", "t": "ㅅ",
        "d": "ㅇ", "w": "ㅈ", "c": "ㅊ", "z": "ㅋ", "x": "ㅌ", "v": "ㅍ", "g": "ㅎ",
        "k": "ㅏ", "o": "ㅐ", "i": "ㅑ", "j": "ㅓ", "p": "ㅔ", "u": "ㅕ", "h": "ㅗ",
        "y": "ㅛ", "n": "ㅜ", "b": "ㅠ", "m": "ㅡ", "l": "ㅣ",
    ]
    private static let shiftedKeys: [Character: Character] = [
        "R": "ㄲ", "E": "ㄸ", "Q": "ㅃ", "T": "ㅆ", "W": "ㅉ", "O": "ㅒ", "P": "ㅖ",
    ]

    /// 키 → 자모. Shift 의미가 있는 R·E·Q·T·W·O·P는 쌍자음/ㅒ·ㅖ, 그 밖의 대문자는 소문자와 같게 처리.
    static let keyToJamo: [Character: Character] = {
        var table = lowercaseKeys
        for (key, jamo) in lowercaseKeys {
            let upper = Character(key.uppercased())
            table[upper] = shiftedKeys[upper] ?? jamo
        }
        return table
    }()

    /// 단일 자모 → 키 (한글 → 영문). 쌍자음·ㅒ·ㅖ는 대문자.
    static let jamoToKey: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (key, jamo) in lowercaseKeys { table[jamo] = key }
        for (key, jamo) in shiftedKeys { table[jamo] = key }
        return table
    }()

    /// 초성 19자 (유니코드 초성 인덱스 순)
    static let choseong: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    /// 중성 21자 (유니코드 중성 인덱스 순)
    static let jungseong: [Character] = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// 종성 27자 (유니코드 종성 인덱스 1~27 순, 0 = 받침 없음은 포함하지 않음)
    static let jongseong: [Character] = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")

    /// 복합 중성: (첫 모음, 둘째 모음) → 결과. ㅘ·ㅙ·ㅚ·ㅝ·ㅞ·ㅟ·ㅢ
    static let compoundVowels: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    /// 겹받침: (첫 자음, 둘째 자음) → 결과. ㄳ·ㄵ·ㄶ·ㄺ·ㄻ·ㄼ·ㄽ·ㄾ·ㄿ·ㅀ·ㅄ
    static let compoundFinals: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]

    private static let compoundComponents: [Character: [Character]] = {
        var table: [Character: [Character]] = [:]
        for (pair, result) in compoundVowels { table[result] = Array(pair) }
        for (pair, result) in compoundFinals { table[result] = Array(pair) }
        return table
    }()

    static func isVowel(_ jamo: Character) -> Bool {
        jungseong.contains(jamo)
    }

    /// 복합 모음·겹받침 → 구성 자모 2개. 단일 자모면 그 자모 하나.
    static func components(of jamo: Character) -> [Character] {
        compoundComponents[jamo] ?? [jamo]
    }
}
