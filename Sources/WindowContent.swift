import AppKit
import WebKit

// A WKWebView consumes mouse events even under a transparent native title bar.
// Give the non-interactive header a native drag surface; leave controls/editing
// to WebKit and the standard macOS window buttons.
final class WindowContent: NSView {
    let dragRegion: WindowDragRegion

    init(webView: WKWebView, headerHeight: CGFloat, trailingControlsWidth: CGFloat) {
        let frame = webView.frame
        dragRegion = WindowDragRegion(frame: NSRect(
            x: 82, y: frame.height - headerHeight,
            width: max(0, frame.width - 82 - trailingControlsWidth), height: headerHeight
        ))
        super.init(frame: frame)
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        dragRegion.autoresizingMask = [.width, .minYMargin]
        dragRegion.toolTip = "드래그하여 창 이동"
        addSubview(dragRegion, positioned: .above, relativeTo: webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class WindowDragRegion: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
