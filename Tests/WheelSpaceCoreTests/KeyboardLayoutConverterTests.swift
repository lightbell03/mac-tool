import XCTest
@testable import WheelSpaceCore

/// trans-plan 11.1 기대값. 기대값은 구현과 별개로 고정한다.
final class KeyboardLayoutConverterTests: XCTestCase {
    private func toHangul(_ text: String) -> String {
        KeyboardLayoutConverter.convert(text, direction: .englishToHangul)
    }

    private func toEnglish(_ text: String) -> String {
        KeyboardLayoutConverter.convert(text, direction: .hangulToEnglish)
    }

    // MARK: - 영문 → 한글

    func testSentences() {
        XCTAssertEqual(toHangul("dkssudgktpdy"), "안녕하세요")
        XCTAssertEqual(toHangul("rkatkgkqslek"), "감사합니다")
        XCTAssertEqual(toHangul("gksrmf"), "한글")
    }

    func testFinalMovesToNextInitial() {
        XCTAssertEqual(toHangul("rksk"), "가나")
    }

    func testCompoundFinal() {
        XCTAssertEqual(toHangul("rkqt"), "값")
        XCTAssertEqual(toHangul("rkqtdl"), "값이")
    }

    func testCompoundFinalSplitsBeforeVowel() {
        XCTAssertEqual(toHangul("rkqtk"), "갑사")
        XCTAssertEqual(toHangul("dlfrdj"), "읽어")
    }

    func testCompoundVowels() {
        XCTAssertEqual(toHangul("rhk"), "과")
        XCTAssertEqual(toHangul("rnj"), "궈")
        XCTAssertEqual(toHangul("rml"), "긔")
        XCTAssertEqual(toHangul("qnpfr"), "뷁")
    }

    func testShiftDoubleConsonants() {
        XCTAssertEqual(toHangul("Rk Ek Qk Tk Wk"), "까 따 빠 싸 짜")
        XCTAssertEqual(toHangul("dO dP"), "얘 예")
        XCTAssertEqual(toHangul("rkT"), "갔")
    }

    func testOtherUppercaseSameAsLowercase() {
        XCTAssertEqual(toHangul("DKSSUD"), "안녕")
    }

    func testInitialsDoNotMergeIntoDoubles() {
        XCTAssertEqual(toHangul("rr"), "ㄱㄱ")
    }

    func testDoubleConsonantThatCannotBeFinalStartsNewSyllable() {
        XCTAssertEqual(toHangul("rkEk"), "가따")
    }

    func testStandaloneJamoPreserved() {
        XCTAssertEqual(toHangul("zz"), "ㅋㅋ")
        XCTAssertEqual(toHangul("bb"), "ㅠㅠ")
        XCTAssertEqual(toHangul("hk"), "ㅘ")
    }

    func testBoundariesPreserved() {
        XCTAssertEqual(toHangul("dkssud! 123\n반가워 😊"), "안녕! 123\n반가워 😊")
        XCTAssertEqual(toHangul("rk\trk\r\nrk"), "가\t가\r\n가")
    }

    func testEmptyAndEmojiOnlyUnchanged() {
        XCTAssertEqual(toHangul(""), "")
        XCTAssertEqual(toHangul("😊👍"), "😊👍")
    }

    // MARK: - 한글 → 영문

    func testHangulToKeys() {
        XCTAssertEqual(toEnglish("안녕하세요"), "dkssudgktpdy")
        XCTAssertEqual(toEnglish("과"), "rhk")
        XCTAssertEqual(toEnglish("값"), "rkqt")
        XCTAssertEqual(toEnglish("까"), "Rk")
        XCTAssertEqual(toEnglish("얘"), "dO")
    }

    func testCompatibilityJamoToKeys() {
        XCTAssertEqual(toEnglish("ㅗ디ㅣㅐ"), "hello")
        XCTAssertEqual(toEnglish("ㅘㄳ"), "hkrt")
    }

    func testConjoiningJamoToKeys() {
        let decomposed = "안녕".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(decomposed.unicodeScalars.count, 2)
        XCTAssertEqual(toEnglish(decomposed), "dkssud")
    }

    func testNonHangulPreserved() {
        XCTAssertEqual(toEnglish("Hello 123 😊\n"), "Hello 123 😊\n")
    }

    // MARK: - 왕복

    func testAllModernSyllablesRoundTrip() {
        var failures: [String] = []
        for value in 0xAC00...0xD7A3 {
            let syllable = String(Character(Unicode.Scalar(value)!))
            let roundTrip = toHangul(toEnglish(syllable))
            if roundTrip != syllable { failures.append(syllable) }
        }
        XCTAssertEqual(failures, [], "왕복 실패 \(failures.count)자")
    }

    func testLongTextPerformance() {
        let text = String(repeating: "dkssudgktpdy rkatkgkqslek. ", count: 400) // 약 10,800자
        measure {
            _ = toHangul(text)
        }
    }
}
