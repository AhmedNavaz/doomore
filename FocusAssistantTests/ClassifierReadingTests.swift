import XCTest
@testable import FocusAssistant

/// Pure selection logic only. These synthetic scores say nothing about what the
/// installed classifier reports for a real camera frame.
final class ClassifierReadingTests: XCTestCase {
    func testOrdersByScoreRegardlessOfInputOrder() {
        let reading = ClassifierReading.summarize([
            Classification(label: "desk", confidence: 0.2),
            Classification(label: "people", confidence: 0.9),
            Classification(label: "indoor", confidence: 0.5)
        ], topCount: 2)

        XCTAssertEqual(reading.topLabels, [
            Classification(label: "people", confidence: 0.9),
            Classification(label: "indoor", confidence: 0.5)
        ])
        XCTAssertEqual(reading.labelCount, 3)
        XCTAssertNil(reading.phoneConfidence)
        XCTAssertNil(reading.labelsAbovePhone)
    }

    func testPhoneScoreIsReportedEvenOutsideTopLabels() {
        var scored = (1...6).map { Classification(label: "other\($0)", confidence: Float($0) / 10) }
        scored.insert(Classification(label: "phone", confidence: 0.01), at: 3)
        scored.append(Classification(label: "lower", confidence: 0.001))

        let reading = ClassifierReading.summarize(scored)

        XCTAssertEqual(reading.topLabels.count, 5)
        XCTAssertFalse(reading.topLabels.contains { $0.label == "phone" })
        XCTAssertEqual(reading.phoneConfidence, 0.01)
        XCTAssertEqual(reading.labelsAbovePhone, 6)
        XCTAssertEqual(reading.labelCount, 8)
    }

    func testPhoneCanBeTheTopLabel() {
        let reading = ClassifierReading.summarize([
            Classification(label: "indoor", confidence: 0.3),
            Classification(label: "phone", confidence: 0.8)
        ])
        XCTAssertEqual(reading.topLabels.first, Classification(label: "phone", confidence: 0.8))
        XCTAssertEqual(reading.phoneConfidence, 0.8)
        XCTAssertEqual(reading.labelsAbovePhone, 0)
    }

    func testOnlyTheExactPhoneIdentifierCounts() {
        let reading = ClassifierReading.summarize([
            Classification(label: "payphone", confidence: 0.9),
            Classification(label: "headphones", confidence: 0.8),
            Classification(label: "microphone", confidence: 0.7),
            Classification(label: "Phone", confidence: 0.6)
        ])
        XCTAssertNil(reading.phoneConfidence)
        XCTAssertNil(reading.labelsAbovePhone)
        XCTAssertEqual(reading.labelCount, 4)
    }

    func testTiedScoresAreNotCountedAsHigherAndOrderIsDeterministic() {
        let reading = ClassifierReading.summarize([
            Classification(label: "zebra", confidence: 0),
            Classification(label: "phone", confidence: 0),
            Classification(label: "apple", confidence: 0),
            Classification(label: "indoor", confidence: 0.4)
        ], topCount: 3)

        XCTAssertEqual(reading.phoneConfidence, 0)
        XCTAssertEqual(reading.labelsAbovePhone, 1)
        XCTAssertEqual(reading.topLabels.map(\.label), ["indoor", "apple", "phone"])
    }

    func testNonFiniteScoresAreDroppedNotRanked() {
        let reading = ClassifierReading.summarize([
            Classification(label: "broken", confidence: .nan),
            Classification(label: "huge", confidence: .infinity),
            Classification(label: "negative", confidence: -.infinity),
            Classification(label: "indoor", confidence: 0.4),
            Classification(label: "phone", confidence: 0.1)
        ])
        XCTAssertEqual(reading.topLabels.map(\.label), ["indoor", "phone"])
        XCTAssertEqual(reading.labelsAbovePhone, 1)
        XCTAssertEqual(reading.labelCount, 2)

        let unusablePhone = ClassifierReading.summarize([
            Classification(label: "phone", confidence: .nan),
            Classification(label: "indoor", confidence: 0.4)
        ])
        XCTAssertNil(unusablePhone.phoneConfidence)
        XCTAssertNil(unusablePhone.labelsAbovePhone)
        XCTAssertEqual(unusablePhone.labelCount, 1)
    }

    func testEmptyInputAndNonPositiveTopCount() {
        let empty = ClassifierReading.summarize([])
        XCTAssertTrue(empty.topLabels.isEmpty)
        XCTAssertNil(empty.phoneConfidence)
        XCTAssertNil(empty.labelsAbovePhone)
        XCTAssertEqual(empty.labelCount, 0)

        let scored = [Classification(label: "phone", confidence: 0.5)]
        XCTAssertTrue(ClassifierReading.summarize(scored, topCount: 0).topLabels.isEmpty)
        XCTAssertTrue(ClassifierReading.summarize(scored, topCount: -3).topLabels.isEmpty)
        XCTAssertEqual(ClassifierReading.summarize(scored, topCount: 0).phoneConfidence, 0.5)
    }
}
