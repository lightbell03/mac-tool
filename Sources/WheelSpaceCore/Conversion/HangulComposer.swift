import Foundation

/// 영문 키 문자열을 두벌식 규칙으로 조합해 한글로 만든다. 문자열 전체를 한 번에 처리한다.
/// 입력 상태 머신(초성·중성·종성 보류)과 유니코드 음절 생성(syllable)을 분리한다.
struct HangulComposer {
    private var initial: Character?
    private var medial: Character?
    private var final: Character?
    private var output = ""

    static func compose(_ text: String) -> String {
        var composer = HangulComposer()
        composer.output.reserveCapacity(text.utf8.count)
        for character in text {
            if let jamo = DubeolsikLayout.keyToJamo[character] {
                composer.feed(jamo)
            } else {
                // 공백·기호·기존 한글 등 경계: 조합을 확정하고 원문 그대로
                composer.flush()
                composer.output.append(character)
            }
        }
        composer.flush()
        return composer.output
    }

    /// 자모 하나 입력. 규칙은 trans-plan 5.2 표를 따른다.
    private mutating func feed(_ jamo: Character) {
        if DubeolsikLayout.isVowel(jamo) {
            feedVowel(jamo)
        } else {
            feedConsonant(jamo)
        }
    }

    private mutating func feedConsonant(_ jamo: Character) {
        guard initial != nil else {
            // 보류 없음, 또는 초성 없는 모음만 보류 중
            flush()
            initial = jamo
            return
        }
        guard medial != nil else {
            // 초성끼리 쌍자음으로 합치지 않는다 (ㄱㄱ)
            flush()
            initial = jamo
            return
        }
        if let currentFinal = final {
            if let compound = DubeolsikLayout.compoundFinals[String([currentFinal, jamo])] {
                final = compound
            } else {
                flush()
                initial = jamo
            }
        } else if DubeolsikLayout.jongseong.contains(jamo) {
            final = jamo
        } else {
            // ㄸ·ㅃ·ㅉ는 받침이 될 수 없다
            flush()
            initial = jamo
        }
    }

    private mutating func feedVowel(_ jamo: Character) {
        if let currentFinal = final {
            // 받침 이동: 겹받침은 뒤 자음만, 단일 받침은 통째로 다음 음절 초성이 된다
            let parts = DubeolsikLayout.components(of: currentFinal)
            let moved: Character
            if parts.count == 2 {
                final = parts[0]
                moved = parts[1]
            } else {
                final = nil
                moved = currentFinal
            }
            flush()
            initial = moved
            medial = jamo
            return
        }
        if let currentMedial = medial {
            if let compound = DubeolsikLayout.compoundVowels[String([currentMedial, jamo])] {
                medial = compound
            } else {
                flush()
                medial = jamo
            }
            return
        }
        if initial != nil {
            medial = jamo
        } else {
            flush()
            medial = jamo
        }
    }

    /// 보류 상태를 출력에 확정한다. 음절을 만들 수 없으면 자모 그대로 출력(ㅋㅋ, ㅠㅠ).
    private mutating func flush() {
        if let currentInitial = initial, let currentMedial = medial,
           let syllable = Self.syllable(initial: currentInitial, medial: currentMedial, final: final) {
            output.append(syllable)
        } else {
            if let initial { output.append(initial) }
            if let medial { output.append(medial) }
            if let final { output.append(final) }
        }
        initial = nil
        medial = nil
        final = nil
    }

    /// 초성·중성·(종성) 자모 → 완성형 음절. U+AC00 + ((초성 × 21) + 중성) × 28 + 종성
    static func syllable(initial: Character, medial: Character, final: Character?) -> Character? {
        guard let initialIndex = DubeolsikLayout.choseong.firstIndex(of: initial),
              let medialIndex = DubeolsikLayout.jungseong.firstIndex(of: medial) else {
            return nil
        }
        var finalIndex = 0
        if let final {
            guard let index = DubeolsikLayout.jongseong.firstIndex(of: final) else { return nil }
            finalIndex = index + 1
        }
        let value = 0xAC00 + ((initialIndex * 21) + medialIndex) * 28 + finalIndex
        return Unicode.Scalar(value).map(Character.init)
    }
}
