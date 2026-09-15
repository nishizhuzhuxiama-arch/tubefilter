import SwiftUI

/// 主题色与层次色。
///
/// `Color(_ uiColor:)` 与 `Color(uiColor:)` 都要到 iOS 15 才可用，而本工程部署目标是
/// iOS 14.2，因此这里不用 UIColor 桥接，改为用系统色阶叠加构造层次，
/// 保证在浅色与深色模式下都能拉开层级。
extension Color {
    /// 二级背景：卡片外的分组底色。
    static var tfSurface: Color { Color.gray.opacity(0.14) }
    /// 三级背景：比二级更浅一档，用于标签与胶囊。
    static var tfSurfaceElevated: Color { Color.gray.opacity(0.09) }
}
