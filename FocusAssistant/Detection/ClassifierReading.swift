import Foundation

/// One whole-image classifier sample, reduced to what the diagnostics window shows.
/// Scores are uncalibrated per-label model outputs. They carry no location and are
/// never evidence that a phone is held or in use.
struct ClassifierReading: Sendable, Equatable {
    /// Matched exactly: `payphone`, `headphones` and similar labels are other classes.
    /// Installed availability of this identifier is recorded in docs/model-evaluation.md.
    static let phoneIdentifier = "phone"

    /// Highest-scoring labels, descending.
    let topLabels: [Classification]
    /// Score of the exact `phone` label; nil when the classifier reported no usable score for it.
    let phoneConfidence: Float?
    /// Number of labels scoring strictly above `phone`; nil when `phone` is absent.
    /// A count is used instead of a rank because many labels can tie, for example at zero.
    let labelsAbovePhone: Int?
    /// Number of labels with a usable (finite) score in this sample.
    let labelCount: Int

    /// Orders by score rather than trusting the order the classifier returned.
    /// Non-finite scores are dropped, not ranked.
    static func summarize(_ scored: [Classification], topCount: Int = 5) -> ClassifierReading {
        let usable = scored.filter { $0.confidence.isFinite }
        let ordered = usable.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.label < $1.label
        }
        let phone = usable.first { $0.label == phoneIdentifier }
        return ClassifierReading(
            topLabels: Array(ordered.prefix(max(0, topCount))),
            phoneConfidence: phone?.confidence,
            labelsAbovePhone: phone.map { phone in usable.filter { $0.confidence > phone.confidence }.count },
            labelCount: usable.count
        )
    }
}
