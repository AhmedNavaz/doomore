import Foundation

/// Developer decision, 25 November 2026: capture at the camera's native 1280×720 mode.
/// Chosen over 1920×1080 (more pixels to process) and 640×480 (different aspect, smallest phone).
enum CaptureFormatChoice {
    static let width = 1280
    static let height = 720

    /// Plain description of one `AVCaptureDeviceFormat`, so selection is testable without a camera.
    struct Candidate: Equatable {
        let width: Int
        let height: Int
        let maxFrameRate: Double
        /// True for the camera's 4:2:0 video-range format (`420v`), the format the built-in camera lists.
        let isVideoRange420: Bool
    }

    /// Index of the exact 1280×720 mode to use, or nil when the camera has none.
    /// Exact dimensions only: no scaling, cropping or nearby size is substituted.
    /// Among exact matches, prefer `420v`, then the highest maximum frame rate, then the first listed.
    static func select(from candidates: [Candidate]) -> Int? {
        candidates.indices
            .filter { candidates[$0].width == width && candidates[$0].height == height }
            .min { a, b in
                let ca = candidates[a], cb = candidates[b]
                if ca.isVideoRange420 != cb.isVideoRange420 { return ca.isVideoRange420 }
                if ca.maxFrameRate != cb.maxFrameRate { return ca.maxFrameRate > cb.maxFrameRate }
                return a < b
            }
    }
}
