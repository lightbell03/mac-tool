import Foundation

/// 방향별 한영 복원. 대상이 아닌 문자(숫자·기호·공백·개행·이모지·반대 언어)는 그대로 둔다.
public enum KeyboardLayoutConverter {
    public static func convert(_ text: String, direction: ConversionDirection) -> String {
        switch direction {
        case .englishToHangul: return HangulComposer.compose(text)
        case .hangulToEnglish: return keys(forHangul: text)
        }
    }

    private static let syllableRange: ClosedRange<UInt32> = 0xAC00...0xD7A3
    private static let compatibilityJamoRange: ClosedRange<UInt32> = 0x3131...0x318E

    /// 한글 → 표준 두벌식 키 문자열.
    static func keys(forHangul text: String) -> String {
        var output = String.UnicodeScalarView()
        func appendKeys(for jamo: Character) {
            for part in DubeolsikLayout.components(of: jamo) {
                if let key = DubeolsikLayout.jamoToKey[part] {
                    output.append(contentsOf: key.unicodeScalars)
                } else {
                    // 옛한글 등 키가 없는 호환 자모는 그대로
                    output.append(contentsOf: part.unicodeScalars)
                }
            }
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if syllableRange.contains(value) {
                let index = Int(value - 0xAC00)
                appendKeys(for: DubeolsikLayout.choseong[index / (21 * 28)])
                appendKeys(for: DubeolsikLayout.jungseong[(index % (21 * 28)) / 28])
                let finalIndex = index % 28
                if finalIndex > 0 {
                    appendKeys(for: DubeolsikLayout.jongseong[finalIndex - 1])
                }
            } else if compatibilityJamoRange.contains(value) {
                appendKeys(for: Character(scalar))
            } else if let jamo = compatibilityJamo(forConjoining: scalar) {
                appendKeys(for: jamo)
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// 조합형(첫가끝) 현대 자모 → 호환 자모. 대상이 아니면 nil.
    static func compatibilityJamo(forConjoining scalar: Unicode.Scalar) -> Character? {
        let value = Int(scalar.value)
        switch value {
        case 0x1100...0x1112: return DubeolsikLayout.choseong[value - 0x1100]
        case 0x1161...0x1175: return DubeolsikLayout.jungseong[value - 0x1161]
        case 0x11A8...0x11C2: return DubeolsikLayout.jongseong[value - 0x11A8]
        default: return nil
        }
    }
}
