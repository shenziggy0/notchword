import AppKit

/// 刘海几何：真实刘海用系统可用区域推算，无刘海机型退回模拟形态。
///
/// 注意：不能用「缺失刘海区域就当成整屏宽度」的做法，否则面板会铺满整块屏幕。
struct NotchGeometry {

    static let fallbackNotchWidth: CGFloat = 200

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let isSimulated: Bool

    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let height = max(screen.safeAreaInsets.top, 32)

        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width >= 80 {
                return NotchGeometry(notchWidth: width, notchHeight: height, isSimulated: false)
            }
        }
        return NotchGeometry(notchWidth: fallbackNotchWidth, notchHeight: height, isSimulated: true)
    }

    var expandedWidth: CGFloat { max(474, notchWidth + 240) }
    var compactWidth: CGFloat { max(340, notchWidth + 140) }

    /// 内容距离屏幕上沿的留白：真实刘海必须让开；模拟形态只需一点呼吸。
    var contentTopInset: CGFloat { isSimulated ? 12 : notchHeight }

    func frame(for screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }
}
