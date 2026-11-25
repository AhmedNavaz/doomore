import CoreGraphics

enum PreviewGeometry {
    /// Maps an original-image Vision box to a top-left-origin, aspect-fit preview.
    /// The capture/model image is unmirrored; mirroring affects only presentation.
    /// Off-image boxes are clipped. Invalid or wholly off-image boxes return nil.
    static func rect(
        for boundingBox: CGRect,
        imageSize: CGSize,
        viewSize: CGSize,
        mirrored: Bool
    ) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              viewSize.width.isFinite, viewSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0,
              boundingBox.origin.x.isFinite, boundingBox.origin.y.isFinite,
              boundingBox.size.width.isFinite, boundingBox.size.height.isFinite,
              boundingBox.size.width > 0, boundingBox.size.height > 0,
              boundingBox.maxX.isFinite, boundingBox.maxY.isFinite else {
            return nil
        }

        let clipped = boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let contentWidth = imageSize.width * scale
        let contentHeight = imageSize.height * scale
        guard scale.isFinite, scale > 0, contentWidth.isFinite, contentHeight.isFinite,
              contentWidth > 0, contentHeight > 0 else { return nil }

        let contentX = (viewSize.width - contentWidth) / 2
        let contentY = (viewSize.height - contentHeight) / 2
        let x = mirrored ? 1 - clipped.maxX : clipped.minX
        return CGRect(
            x: contentX + x * contentWidth,
            y: contentY + (1 - clipped.maxY) * contentHeight,
            width: clipped.width * contentWidth,
            height: clipped.height * contentHeight
        )
    }
}
