import SwiftUI

/// 界面设计规范（Design Tokens）。
///
/// 职责边界：
/// - **本文件只管「界面长什么样」**：字号/行高/字重、间距、圆角、颜色、阴影外观。
/// - **刘海几何不在这里**：窗口尺寸、展开尺寸、阴影余量、刘海顶部/底部圆角、chin 高度
///   都属于窗口层参数，继续留在 `ScreenGeometry` / `NotchViewModel`，不要混进来。
///
/// 规则（见 README「界面设计规范」）：视图层只能引用这里的 token；需要新档位时先改规范再加 token，
/// 不允许在视图里写裸的字号、行高、间距、圆角、颜色。`--selftest` 里有一项静态检查会扫描
/// `*View.swift`，发现裸字面量就 FAIL 并列出位置。
enum DesignSystem {

    // MARK: - 字体

    /// 一段文字的完整排版规格：字号 + 字重 + 字体族 + 行高。
    ///
    /// 行高按「行盒总高」理解：`lineSpacing` 是 SwiftUI 在系统默认行高之外追加的间距，
    /// 系统默认行高约为 `size × 1.21`（SF 的 ascent + descent），故差值即需要追加的部分。
    struct TextStyle {
        let size: CGFloat
        let weight: Font.Weight
        let design: Font.Design
        let lineHeight: CGFloat

        var font: Font {
            .system(size: size, weight: weight, design: design)
        }

        var lineSpacing: CGFloat {
            max(0, lineHeight - size * 1.21)
        }
    }

    enum Typography {
        /// 主信息：首页曲名。14pt / 18pt 行高。
        static let title = TextStyle(size: 14, weight: .semibold, design: .rounded, lineHeight: 18)
        /// 正文：副信息、空状态说明、占位文字。11pt / 15pt 行高。
        static let body = TextStyle(size: 11, weight: .regular, design: .default, lineHeight: 15)
    }

    // MARK: - 间距（4 的倍数）

    /// 间距阶梯。只保留当前有使用点的档位：需要新档位时先改规范再加。
    enum Spacing {
        /// 0pt：结构对齐用（例如顶对齐的 VStack 不允许子视图被默认间距推开）。
        static let none: CGFloat = 0
        /// 4pt：Tab 命中区之间的间隙、胶囊标签的纵向内边距。
        static let xs: CGFloat = 4
        /// 8pt：行内元素间距、胶囊标签的横向内边距。
        static let sm: CGFloat = 8
        /// 12pt：chrome 行与内容块之间的纵向间距。
        static let md: CGFloat = 12
        /// 16pt：展开态四边统一内边距（内容贴着屏幕顶边时仍留出 16pt 呼吸）。
        static let lg: CGFloat = 16
    }

    // MARK: - 尺寸

    enum Size {
        /// 1pt 发丝线：阴影遮罩、空状态虚线描边。
        static let hairline: CGFloat = 1
        /// 16pt：Tab 图标、播放控制图标的绘制尺寸（命中区用 Control 档位）。
        static let icon: CGFloat = 16
        /// 20pt：文件架每行的文件图标边长。语义独立于「闭合态徽标」，
        /// 以后调整其中一处不会牵连另一处。
        static let fileIcon: CGFloat = 20
        /// 24pt：封面占位里的音符图标。
        static let coverGlyph: CGFloat = 24
        /// 56pt：首页封面位边长，也是首页内容行的高度。
        static let cover: CGFloat = 56
        /// 20pt：闭合态封面缩略图边长（常驻信息在刘海右侧的投影）。
        static let closedBadge: CGFloat = 20
        /// 420pt：播放器兼容设置窗口的内容宽度（独立窗口，不占刘海面板的高度预算）。
        static let settingsWidth: CGFloat = 420
        /// 720pt：设置窗口 `fittingSize` 拿不到时的回退高度（独立窗口，同样不占面板预算）。
        static let settingsFallbackHeight: CGFloat = 720
        /// 8pt：闭合态无封面时跳动条的最高档。
        static let eqBarHeight: CGFloat = 8
        /// 2pt：跳动条宽度。
        static let eqBarWidth: CGFloat = 2
        /// 2pt：跳动条之间的间隙。
        static let eqBarGap: CGFloat = 2
        /// 36×20：设置窗口里开关轨道的视觉尺寸（自绘控件，`ImageRenderer` 也能离屏渲染）。
        static let switchWidth: CGFloat = 36
        static let switchHeight: CGFloat = 20
        /// 16pt：开关圆点直径。
        static let switchKnob: CGFloat = 16
        /// 2pt：圆点到轨道边缘的间距（(20 − 16) / 2）。
        static let switchInset: CGFloat = 2
    }

    // MARK: - 控件尺寸（高度阶梯）

    /// 控件高度阶梯：20 / 24 / 28 / 32。
    ///
    /// 视图里只允许引用这些档位，不允许给控件写 `frame(height: 23)` 之类的裸值。
    /// 需要新档位时先改规范和这张表。
    enum Control {
        /// 20pt：Tab 选中色块的**视觉**尺寸（图标 16 居中，四周 2pt 呼吸）。
        static let xs: CGFloat = 20
        /// 24pt：上一首 / 下一首按钮的命中区。
        static let sm: CGFloat = 24
        /// 28pt：唯一一行 chrome 的高度；也是 Tab 的**命中区**（图标 16、选中块 20 居中，
        /// 四周透明扩边）与播放大按钮直径。
        static let md: CGFloat = 28
        /// 32pt：文件架空状态区高度。
        static let lg: CGFloat = 32
    }

    // MARK: - 圆角（界面元素）

    /// 只用于界面元素（Tab 选中块、封面位等）。刘海的顶部/底部圆角属于窗口几何，不在此处。
    enum Radius {
        /// 4pt：Tab 选中色块圆角 / 空状态虚框圆角。
        static let small: CGFloat = 4
        /// 8pt：封面位圆角。
        static let medium: CGFloat = 8
    }

    // MARK: - 颜色语义

    enum Colors {
        /// 面板底色 / 刘海填充色。
        static let surface = Color.black
        /// 几乎透明的黑色遮罩：刘海下方的 chin，用来避免露缝。
        static let surfaceVeil = Color.black.opacity(0.01)
        /// 主文本。
        static let textPrimary = Color.white
        /// 次文本：说明段落。
        static let textSecondary = Color.white.opacity(0.65)
        /// 三级文本：未选中的 Tab 图标、空状态说明。
        static let textTertiary = Color.white.opacity(0.55)
        /// 分隔 / 描边：空状态虚线框。
        static let divider = Color.white.opacity(0.12)
        /// 色块底：Tab 选中块、封面占位底。
        static let badgeFill = Color.white.opacity(0.1)
    }

    // MARK: - 效果

    /// 阴影外观（方向性：只在下方与两侧下缘投影）。
    ///
    /// 一圈均匀投影（`.shadow(0.7, radius: 6)`）在贴屏幕顶边的面板上会让左右两侧形成
    /// 从 y=0 一路向下的竖向暗带，看起来像浮在屏幕上的卡片，而不是从顶边延伸出来的形状。
    /// 这里把半径和不透明度都降到系统菜单栏附近浮层的量级，并用 `panelShadowFade*`
    /// 把顶部一段排除在投影源之外（遮掉的部分不产生阴影），只留下方与两侧下缘。
    /// 取值依据见 README「界面设计规范」的 Effects 表与「方向性阴影」一节。
    enum Effects {
        /// 4pt：阴影模糊半径。收紧到系统菜单栏附近浮层的量级，避免两侧大范围晕开。
        static let panelShadowRadius: CGFloat = 4
        /// 0.35：展开态阴影不透明度。实测有效峰值 0.195，落在浮层量级。
        static let panelShadowOpacityOpen: Double = 0.35
        /// 闭合态完全不投影：闭合形状就是刘海本身，不能有厚度感。
        static let panelShadowOpacityClosed: Double = 0
        /// 2pt：阴影整体下移，营造「光从上方来」的方向感。
        static let panelShadowOffsetY: CGFloat = 2
        /// 0.25：形状高度顶部 25% 完全不参与投影（遮罩 alpha = 0），保证 y=0 附近没有暗带。
        static let panelShadowFadeStart: CGFloat = 0.25
        /// 0.75：到高度 75% 处阴影完全显示，即只有下方与两侧下缘有阴影。
        static let panelShadowFadeEnd: CGFloat = 0.75
        /// 阴影遮罩的透明端（alpha = 0）：这一段形状不产生任何阴影。
        static let panelShadowMaskClear = Color.clear
        /// 阴影遮罩的不透明端（alpha = 1）：遮罩只读 alpha，颜色本身不参与合成。
        static let panelShadowMaskOpaque = Color.black
    }
}

extension View {
    /// 套用一段排版规格（字号 + 字重 + 字体族 + 行高）。
    func textStyle(_ style: DesignSystem.TextStyle) -> some View {
        font(style.font).lineSpacing(style.lineSpacing)
    }

    /// 单行文字按规范行高占位。
    ///
    /// `lineSpacing` 只影响多行之间的间距，单行 `Text` 的高度仍是字体自身行高
    /// （11pt 实际约 13pt，比规范的 15pt 少 1~2pt）。这 1~2pt 会让
    /// 「内容自然高 + 内边距」算出来的面板高度和实际渲染差几像素，四边留白就对不齐。
    /// 这里把单行文本固定成规范行高，让 `PageMetrics` 的算术和渲染结果一致。
    func textLineBox(_ style: DesignSystem.TextStyle) -> some View {
        textStyle(style).frame(height: style.lineHeight, alignment: .leading)
    }
}
