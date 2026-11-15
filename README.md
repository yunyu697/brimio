# Brimio

一个零第三方依赖的 macOS 刘海窗口最小实现，用来验证「固定窗口尺寸 + 内容高度插值 + clipShape 裁切 + contentShape 命中 + 延时 hover 开合 + 显式点击穿透」这套窗口层架构。

## 运行

```bash
cd outputs
swift run Brimio            # 正常运行：屏幕顶部出现刘海，悬停展开，移开收起
swift run Brimio --selftest # 自测几何/状态机/穿透开关，输出 PASS/FAIL 后退出
swift run Brimio --e2e      # 真实指针移动测试（会短暂移动鼠标并复原）
swift run Brimio --show-open# 启动后直接展开，方便肉眼检查/截图
swift run Brimio --render /tmp/notch-render  # 离屏渲染闭合/展开两态 PNG（不需要录屏权限）
swift run Brimio --animate-probe            # 采样开合过程的中间帧，证明动画真的在插值（仅 DEBUG 构建）
swift run Brimio --shadow-probe [dir]       # 离屏渲染不带红线的干净图并逐像素量阴影（侧边/顶边/底部）
swift run Brimio --media-probe [--out f]    # 用 AppleScript 读一次当前播放信息（不跑 UI）
swift run Brimio --presence-probe           # 实测 IOPM 播放状态通道 + CoreAudio 事件源，并验证暂停/退出/UI 三种降级
swift run Brimio --power-probe              # 同进程 A/B：复核表 ON/OFF 各 20s，先校准仪器再测唤醒
swift run Brimio --window-probe             # 五个时间点采样 frame/contentLayout/CG bounds/backing/DisplayMode，并建同尺寸对照窗口
swift run Brimio --shoulder-probe           # @4x 逐行量闭合形状左右肩内缩量，与二次曲线解析解对比，并裁剪放大图
```

要求：macOS 13+、Xcode Command Line Tools（Swift 5.9+）。无网络、无第三方包。

如果希望把编译产物放到别处：

```bash
swift build --scratch-path /tmp/notch-build \
            --cache-path /tmp/notch-cache \
            --config-path /tmp/notch-config \
            --security-path /tmp/notch-security
```

## 代码结构

| 文件 | 职责 |
|---|---|
| `ScreenGeometry.swift` | 尺寸常量、刘海判定、屏幕顶部矩形计算、屏幕 UUID |
| `NotchShape.swift` | 刘海外形：顶边两角各一段控制点落在顶边上的二次曲线、底部外扩曲线，顶部圆角闭合 6 / 展开 0、底部 14/24，两个圆角都参与 `animatableData` |
| `NotchPanel.swift` | `NSPanel` 子类：无边框/非激活/置顶/透明，`setInteractive(_:)` 控制点击穿透 |
| `NotchViewModel.swift` | `closed/open` 状态机、`notchSize`、唯一动画源 |
| `NotchWindowController.swift` | 建窗、定位、鼠标监听、延时开合、穿透切换 |
| `NotchRootView.swift` | SwiftUI 根视图：布局、裁切、命中、唯一动画源（只引用 `DesignSystem` token） |
| `ExpandedContentView.swift` | 展开态骨架：唯一一行 28pt chrome（图标 Tab）+ 页面容器（四页常驻、按 route 切 opacity） |
| `ExpandedItem.swift` | 展开态路由枚举 + `PageMetrics`（内容尺寸 → 形状尺寸的换算与上下限） |
| `FileShelfView.swift` | 文件架：`ShelfItem` 模型、`FileShelfStore`（添加/去重/移除/判活）、`FileShelfLayout`（行高 32 / 间距 8 / 视口 140）、列表视图与 `FileDropDelegate` |
| `PlayerRegistry.swift` | 播放器兼容分组与开关：Music/Spotify 恒开（Automation），第三方默认关，`allowsReading` 是读取闸门 |
| `PlayerSettingsWindow.swift` | 独立设置窗口（420pt）：7 个播放器逐项写清权限 / 收益 / 不开启的后果 |
| `DesignSystem.swift` | 界面设计规范：字号/行高/字重、间距、圆角、颜色语义、控件高度阶梯、阴影外观 |
| `DESIGN.md` | 信息分级规范（常驻 / 临时 / 不显示）+ 四页分级表 + 播放器兼容与权限 + 后续功能的前置门槛 |
| `main.swift` | AppKit 启动入口 + 自测/端到端/动画采样/离屏渲染/界面规范静态检查 |

## 关键设计

**1. 窗口尺寸固定，只有内容尺寸变化（且跟着当前页走）**

`ScreenGeometry.windowSize = 316 × 232`（= 最大页形状 300×212 + 16pt 动画超调余量（宽）+ 20pt 阴影余量（高）；`maxShapeSize` 取所有页面里最大者，文件架溢出态 248×212 之前先由上限 640×212 决定，实际最大页是播放器兼容/文件架溢出态 300×212 与 248×212）。窗口从创建到销毁都不 resize；`NotchRootView` 用 `.frame(width:height:)` 把内容在 `closedSize` 与**当前页的形状尺寸**之间插值，再由 `clipShape(NotchShape(...))` 裁出外形。这样避免了窗口 resize 带来的坐标抖动和动画不同步，同时宽度余量保证 spring 超调的那几帧不会被窗口边界平切。

**2. 命中区域与视觉区域分离**

- `clipShape` 只影响绘制，不影响命中；
- `.contentShape(Rectangle())` 把整块布局矩形声明为可命中，保证按钮之间、圆角之外的空隙也能响应点击；
- 真正限制"哪些屏幕区域属于这个 App"的是窗口层：`NotchPanel.ignoresMouseEvents`。

**3. 显式点击穿透**

透明区域是否会吃掉菜单栏点击，取决于 AppKit/SwiftUI 的默认命中行为，不受控。这里改成显式控制：

- 闭合时 `ignoresMouseEvents = true`，整个 316×232 窗口对鼠标透明，点击直接落到下层 App；
- 指针进入当前状态的可交互矩形（闭合 = 刘海矩形，展开 = 展开矩形，各外扩 6pt）时切到 `false`；
- 收起动画结束后切回 `true`。

指针位置来自 `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents`（`mouseMoved` / 拖拽）。之所以不用 SwiftUI 的 `.onHover` 作为主路径：窗口在闭合态穿透，SwiftUI 根本收不到 hover 事件，必须有一个窗口外的指针来源。

**4. 动画只保留一处，并且挂在「发生尺寸变化」的那一层**

`NotchViewModel` 只暴露一条曲线给视图：`.animation(vm.isOpen ? openAnimation : closeAnimation, value: vm.notchSize)`，挂在内容链最后一层（`.frame` / `.background` / `.clipShape` / `.shadow` 都在它的子树里）；调用方（`open()` / `close()` / hover 任务 / 点击）都不包 `withAnimation`，避免出现第二个动画源。

两个关键点，都是踩坑后定下来的：

- **触发值必须是 `vm.notchSize`，不是 `vm.isOpen`**。旧实现里 `notchSize` 和 `state` 是两次独立的 `@Published` 变更：SwiftUI 先看到「尺寸已经变成 190、状态还是 closed」，此时 `value: isOpen` 没变，尺寸变化没拿到曲线，于是瞬变。现在 `notchSize` 从 `state` 派生，一次开合只产生一次变更；
- **采样器/形状必须在该 `.animation` 之前**（即它的子树内）。修饰符顺序是「越靠后越外层」，把 `.background(probe)` 写在 `.animation` 之后就落到动画事务之外，拿不到中间值。

此外 animated 子树里不能出现 `if isOpen { A } else { B }` 这种类型切换：SwiftUI 会当成「移除 + 插入」，动画期间同时存在两份各自插值的副本（采样序列会交出错乱的两条曲线）。所以内容固定为一层 `ZStack`：黑底常驻，展开态文字用 `opacity` 叠加。

顶部圆角 6 → 0、底部圆角 14 → 24 也随状态变化，由 `NotchShape.animatableData` 连续插值（在该文件里加了一行 `--animate-probe` 用的记录钩子，已用 `#if DEBUG` 隔离；路径几何本身不动，只有圆角在插值）。

**5. 开合时序**

- 进入：先 `panel.setInteractive(true)`，再等 `hoverDelay = 0.3s`（防误触：指针只是扫过屏幕顶部时不展开），仍然在矩形内才 `vm.open()`；
- 离开：等 `leaveDelay = 0.1s`（防抖：指针短暂越界不至于收起），仍然在矩形外才 `vm.close()`，然后 `setInteractive(false)`；
- 两个方向都会取消对方的 pending `Task`，避免快速划过时状态抖动。

**6. 顶部对齐与 chin**

内容用 `VStack(spacing: 0)` 从窗口顶部往下排，外层 `.frame(maxWidth/maxHeight, alignment: .top)`，窗口多出的 20pt 只在底部，不产生顶部空隙。刘海下方补一块 `chinHeight = max(0, 菜单栏高 - 刘海高)` 的 `black.opacity(0.01)` 矩形（本机 33 - 32 = 1pt），避免菜单栏底边和形状之间露缝。

## 界面设计规范（Design Tokens）

`DesignSystem.swift` 是界面外观的唯一来源；`NotchRootView.swift` 里不允许再出现裸的字号、行高、间距、圆角、颜色。

**职责边界**（两套东西不混）：

| 归属 | 内容 | 位置 |
|---|---|---|
| 界面规范 | 字号、行高、字重、间距阶梯、界面元素圆角、颜色语义、阴影外观 | `DesignSystem.swift` |
| 窗口层参数 | 窗口尺寸 316×232（= 最大页形状 300×212 + 超调/阴影）、阴影余量 20、刘海顶部/底部圆角（0/6、24/14）、chin 高度、开合 spring | `ScreenGeometry.swift` / `NotchViewModel.swift` / `NotchShape.swift` |

规则：**界面改动只能挂到已有阶梯上；需要新档位时先改本节和 `DesignSystem.swift`，再加 token。**

界面信息先分级再实现：分级规则、判定顺序、三页分级表与「不显示」可删除清单见 [DESIGN.md](./DESIGN.md)。

### 字号 / 行高 / 字重

| Token | 字号 | 行高 | 字重/字体族 | 用途 |
|---|---|---|---|---|
| `Typography.title` | 14 | 18 | semibold / rounded | 首页曲名（常驻信息 ①） |
| `Typography.body` | 11 | 15 | regular / default | 副信息、空状态说明、计时占位 |

行高按「行盒总高」定义；`TextStyle.lineSpacing` 由 `lineHeight - size × 1.21` 折算成 SwiftUI 的追加行距，统一通过 `.textStyle(.xxx)` 应用，避免视图里出现裸 `lineSpacing`。

### 间距阶梯（4 的倍数）

| Token | 值 | 用途 |
|---|---|---|
| `Spacing.none` | 0 | 结构对齐（顶对齐的 `VStack` 不允许子视图被默认间距推开） |
| `Spacing.xs` | 4 | Tab 命中区之间的间隙、胶囊标签纵向内边距 |
| `Spacing.sm` | 8 | 行内元素间距、胶囊标签横向内边距 |
| `Spacing.md` | 12 | chrome 行与内容块之间的纵向间距 |
| `Spacing.lg` | 16 | 展开态四边统一内边距 |

只保留有使用点的档位：原 24pt 档已无使用点，随 padding 降到 16 一并移除。

### 尺寸与圆角

| Token | 值 | 用途 |
|---|---|---|
| `Size.hairline` | 1 | 阴影遮罩、空状态虚线描边 |
| `Size.icon` | 16 | Tab 图标、播放控制图标 |
| `Size.coverGlyph` | 24 | 封面占位里的音符图标 |
| `Size.cover` | 56 | 首页封面位边长，也是首页内容行高 |
| `Size.closedBadge` | 20 | 闭合态封面缩略图边长（刘海右侧） |
| `Size.eqBarHeight` / `eqBarWidth` / `eqBarGap` | 8 / 2 / 2 | 无封面时的三根跳动条 |
| `Control.xs` | 20 | Tab 选中色块的视觉尺寸（图标 16 居中） |
| `Control.sm` | 24 | 上一首 / 下一首按钮命中区 |
| `Control.md` | 28 | 唯一一行 chrome；Tab 命中区（透明扩边）；播放大按钮直径 |
| `Control.lg` | 32 | 文件架空状态区高度 |
| `Radius.small` | 4 | Tab 选中色块、空状态虚框圆角 |
| `Radius.medium` | 8 | 封面位圆角 |

刘海自身的 0/6 与 24/14 圆角属于窗口几何，不在这里。

### 颜色语义

| Token | 取值 | 用途 |
|---|---|---|
| `Colors.surface` | 黑 | 面板底色 / 刘海填充 |
| `Colors.surfaceVeil` | 黑 1% | chin 遮罩（避免菜单栏底边露缝） |
| `Colors.textPrimary` | 白 | 主文本、选中 Tab 图标 |
| `Colors.textSecondary` | 白 65% | 副信息、控制按钮图标 |
| `Colors.textTertiary` | 白 55% | 未选中 Tab 图标、空状态说明 |
| `Colors.divider` | 白 12% | 空状态虚线框描边 |
| `Colors.badgeFill` | 白 10% | Tab 选中色块、封面占位底 |

### 阴影外观（方向性）

阴影不是一圈均匀投影，而是「顶部完全不投影、只在下方与两侧下缘出现」。`.shadow` 本身是四周均匀的，所以视图层把形状自身当作投影源，先用竖向渐变 mask 掉顶部一段（alpha=0 的区域不产生阴影），再发散：

| token | 取值 | 用途 / 依据 |
|---|---|---|
| `Effects.panelShadowRadius` | 4 | 模糊半径。收紧到系统菜单栏附近浮层的量级，避免两侧大范围晕开 |
| `Effects.panelShadowOpacityOpen` | 0.35 | 展开态不透明度。实测有效峰值 0.195，落在浮层量级 |
| `Effects.panelShadowOpacityClosed` | 0 | 闭合态完全不投影：闭合形状就是刘海本身，不能有厚度感 |
| `Effects.panelShadowOffsetY` | 2 | 整体下移 2pt，营造「光从上方来」的方向感 |
| `Effects.panelShadowFadeStart` | 0.25 | 形状高度顶部 25% 不参与投影，保证 y=0 附近没有暗带 |
| `Effects.panelShadowFadeEnd` | 0.75 | 到高度 75% 处阴影完全显示，即只有下方与两侧下缘有 |
| `Effects.panelShadowMaskClear/Opaque` | `.clear` / `.black` | 遮罩两端（遮罩只读 alpha，颜色不参与合成） |

实测数据与判定见下面「方向性阴影」一节。

### 静态检查

`--selftest` 里有三条：`lint discovers every swift file recursively`（守发现面）、`lint checks discovered files minus explicit exemptions`（守实际检查面）与 `view layer uses only DesignSystem tokens`（守 9 条规则）。

**扫描范围 = `Sources/Brimio` 下递归全部 `.swift` 文件 − 显式豁免清单。** 两个历史漏洞都堵掉了：先是按 `hasSuffix("View.swift")` 挑文件，导致 `PlayerSettingsWindow.swift`、`ClosedMediaBadge.swift` 一行都没被扫过；后来是只列顶层目录，`Generated/Naming.swift` 靠「放在子目录」整份躲过检查——等于用位置代替豁免。现在子目录一样进扫描集，**豁免只能以相对路径写进清单**：

| 豁免路径（相对 `Sources/Brimio`） | 原因 |
|---|---|
| `DesignSystem.swift` | 规范本体：这里的字面量就是 token 定义 |
| `main.swift` | CLI / 离屏渲染脚手架：画布尺寸与红色标记线不属于界面规范 |
| `Generated/Naming.swift` | 机器生成：由 `Scripts/naming.sh --emit-swift` 产出，不手写样式；要改请改 `Config/naming.env` |

`--selftest` 分别断言**发现数**（含豁免，`expectedDiscoveredFileCount = 17`）与**实际检查数**（17 − 3 = 14，`expectedCheckedFileCount = 14`），并把文件名与每条豁免理由打印出来。只断言其中一个都可能出现「数量对得上、扫的却是另一批文件」的假绿，所以两个都断言：

```text
[LINT] discovered 17 file(s): AudioPresence.swift, …, Generated/Naming.swift, …, main.swift
[LINT] checked 14 file(s): AudioPresence.swift, ClosedMediaBadge.swift, …, ScreenGeometry.swift
[LINT] exempt DesignSystem.swift：规范本体：这里的字面量就是 token 定义本身
[LINT] exempt main.swift：CLI / 离屏渲染脚手架：画布尺寸与红色标记线不属于界面规范
[LINT] exempt Generated/Naming.swift：机器生成：由 Scripts/naming.sh --emit-swift 产出，不手写样式；要改请改 Config/naming.env
[SELFTEST] PASS  lint discovers every swift file recursively (subdirectories included)  (17/17 discovered)
[SELFTEST] PASS  lint checks discovered files minus explicit exemptions  (14/14 checked, 3 exempt)
[SELFTEST] PASS  recursion proven by a negative case in a temp subdirectory  (discovered=1 violations=1 first=Views/FakeView.swift:1 裸内边距（应改用 DesignSystem.Spacing） -> …padding(8)…)
```

最后一条是**负向用例**，用来证明递归真的生效而不是靠自报：在临时目录里造一棵 `Views/FakeView.swift`（含裸 `.padding(8)`）交给同一个 `scanUI(root:exemptions:)`，要求它被发现且报违规。若扫描退回「只列顶层目录」，这个文件根本不会被发现，断言立刻 FAIL。

纳入扫描后 `PlayerSettingsWindow.swift` 只暴露一处裸值：设置窗口 `fittingSize` 为空时的回退高度 `NSSize(width:height: 720)`，已改成 token `DesignSystem.Size.settingsFallbackHeight`。字号 / 内边距 / 圆角 / 颜色本来就走 token（`.textLineBox`、`Spacing.lg`、`Radius.small`、`Colors.*`），无需改动。

命中 9 条规则就 FAIL 并打印文件:行号：

```text
[SELFTEST] FAIL  view layer uses only DesignSystem tokens  (1 violation(s))
[LINT] NotchRootView.swift:17 裸间距（应改用 DesignSystem.Spacing） -> VStack(spacing: 0) {
```

规则覆盖：裸字号（`.font(.system(size:`）、裸行高（`.lineSpacing(<数字>)`）、裸内边距（`.padding(...<数字>)`）、裸间距（`spacing: <数字>`）、裸尺寸（`.frame(width/height: <数字>)`）、裸圆角（`cornerRadius: <数字>`）、裸不透明度（`.opacity(0.x)`）、裸颜色（`.white/.black/.green` 等字面量）、裸 RGB（`Color(red:`）。注释行跳过，避免文档里的示例数字误判。

### token 化带来的视觉变化

`--render` 前后逐像素比对：**闭合态 0 个像素差异**；展开态 32494 个像素不同（文本区 y≈68.5–152.5pt），全部来自把原值归一到阶梯：

| 位置 | 原值 | 现在 | 原因 |
|---|---|---|---|
| 内容块纵向间距 | 10 | 12 (`Spacing.md`) | 10 不是 4 的倍数，归到最近的阶梯值 |
| 状态圆点 | 7×7 | 8×8 (`Size.statusDot`) | 归一到 4 的阶梯 |
| 胶囊横向内边距 | 7 | 8 (`Spacing.sm`) | 同上 |
| 胶囊纵向内边距 | 3 | 4 (`Spacing.xs`) | 同上 |
| 胶囊圆角 | 5 | 4 (`Radius.small`) | 归一到阶梯值 |
| 文本行盒 | 系统默认 | 按 token 行高 | `.lineSpacing` 让单行文本的行盒略高，HStack 垂直居中位置有 ≤1pt 位移 |

没有出现换行、重叠或裁切；三枚胶囊仍在内容区内。若要 1:1 保持原像素，需要把上面 5 个值原样写回 `DesignSystem`——但那会破坏 4 的阶梯，所以按规范采用新值。

## 验证结果

在本机 macOS 27.2 / Swift 6.4 上实际编译并运行。

`swift build`：编译成功。

`Brimio --selftest`：71 项全部 PASS，退出码 0（M1 之前是 24 项；M1 新增 8 项路由/内边距断言；首页改版新增 chrome 高度、三桶高度预算、占比合计 100%、首页内容块最大 4 项；M2 新增闭合态缩略图加宽 1 项；坐标空间那一轮把 2 条宽松的 on-screen 断言换成 3 条严格断言；IOPM 降级那轮新增「只有状态时用右侧槽位放图标」「没有音频进程时闭合态不动」2 项；闭合态去文字那轮新增「闭合层没有任何文字节点」1 项；音乐类过滤那轮新增「非音乐音频进程不点亮闭合态」1 项；播放器兼容那轮新增 5 项：第三方默认关闭、开启后持久化、能再关回、系统播放器恒开且不可关、每项都写全权限/收益/后果；设计门禁那轮新增 2 项：`lint scans every UI source file`（14 个文件全覆盖）与 `every page keeps content above 30% of panel height`（逐页报份额、豁免带原因）；权限对齐那轮新增 2 项：`each player's stated permission equals what the code requests`、`automation players match the AppleScript targets exactly`；M3 文件架那轮新增 17 项：五状态尺寸/份额、212 上限、高度派生、置顶与去重、大小格式化、单条移除、move 即移除、外部删除后 prune、copy 保留、清空、拖放三条验收各 2 条细化、`app sources never call the accessibility API`；设计门禁改递归那轮把 1 项拆成 3 项：发现数、检查数、子目录负向用例）。关键输出：

```text
[Brimio] window frame={{577, 724}, {316, 232}} contentLayout={{0, 0}, {316, 232}} content={{0, 0}, {316, 232}} safeAreaTop=0.0 closed={183, 32} menuBar=33.0 chin=1.0 screen=内建视网膜显示器
[SELFTEST] PASS  window is visible
[SELFTEST] PASS  window size is fixed 316x232  ((316.0, 232.0))
[SELFTEST] PASS  window wider than largest page (room for spring overshoot)  (window=316 maxPage=300)
[SELFTEST] PASS  window top aligned with screen top  (maxY=956.0)
[SELFTEST] PASS  window horizontally centered  (midX=735.0)
[SELFTEST] PASS  window frame matches geometry
[SELFTEST] PASS  window level above menu bar  (level=27)
[SELFTEST] PASS  joins all spaces and full-screen auxiliary  (raw=337)
[SELFTEST] window-info layer=27 alpha=1 bounds={
    Height = 232;
    Width = 316;
    X = 577;
    Y = 0;
}
[SELFTEST] PASS  window registered on screen  (count=1)
[SELFTEST] PASS  panel composites exactly like a plain window of the same frame  (panel=(577.0, 0.0, 316.0, 232.0) control=(577.0, 0.0, 316.0, 232.0))
[SELFTEST] cg-space scale=1.0000/1.0000 inset=0.0/0.0 desktop=1470.0x956.0 screen=1470.0x956.0
[SELFTEST] PASS  on-screen bounds equal window frame mapped into CG space  (bounds=316.0x232.0@(577.0,0.0) mapped=316.0x232.0@(577.0,0.0) residual=0.00pt)
[SELFTEST] PASS  on-screen bounds touch screen top  (minY=0.0 top=0.0 midX=735.0 center=735.0)
[SELFTEST] PASS  collapsed window ignores mouse events
[SELFTEST] PASS  initial state is closed
[SELFTEST] PASS  closed state keeps 6pt top corners  (6.0)
[SELFTEST] PASS  hover opens the notch
[SELFTEST] PASS  open window receives mouse events
[SELFTEST] PASS  open size follows home page content
[SELFTEST] PASS  window frame unchanged after open
[SELFTEST] PASS  open state has square top corners  (0.0)
[SELFTEST] PASS  default route is home
[SELFTEST] PASS  every tab reachable  (首页,文件架,计时器,播放器兼容)
[SELFTEST] PASS  pages have distinct sizes  (首页=300x128 文件架=248x104 计时器=228x87 播放器兼容=300x184)
[SELFTEST] PASS  all four sides share one padding token  (首页 内容268x56 + chrome28 + 间距12 + 16*2 = 300x128；文件架 内容216x32 + chrome28 + 间距12 + 16*2 = 248x104；计时器 内容196x15 + chrome28 + 间距12 + 16*2 = 228x87；播放器兼容 内容268x112 + chrome28 + 间距12 + 16*2 = 300x184)
[SELFTEST] PASS  chrome is at most one 28pt row  (chrome=28pt)
[SELFTEST] PASS  content + chrome + padding+间距 equals panel height  (首页 56+28+44=128；文件架 32+28+44=104；计时器 15+28+44=87；播放器兼容 112+28+44=184)
[SELFTEST] PASS  closed media badge widens to the right only  (closed=183 badge=211 offset=14.0 hiddenOffset=0.0)
[SELFTEST] PASS  presence-only uses the right badge slot (never centered text)  (width=211 extra=28.0 offset=14.0)
[SELFTEST] PASS  no audio process leaves the closed notch untouched  (width=183 badge=false)
[SELFTEST] PASS  non-music audio process keeps the closed notch quiet  (bundle=com.google.Chrome badge=false width=183)
[SELFTEST] PASS  switching tab keeps the notch open
[SELFTEST] PASS  size follows the selected page  ((248.0, 104.0))
[SELFTEST] PASS  window frame unchanged after tab switch
[SELFTEST] PASS  size returns to home page  ((300.0, 128.0))
[SELFTEST] PASS  leaving closes the notch
[SELFTEST] PASS  closed window ignores mouse events again
[SELFTEST] PASS  closed size restored  ((183.0, 32.0) closed=(183.0, 32.0))
[SELFTEST] PASS  window frame unchanged after close
[SHARE] 首页 内容 43.8% (56/128) ≥ 下限 30%
[SHARE] 文件架 0 个 内容 30.8% (32/104) ≥ 下限 30%
[SHARE] 计时器 内容 17.2% (15/87) 豁免：占位页：内容只有一行「后续接入」（15pt）…
[SHARE] 播放器兼容 内容 60.9% (112/184) ≥ 下限 30%
[SHELF] 0 条 -> 248x104 内容 32/104 30.8%
[SHELF] 1 条 -> 248x104 内容 32/104 30.8%
[SHELF] 2 条 -> 248x144 内容 72/144 50.0%
[SHELF] 3 条 -> 248x184 内容 112/184 60.9%
[SHELF] 4 条 -> 248x212 内容 140/212 66.0%
[SELFTEST] PASS  file shelf holds its size and content share in all five states  (0 条 -> 248x104 内容 32/104 30.8%；…；4 条 -> 248x212 内容 140/212 66.0%)
[SELFTEST] PASS  panel height cap stays at 212pt  (212pt)
[SELFTEST] PASS  file shelf height is derived from the entry count  (104 / 104 / 144 / 184 / 212)
[SELFTEST] PASS  new files are prepended and counted  (added=3 order=["报告.pdf", "截图.png", "素材.zip"])
[SELFTEST] PASS  size string is fixed-width and locale-independent  (35 KB / 1.3 MB / 900 B)
[SELFTEST] PASS  dropping the same path again moves it to the top without duplicating  (报告.pdf / 截图.png / 素材.zip)
[SELFTEST] PASS  removing one entry keeps the others  (报告.pdf / 素材.zip)
[SELFTEST] PASS  moving an entry out removes it immediately  (素材.zip)
[SELFTEST] PASS  deleting outside the app removes the entry on the next user action  (pruned=["素材.zip"] remaining=0)
[SELFTEST] PASS  copy drag keeps the entry and the original file  (items=1)
[SELFTEST] PASS  clearing removes references only
[SELFTEST] PASS  precondition: closed and pass-through
[SELFTEST] PASS  file drag over the closed notch accepts the drop  (ignoresMouseEvents=false)
[SELFTEST] PASS  hovering during a file drag does not expand the notch  (open=false after 0.45s (hoverDelay=0.3s))
[SELFTEST] PASS  drag end restores pass-through
[SELFTEST] PASS  pass-through still on 200ms after the drag ends
[LINT] discovered 17 file(s): AudioPresence.swift, …, Generated/Naming.swift, …, main.swift
[LINT] checked 14 file(s): AudioPresence.swift, ClosedMediaBadge.swift, ExpandedContentView.swift, ExpandedItem.swift, FileShelfView.swift, MediaService.swift, NotchPanel.swift, NotchRootView.swift, NotchShape.swift, NotchViewModel.swift, NotchWindowController.swift, PlayerRegistry.swift, PlayerSettingsWindow.swift, ScreenGeometry.swift
[SELFTEST] PASS  lint discovers every swift file recursively (subdirectories included)  (17/17 discovered)
[SELFTEST] PASS  lint checks discovered files minus explicit exemptions  (14/14 checked, 3 exempt)
[SELFTEST] PASS  recursion proven by a negative case in a temp subdirectory  (discovered=1 violations=1 first=Views/FakeView.swift:1 …)
[SELFTEST] PASS  view layer uses only DesignSystem tokens  (14 file(s) clean)
[SELFTEST] PASS  closed layer contains no text nodes  (NotchRootView.swift: 0 text)
[SELFTEST] PASS  app sources never call the accessibility API  (0 hit(s) outside main.swift)
[SELFTEST] PASS all 71 checks
```

这 71 项覆盖的都是「可断言的事实」：

| 类别 | 项数 | 具体项 |
|---|---|---|
| 窗口几何与层级 | 7 | 可见、尺寸 316×232、比最大页形状宽、顶边贴屏幕顶、水平居中、frame 与 `ScreenGeometry` 一致、level = `.mainMenu + 3` |
| WindowServer 合成 | 4 | 窗口已注册、面板合成 rect 与同 frame 的普通窗口逐项相同（0 容差）、frame 经标定映射进 CG 全局空间后一致（≤2.5pt）、bounds 贴屏幕顶且水平居中 |
| 窗口行为枚举 | 1 | `canJoinAllSpaces` + `fullScreenAuxiliary` 已设置 |
| 状态机与穿透 | 7 | 初始闭合、闭合穿透、hover 展开、展开接收事件、open 尺寸、离开收起、闭合恢复穿透 |
| 分页路由与尺寸 | 14 | 默认首页、四页都能到达、四页尺寸互不相同、四边共用同一档 padding、chrome ≤ 28pt、三桶高度等于面板高、三桶占比合计 100%、首页内容块最大、每页内容份额 ≥ 30%（逐页报数、豁免显式打印）、闭合态缩略图只向右加宽、切页仍展开、尺寸跟随页面、切页不动窗口 frame、切回首页尺寸还原 |
| 媒体降级 | 3 | 只有 IOPM 状态且是音乐类播放器时用右侧槽位放图标（+28pt，绝不居中放字）、没有音频进程时闭合态完全不占位、非音乐类音频进程（Chrome/Safari/微信）也不点亮闭合态 |
| 形状参数 | 2 | 闭合顶部圆角 6、展开顶部圆角 0 |
| 终态稳定性 | 3 | 展开后 frame 不变、闭合高度恢复（宽度允许带一枚徽标）、收起后 frame 不变 |
| 界面规范 | 6 | **递归**发现 17 个 `.swift`（含 `Generated/Naming.swift`，断言 `expectedDiscoveredFileCount`）、实际检查 14 个（断言 `expectedCheckedFileCount`）、生成文件以路径出现在显式豁免清单且写明原因、子目录负向用例证明递归生效；这 14 个文件里没有裸的字号/行高/间距/尺寸/圆角/颜色；闭合层（`NotchRootView.swift`）里没有任何 `Text(`/`Label(`；**除 `main.swift` 探针外没有任何 `AXUIElement` / `AXIsProcessTrusted` 调用**（静态扫源码，防止辅助功能权限悄悄回流） |
| 文件架 | 16 | 五状态（0/1/2/3/≥4）逐个断言 shapeSize 与内容份额、面板高度上限 212、高度由条目数派生、新文件置顶且同路径去重、大小字符串定宽、单条移除保留其余、**move 拖出后立即消失**、**外部删除后下一次用户动作触发移除**、copy 拖出保留条目、清空只删引用、闭合态拖入接收、拖动悬停 0.45s 不展开、松手恢复穿透、松手 200ms 后仍是穿透 |
| 播放器兼容 | 7 | 第三方默认关闭、开启后持久化、能再关回、系统播放器恒开且不可关、每项写全权限/收益/后果、**权限声明逐条等于代码实际请求**、**声明 Automation 的 App 与 AppleScript 覆盖集合完全相等** |

**它无法断言的东西**（这些只能靠渲染图/人眼，或需要录屏权限）：

- 实际像素里形状有没有被窗口边界裁掉、顶部有没有透明缝——`selftest` 只能证明窗口 frame 与 WindowServer bounds 对得上，证明不了内容绘制区域；
- 圆角/阴影/文字的具体长相；
- 动画是否平滑（这由 `--animate-probe` 负责，`selftest` 只验证首尾状态）；
- 全屏 App 之上、其他 Space 上的实际层级表现——`selftest` 只能断言 `collectionBehavior` 已设置，无法在本机自动进入全屏去肉眼确认。

说明：

- `window frame` 是 AppKit 坐标（原点左下）`{{577, 724}, {316, 232}}`，屏幕高 956，`724 + 232 = 956`，顶边正好在 956；
- `layer=27` 等于 `.mainMenu(24) + 3`，证明窗口层级高于菜单栏；恢复 `utilityWindow` / `hudWindow` 之后这一项不变；
- `window-info` 里的 CG bounds 是 `286×134 @ (592,47)`（那一轮窗口还是 316×148 时的读数），**不是启动瞬态、也不是面板样式造成的**，而是 `CGWindowList` 全局空间把整块桌面缩到了 0.90 —— 根因与标定方式见下一节；
- `contentLayout` / `content` 都是 `{{0,0},{316,232}}`、`safeAreaTop=0.0`：SwiftUI 内容没有被安全区或标题栏内缩，形状顶边就是窗口顶边；
- 整个过程中窗口 frame 始终是 316×232，开合只改内容。

`Brimio --e2e`：真实指针移动验证 PASS，退出码 0：

```text
[Brimio] interactive=1 ignoresMouseEvents=0
[Brimio] hover -> open
[E2E] after hover: open=1
[Brimio] interactive=0 ignoresMouseEvents=1
[Brimio] leave -> closed
[E2E] after leave: closed=1
[E2E] PASS real pointer hover works
```

即：指针移到刘海区域 → 0.3s 后展开且窗口开始接收鼠标事件；指针移开 → 0.1s 后收起并恢复穿透。测试结束后指针已复原。

`Brimio --animate-probe`（只在 DEBUG 构建可用）：证明开合过程中确实存在中间帧，**并且整段动画的尺寸都没有超出窗口**。退出码 0。

采样方式：把尺寸和圆角各包进一个 `Animatable` 视图/`Shape`，在 `animatableData` 的 setter 里记录 `(时间, 尺寸/圆角)`。SwiftUI 每次插值一帧就会调一次 setter，所以拿到的是渲染层真实插值出的值。**不能用 `GeometryReader` 采样**——`frame` 动画在渲染层插值，布局阶段只拿到首尾值（这个坑前面踩过）。

```text
[ANIM] open  sizeSamples=65 intermediate=16 interval min/avg/max=3.5/16.4/17.9ms
[ANIM] open  sizes=183.0x32.0,183.0x32.0,183.0x32.0,198.2x37.3,231.6x48.8,275.2x63.9,323.1x80.4,
              371.5x97.2,417.6x113.1,451.6x124.9,489.9x138.1,529.2x151.7,556.2x161.0,578.5x168.7,
              593.2x173.8,610.6x179.8,621.5x183.6,629.6x186.4,635.5x188.5,639.7x189.9,642.0x190.7,
              644.1x191.4,645.0x191.7,645.4x191.9,645.3x191.8,645.0x191.7,644.5x191.6,643.9x191.4,
              …,640.0x190.0（尾部为收敛后的静止帧）
[ANIM] open  shapeSamples=49 intermediate=16 radii(top/bottom)=6.0/14.0,…,5.5/14.9,4.9/15.8,4.2/17.1,
              …,0.4/23.4,0.1/23.8,0.0/24.0
[ANIM] open  peak=645.4x191.9
[ANIM] close sizeSamples=64 intermediate=31 interval min/avg/max=3.3/16.4/17.7ms
[ANIM] close sizes=640.0x190.0,622.3x183.9,605.4x178.1,570.8x166.1,524.4x150.0,492.9x139.2,455.0x126.0,
              412.7x111.4,387.1x102.6,358.1x92.5,332.5x83.7,310.1x75.9,290.6x69.2,273.9x63.4,259.6x58.5,
              247.3x54.2,236.9x50.7,228.2x47.6,220.8x45.1,214.5x42.9,209.3x41.1,204.9x39.6,201.2x38.3,
              198.1x37.2,195.6x36.4,193.5x35.6,191.7x35.0,190.2x34.5,…,183.1x32.0,183.0x32.0
[ANIM] close shapeSamples=62 intermediate=30 radii(top/bottom)=0.0/24.0,…,1.0/22.3,1.4/21.6,1.9/20.8,
              2.5/19.8,3.0/19.0,3.4/18.3,…,5.9/14.1,6.0/14.0
[ANIM] close peak=640.0x190.0
[ANIM] window=656.0x210.0 peak=645.4x191.9 contained=true
[ANIM] PASS animation interpolates: open size=16 shape=16, close size=31 shape=30, contained=true
```

（为可读性用 `…` 省略了部分帧，数值均来自实际运行输出；完整序列用同一命令可复现。）

解读：

- 采样间隔 avg 16.4ms，正好是 60Hz 的逐帧节奏，说明确实是逐帧插值，不是「两次跳变」；
- open 走 `.spring(response: 0.42, dampingFraction: 0.8)`，宽度 183 → **645.4**（超调）→ 回落 640，高度 32 → 191.9 → 190，符合欠阻尼 spring 的行为；
- **`contained=true`**：整段动画的峰值 645.4×191.9 都在 656×210 的窗口内，横向还留 10.6pt、纵向留 18.1pt，中间帧侧边不会被窗口平切；
- close 走 `.spring(response: 0.45, dampingFraction: 1.0)`，190 → 32 单调收敛、无超调，符合临界阻尼；
- 圆角同步插值（顶部 6 ↔ 0、底部 14 ↔ 24），中间帧连形状都是连续的，不只是尺寸；
- 判定逻辑：两个阶段各需 ≥3 个严格落在首尾之间的尺寸、圆角同样要有中间值、且峰值不超窗口；任一不满足就 `[ANIM] FAIL` 并以退出码 2 结束。

`--render` 出图（`Snapshots/closed.png`、`Snapshots/open.png`，灰底、红 1px 线标出窗口顶边）：

- **能证明**：形状顶边与窗口顶边齐平（红线正好压住形状上沿）、展开态顶部两角是方角而不是露出背景三角、左右两侧形状 + 阴影完整没有被平切、底部圆角/文字/分隔线的排布；
- **不能证明**：真实窗口在屏幕上的合成结果（`ImageRenderer` 是离屏绘制，不经过 WindowServer，也没有真实 `NSPanel` 参与）、真实桌面背景下的观感、动画是否流畅、以及全屏/多 Space 下的表现；
- 另外，本机终端进程**没有屏幕录制权限**，`screencapture` 返回 `could not create image from display`，所以**没有实拍截图**，不能用渲染图冒充。窗口是否真的在屏幕上、是否被系统裁切，由 `--selftest` 里的 `CGWindowList`（`layer=27`、`316×232 @ (577,0)`、minY=0）来佐证。

## 几何与动效的取值依据

| 参数 | 取值 | 取值理由 |
|---|---|---|
| 窗口尺寸 | 316×232 | 宽度 = 最大页形状宽 300 + 动画超调 16（左右各 8）= 316；高度 = 最大页形状高 212 + 阴影余量 20 = 232。窗口从创建到销毁都不 resize，避免 resize 带来的坐标抖动。 |
| 窗口宽度动画余量 | 16（左右各 8） | 宽度也逐帧插值，欠阻尼 spring 必然超调（实测峰值比终值多约 5.4pt）。左右各留 8pt，保证超调那几帧两侧都不被窗口边界平切。 |
| 展开内容尺寸上限 `maxSize` | 640×212 | 高度 212 = 文件架视口 140 + chrome 28 + 标题 44，正好容纳「3 整行 + 第 4 行露出 20pt」；宽度 640 是四页内容的最宽上限，再宽形状与菜单栏的比例就失衡。 |
| 阴影余量 `shadowPadding` | 20 | 阴影 radius 4 + 下移 2 之后四周仍要留白：20pt 足够容纳底部实测 8.0pt 的扩散，保证阴影不被窗口裁切。 |
| 展开态顶部圆角 | 0（方角） | 面板顶边压在屏幕顶边上，任何正圆角都会在顶边与形状之间露出左右两个背景三角；方角让顶边整条与屏幕顶边齐平。 |
| 展开态底部圆角 | 24 | 底部悬空，24 与 640 的宽度比接近整圆收口，不显尖锐；与顶部方角形成「上平下圆」的接触关系。 |
| 闭合态顶部圆角 | 6 | 闭合形状就是刘海本体的视觉替身：6pt 与物理刘海下缘的弧度衔接，顶部中段仍保持平直贴边。 |
| 闭合态底部圆角 | 14 | 闭合高度只有 32，14 小于半高，两侧仍留直线段；该值参与 `animatableData`，从 14 连续插值到展开的 24。 |
| 闭合宽度算法 | `frame.width - left.width - right.width + 4` | 用屏幕顶部的左右安全区（`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`）反推物理刘海宽度，任何机型都自适应。 |
| 闭合宽度补偿 | +4 | 四处各 1pt 抗锯齿补偿：刘海边缘落在半像素边界上，不补会在形状与菜单栏之间露出 1px 亮缝。 |
| 无刘海默认宽度 | 185 | 无刘海屏没有物理刘海可对齐，185 与菜单栏图标密度下的视觉重心相称，又明显小于展开宽度，开合有明确的收放感。 |
| 无刘海默认高度 | 32 | 32 与标准菜单栏等高，闭合形状正好嵌在菜单栏里，不侵入下方内容。 |
| 有刘海自定义高度 | 32 | 与物理刘海高度一致；`custom` 模式没有设置界面，取这个值作为默认。 |
| 刘海高度三种模式 | `matchRealNotchSize` / `matchMenuBar` / `custom`，有刘海默认第一种、无刘海默认第二种 | 有刘海屏能从 `safeAreaInsets.top` 读到真实高度，直接采用；无刘海屏只有菜单栏高度可依；`custom` 留给将来的设置项。 |
| 菜单栏高度 | `frame.maxY - visibleFrame.maxY`（另加 24pt 下限兜底） | 这是 AppKit 里唯一可靠的菜单栏高度来源；24pt 下限防止隐藏菜单栏等状态下算出 0，导致 chin 与闭合高度失效。 |
| 展开 spring | response 0.42 / damping 0.8 | 欠阻尼：约 1.2% 的轻微回弹让展开有「弹出」手感，又不至于来回晃；0.42s 内完成，不拖慢 hover 反馈。 |
| 收起 spring | response 0.45 / damping 1.0 | 临界阻尼：收起单调收敛、不超调；比展开略慢一点，收起时没有内容要读，慢下来更不突兀。 |
| hover 进入延时 | 0.3s | 防误触：指针扫过屏幕顶部（点菜单栏、拖窗口经过）时不会立刻展开。 |
| hover 离开延时 | 0.1s | 防抖：指针短暂越界（手抖、擦过圆角缺口）不至于收起；比进入短，因为误收起的代价低于误展开。 |
| 手势灵敏度 | 未实现手势 | demo 不含拖拽开合，200 只作为记录，不参与当前行为。 |
| chin 高度 | `max(0, 菜单栏高 - 刘海高)`，本机 1pt | 刘海高度通常小于菜单栏高度，差值就是菜单栏底边与形状之间那条缝；`max(0, …)` 保证刘海高于菜单栏时不出负高度（本机 33 - 32 = 1pt）。 |
| chin 矩形 | `black.opacity(0.01)` | 用几乎全透明的黑补齐缝隙：既参与合成遮住缝，又不形成可见色块。 |
| chin 宽度 | 闭合刘海宽 183 | 与闭合形状同宽，补块两侧不超出刘海本体；将来在刘海内加常驻信息（音乐/电池）时再按内容加宽。 |
| 顶部 1pt 补线 | `height 1`，水平 inset = 顶部圆角 | 只补两侧顶部圆角之间的平直段：圆角本身由形状绘制，补线伸出圆角会在肩部画出直角。 |
| 内容顶对齐 | `VStack(spacing: 0)` + `frame(alignment: .top)` | 窗口高度比形状多 20pt（阴影余量），顶对齐保证这 20pt 全部落在底部，顶部不出现空隙。 |
| 阴影 | **方向性**：0.35 / radius 4 / 下移 2pt，顶部 25% 高度不投影（`DesignSystem.Effects`） | 贴顶面板若用一圈均匀投影（0.7 / radius 6），左右两侧会从 y=0 起出现竖向暗带（实测 82.7/255），顶部还会向 y<0 渗出 91.2/255，观感像浮在屏幕上的卡片。把顶部 25% 排除在投影源之外、半径收到 4，只留下方与两侧下缘。 |
| 命中外扩 | 6pt | 闭合态窗口穿透，SwiftUI 收不到 hover，命中入口只能由 `NSEvent` 全局监听提供；留 6pt 余量，指针贴边时不会在边界上反复抖动。 |

设计决定：

1. **命中外扩 6pt**：闭合态窗口穿透时 SwiftUI 收不到事件，命中入口只能统一由 `NSEvent` 全局监听提供；外扩 6pt 是为了贴边不抖。
2. **唯一动画源的写法**：参数（0.42/0.8、0.45/1.0）只挂在视图上的一处 `.animation`，调用方不包 `withAnimation`；开/收各取一条曲线，避免两处曲线互相覆盖。
3. **阴影改成方向性**：hover 状态在窗口控制器里、不进 SwiftUI，阴影只能按 `isOpen` 取值；更关键的是贴屏幕顶边的面板若用一圈均匀阴影，左右两侧会从 y=0 起出现竖向暗带（实测 82.7/255）、顶部还向 y<0 渗出 91.2/255，看起来像浮在屏幕上的卡片。所以改成「顶部 25% 高度不投影 + radius 4 + 下移 2pt」的方向性阴影，闭合态仍为 0；实测数据见「方向性阴影」一节。
4. **闭合态绘制宽度**：形状宽度直接用 `closedSize.width`，肩部随顶部圆角 6 内收（体内 171pt），顶边仍严格在 y=0。若要让肩部与外扩量完全对齐，可把宽度改成 `closedSize.width + 2 × closed.top`。
5. **手势**：demo 不含拖拽手势，灵敏度 200 只记录未使用。
6. **窗口宽度留出超调余量**：宽度也逐帧插值，spring 超调那几帧必须落在窗口内，因此窗口宽 = 最大页形状宽 + 16（左右各 8）。`--animate-probe` 的 `contained=true` 就是守这一条；窗口加宽不影响闭合宽度（仍是 183）、命中矩形（仍是 640×190 / 183×32）和居中位置（`midX` 仍等于屏幕中线）。
7. **展开态顶部方角（0）**：面板顶边已经压在屏幕顶边上，19pt 圆角会在顶边与形状之间露出左右两个背景三角；改方角后顶边整条齐平，闭合态保持 6pt 圆角。

## 修复记录（顶部两侧发空）

根因与改动：

1. `NotchShape.swift`：旧实现把顶部过渡画成了二次曲线，顶边中段整体下凹（闭合 6pt、展开 19pt），黑块比窗口顶边低，物理刘海两侧就露出菜单栏底色。现改成从 `(minX, minY)` 起笔的路径：两肩的控制点落在 `y = minY` 上，顶边整条回到 y=0。
2. `NotchRootView.swift`：布局改成 `VStack(spacing: 0)` + `.frame(maxWidth/maxHeight, alignment: .top)`，内容严格顶对齐；去掉旧版多余的 `Color.clear` 与嵌套 frame；加 `.ignoresSafeArea()`；补上顶部 1pt 黑线和 chin 矩形。
3. `NotchPanel.swift`：`NotchHostingView` 覆写 `safeAreaInsets` 返回零。（当时还把 `styleMask` 简化成了 `[.borderless, .nonactivatingPanel]`，理由是「`utilityWindow`/`hudWindow` 会带标题栏内边距」——这个判断是错的，见下面审核修复记录第 2 条，现已恢复。）
4. `ScreenGeometry.swift`：补齐 `cornerRadiusInsets`、三种刘海高度模式、`menuBarHeight`，每个常量都注明取值依据（见「几何与动效的取值依据」）。
5. `NotchViewModel.swift`：加 `topCornerRadius` / `bottomCornerRadius` / `chinHeight` / `chinWidth`，开合各用一条 spring（0.42/0.8、0.45/1.0）。
6. `NotchWindowController.swift`：hover 延时改为 0.3s / 0.1s，建 VM 时传入菜单栏高度，日志补充 `contentLayout`、`safeAreaTop`、`menuBar`、`chin`。
7. `main.swift`：新增 `--render <dir>` 离屏渲染（`Snapshots/` 的来源）；`--show-open` 打开后打印 `show-open -> open`。

修复前后几何对比（本机 Built-in Retina Display，屏幕 1470×956）：

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 形状顶边 y（闭合） | 6pt（顶边中段下凹） | 0pt，与窗口/屏幕顶边齐平 |
| 形状顶边 y（展开） | 19pt | 0pt |
| 闭合尺寸 | 183×32 | 183×32（不变，`auxiliaryTopLeftArea/RightArea` + 4） |
| 展开尺寸 | 640×190 | 640×190（不变） |
| 内容在窗口内的 y 偏移 | 0（但形状内部下凹） | 0（`contentLayout={{0,0},{656,210}}`，`safeAreaTop=0`） |
| 刘海下沿到菜单栏底边 | 无补块，可能露缝 | chin 1pt（`black.opacity(0.01)`） |

## 修复记录（展开无动画、瞬变）

现象：悬停展开/收起时尺寸直接跳变，没有任何过渡。

根因（三处叠加，都是上一轮修「顶部两侧发空」时引入或暴露的）：

1. **触发值不对**：`NotchViewModel` 里 `notchSize` 和 `state` 是两次独立的 `@Published` 变更，而 `.animation(...)` 用的是 `value: vm.isOpen`。SwiftUI 先处理「尺寸变了」那次更新，此时 `isOpen` 还是旧值、动画不触发，尺寸直接跳到终值；等 `state` 变化时尺寸已是终值。→ 改为 `notchSize` 从 `state` 派生（`isOpen ? openSize : closedSize`），一次开合只发布一次变更，`.animation` 的 `value` 换成 `vm.notchSize`。
2. **`.animation` 挂在了尺寸不变化的层**：上一轮为了顶对齐，把 `.animation` 留在最外层 `VStack`/`frame(maxHeight:, alignment: .top)` 上，那一层的尺寸是固定的 640×210，从不变化。→ 把 `.animation` 移到内容链最后一层，让 `.frame(width:height:)`、`.clipShape`、`.shadow` 全部落在它的子树内，仍然只有这一处动画源。
3. **结构切换产生两份副本**：内容原本是 `if vm.isOpen { 展开内容 } else { Color.black }`，类型不同 → SwiftUI 按「移除 + 插入」处理，动画期间两份视图各自插值，采样序列交出错乱的两条曲线。→ 改成固定一层 `ZStack`：黑底常驻，展开文字用 `opacity` 叠加。

验证方式（`--animate-probe`）：把尺寸包成 `Animatable` 视图、把圆角包成 `Animatable` `Shape`，在 `animatableData` setter 里按帧记录。结果 open 65 个采样/16 个中间值、close 65 个采样/31 个中间值，间隔 avg 16.4ms，圆角同样有 16/30 个中间值，`[ANIM] PASS`。详见上面「验证结果」一节。

对齐没有回退：`.frame(maxWidth/maxHeight, alignment: .top)` + `.ignoresSafeArea()` 原样保留，采样首值仍是 `183.0x32.0`，`--render` 出的 `Snapshots/closed.png`、`open.png` 里形状顶边仍压在红线上。（当时的 `--selftest` 是 18 项，后来扩展到 23 项，加上界面规范的静态检查后是 24 项，见下面审核修复记录。）

## 修复记录（审核反馈：裁切 / styleMask / 采样钩子 / 顶部方角）

1. **动画期形状被窗口裁切**：上一版窗口宽 640 = 展开宽度，而宽度也参与动画，0.42/0.8 的 spring 峰值到 645.4，超出的 5.4pt 被窗口边界平切。改法：`ScreenGeometry.animationOvershootPadding = 16`，窗口宽度变成 656（左右各 8pt，画布仍居中，VStack 的水平对齐把 640 宽的内容居中放置），`openSize` 保持 640×190 不变。`--animate-probe` 新增峰值校验，输出 `window=656.0x210.0 peak=645.4x191.9 contained=true`，并把它纳入 PASS 条件（不满足则退出码 2）。
2. **`styleMask` 回退**：恢复成 `[.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]`（`.borderless` 的 rawValue 是 0，写不写都一样，保留只为把「无标题栏」显式写进 styleMask）。复查结论：`contentLayout` / `content` 仍是 `{{0,0},{656,210}}`、`safeAreaTop=0`，`level` 仍是 27，`collectionBehavior` raw 337（含 `canJoinAllSpaces` + `fullScreenAuxiliary`），合成稳定后的 `CGWindowList` bounds 是 `656×210 @ (407,0)`、minY=0，说明这三项 flag 没有引入内边距。**之前那次「简化」为什么没破坏表现**：上一版把 CGWindowList 在启动后约 200ms 内报出的瞬时内缩 bounds（当时 `630×206 @ (420,2)`，本次同样有 `646×206 @ (412,2)`）误当成 HUD 样式带来的永久内边距；实际那是 WindowServer 首次合成未完成时的中间状态，等 1~2 秒后就是完整的窗口 frame。所以简化前后肉眼无差别，简化本身也没解决问题——因为它本来不是问题。
3. **采样钩子污染生产路径**：`NotchLayoutProbe` / `SizeProbe` / `DebugSizeProbe` 全部关进 `#if DEBUG`，`NotchShape.animatableData` 里的记录调用也用 `#if DEBUG` 包住；Release 构建下这些类型不存在、逐帧插值不做任何额外写入，`--animate-probe` 在 Release 下直接提示不可用。Debug 构建下还要 `isEnabled`（只有 `--animate-probe` 打开）才真正记录。
4. **展开态顶部两角改方角**：`NotchViewModel.topCornerRadius` 展开时为 0、闭合仍为 6，避免贴顶后面板与屏幕顶边之间露出两个背景三角。底部圆角仍为 24 / 14。

顺带把 `--selftest` 从 18 项扩到 23 项：新增「窗口比展开内容宽」「level = mainMenu+3」「collectionBehavior 含 all-spaces/full-screen-auxiliary」「闭合顶部圆角 6」「展开顶部圆角 0」，并把 WindowServer bounds 的校验从「容差 ±12/±8」收紧到 ±2、minY ≤ 1（先等 1.2s 让首次合成完成）。之后建立界面设计规范时，又加了第 24 项「视图层只用 DesignSystem token」（静态扫描，见「界面设计规范」一节）。

## 闭合态顶边像素复核（是否绘制越界）

针对「闭合图里形状顶边像高出红线 1–2px、两个上角有小钩子」的疑问，直接对 `Snapshots/closed.png`（1440×600，@2x，窗口左上角在设备像素 (80,80)）逐像素扫描：

| 指标 | 实测值 | 含义 |
|---|---|---|
| 红线所在行 | 设备像素 80–81（= y∈[0,1)pt） | 标注线画在窗口顶边上，1pt 高 |
| 红线以上（y<0）的非背景像素 | **0 个**（第 0–79 行、1440 列全为背景色 rgb(173,178,185)） | 没有任何绘制越出窗口顶边 |
| 最高的深色像素 | 第 82 行 = **y = +1.0pt** | 红线把形状最上 1pt 盖住了，这是第一条完全可见的黑行 |
| 该行黑色宽度 | 350 device px = **175pt** | 不是 183，原因见下 |
| 闭合态阴影 | 不透明度 0 | 没有阴影外溢 |

**为什么上角像「小钩子探到线上」**：形状顶部是内凹肩（二次曲线从 `(minX, minY)` 到 `(minX+6, minY+6)`，控制点 `(minX+6, minY)`）。按这条曲线算，`y = 1.0pt` 处每侧内缩 3.9pt，即 `183 − 7.8 = 175.2pt`，与实测 175pt 吻合。所以看到的是「红线盖住最上 1pt + 内凹肩曲线」的叠加；再加上图片被查看器从 1440 缩到 1024（0.71×）时的插值，红线附近的深色会被抹到上一两行，读起来像越界。

**结论**：闭合态最高绘制点就是窗口顶边 y = 0，**没有超出、也没有被裁剪**。`.ignoresSafeArea()` 只影响 hosting view 的布局内缩（`safeAreaTop=0`，内容不会下移），不产生越界绘制；1pt 补线在内容 frame 内（y∈[0,1)）；闭合态阴影不透明度为 0。

补充：当时展开态还是均匀阴影（0.7 / radius 6），会向 y<0 外溢；改成方向性阴影后这一点已消失（见下一节，y<0 实测 0）。

## 方向性阴影（修复「浮在屏幕上的卡片」观感）

改前的阴影是 `.shadow(black.opacity(0.7), radius: 6)` 的四周均匀投影。两个后果：左右两侧从 y=0 起就有竖向暗带，顶部还会往 y<0 渗；底部峰值太高，重心压在下半部分。观感上就是从顶边「浮起来」的卡片，而不是从顶边延伸出来的形状。

改法：把形状自身当投影源，先 `.mask(LinearGradient(.clear → .black, 0.25 → 0.75))` 遮掉顶部 25% 高度（alpha=0 的区域不产生阴影），再 `.shadow(radius 4, y +2)`。token 见 `DesignSystem.Effects`。

验收工具：`Brimio --shadow-probe [dir]`。它**单独渲染不带红线的干净图**（红线横跨整窗、覆盖 y∈[0,1)pt，会污染采样），再按设备像素扫描；暗度 = 背景亮度 − 像素亮度，`peakAlpha ≈ 暗度 / 背景亮度`。容差 3/255。退出码 0=PASS、2=FAIL。

改之前 / 改之后并排（展开态，单位 0–255 灰阶）：

| 指标 | 改之前（0.7 / radius 6 均匀） | 改之后（0.35 / radius 4 方向性） | 判定 |
|---|---|---|---|
| 两侧 y∈[0,8]pt 最大暗度 | **82.7**（x=7.5pt，28 列全部 21.9–82.7） | **0.0**（28 列全 0） | 容差 3 → PASS |
| y=0 行面板外侧暗度 | **56.7** | **0.0** | 无水平暗线 → PASS |
| y<0（窗口顶边以上）暗度 | **91.2** | **0.0** | 不再向上外溢 → PASS |
| 底部最大扩散距离 | 11.5pt | **8.0pt** | 收窄 30% |
| 底部峰值暗度 / 有效不透明度 | 85.9 / **0.483** | 34.7 / **0.195** | 降低 60% |
| 闭合态三项 | 0.0 / 0.0 / 无投影 | 0.0 / 0.0 / 无投影 | 保持不投影 → PASS |

改之后的两侧纵向剖面（x=7.5pt，距面板边 0.5pt）：`y≤40pt` 全 0，`y=60: 2.6`、`y=100: 12.6`、`y=140: 23.3`、`y=160: 24.2`、`y=188: 1.7`——正是「两侧下缘才有、越往顶部越淡」的方向性分布；底部中轴剖面 `+0pt: 34.7 → +2pt: 23.3 → +4pt: 13.2 → +6pt: 6.2 → +8pt: 0`。

`--selftest` 24 项全 PASS（含静态检查），`--animate-probe` PASS（`peak=645.3x191.8 contained=true`），`--e2e` PASS。

`Snapshots/` 重新出图后的比对（对上一版 token 化的图）：

- `closed.png`：**72 个像素差（占 0.0083%），maxDelta=29/255**，全部落在闭合形状**左下/右下圆角的抗锯齿边**（窗口坐标 x≈243/413pt、y≈19–31.5pt）；顶边（y<20pt）逐像素完全一致。原因：新的阴影层在内容背后多画了一层同轮廓的黑色形状作为投影源，把圆角边缘的半透明抗锯齿像素补实（62.8 → 35.9，两者都接近黑），几何没有移动、闭合态依旧不投影。
- `open.png`：按预期变化，就是阴影本身（侧边暗带消失、底部收窄变浅）。

## 实拍比对方案（需要屏幕录制权限，本轮未执行）

目前确实没有任何证据证明闭合形状与物理刘海在真实屏幕上重合：离屏渲染不含 WindowServer，`--selftest` 里的 183×32 只是把公式值读回来，属于自证。

需要的权限与能力：

- **屏幕录制**（系统设置 → 隐私与安全性 → 屏幕录制，TCC `kTCCServiceScreenCapture`），授权给运行 demo 的终端/IDE 进程，授权后需重启该进程；
- 截图 API 二选一：`screencapture -x -R<x,y,w,h>` 或 ScreenCaptureKit `SCScreenshotManager.captureImage`（两者都受同一 TCC 约束）；
- 用 `CGDisplayPixelsWide/High` 换算 Retina 倍率，把 pt 对齐到设备像素；不需要辅助功能权限（不移鼠标）。

做法（A/B 差分 + 高对比色，避免自己量自己）：

1. **准备**：`--capture-verify` 模式；把桌面壁纸换成纯浅色（深色壁纸会让刘海与菜单栏对比度不足）；关闭 Stage Manager 等会遮挡顶部的特性。
2. **A 帧（对照）**：`panel.orderOut(nil)` 后截取屏幕顶部中央 `R = (midX−400, 0, 800, 120)`；此时图里只有物理刘海 + 菜单栏。
3. **B 帧（待测）**：把面板的形状临时填成非黑的高对比色（例如纯洋红，避免和刘海黑混淆）并 `orderFront`，同一区域再截一次。
4. **量物理刘海**：A 帧沿 `y=0` 行扫描，取「亮度低于阈值且连续」的区间 → 左右边界 `x0b/x1b`；沿中轴向下扫描亮度跳变 → 底边 `y1b`；边界用 50% 交叉点插值到亚像素。
5. **量我们的形状**：B 帧按颜色匹配得到 bbox `x0s/x1s/y1s`；同时检查 `y=0` 整行都是形状色（证明顶部没有缝、没有被裁）。
6. **判定**：`|x0s−x0b|`、`|x1s−x1b|`、`|y1s−y1b|` 均 ≤ 1pt（2x 下 = 2 device px）判 PASS，并单独断言 `y=0` 行无背景色缝隙。
7. **输出**：`[CAPTURE] notch=(x0,x1,y1) shape=(x0,x1,y1) delta=(...) PASS/FAIL`；取不到权限时输出 `SKIP`（退出码 3），**不允许把 SKIP 记成 PASS**。

已知限制：TCC 只能人工授权、脚本无法代授；深色壁纸下边缘检测会失败，需先换浅色壁纸；多显示器要按 `ScreenGeometry.displayUUID` 选对屏；菜单栏图标可能进入截取区域，取刘海中心列即可避开。

这个方案能证明「形状与物理缺口在真实屏上是否重合」；不能证明形状宽度符合 Apple 的设计意图（那只能靠肉眼审美判断）。

## M1：内容区骨架（路由 / Tab / 尺寸随内容）

**信息分级**：规则、判定顺序与三页分级表都在 [DESIGN.md](./DESIGN.md)。首页常驻信息只有两条：**曲名**、**副信息（歌手 · 年份）**；播放状态不写字（用图标），应用名/连接状态/调试信息一律不显示。

**结构**：`ExpandedContentView` 是唯一骨架 —— **唯一一行 28pt chrome**（三个图标 Tab，左对齐，选中态是 `badgeFill` 色块）→ 12pt 间距 → 页面容器。没有应用名标题、没有 `Window Layer` 状态文字、没有状态点、没有分隔线；Tab 不再单独占一行。三页常驻、按 `vm.route` 切 `opacity`，结构稳定，不加第二处 `.animation`。

**路由**：`ExpandedItem` 枚举（`CaseIterable`）同时带 `title`（只留给 VoiceOver）、`iconName`（SF Symbols）与 `contentSize`。加页面 = 加一个 case + 加 `page(for:)` 一个分支 + 写上该页图标与内容尺寸，视图结构不动。

**尺寸随内容**（窗口仍不 resize）：

| 页面 | 内容自然尺寸（不含内边距） | chrome | 行间距 | 上下内边距 | 形状尺寸 |
|---|---|---|---|---|---|
| 首页 | 268 × 56（媒体行：封面 56） | 28 | 12 | 16 × 2 | **300 × 128** |
| 文件架 | 216 × 32 / 72 / 112 / 140（按条目数 0–1 / 2 / 3 / ≥4） | 28 | 12 | 16 × 2 | **248 × 104 / 144 / 184 / 212** |
| 计时器 | 196 × 15（占位一行正文） | 28 | 12 | 16 × 2 | **228 × 87** |
| 播放器兼容 | 268 × 112（4 行 × 28pt，摘要 + 入口按钮） | 28 | 12 | 16 × 2 | **300 × 184** |

`PageMetrics` 的换算没有中间档：`形状高 = chrome 28 + 间距 12 + 内容自然高 + 16×2`，只夹一个防止过小的下限（`28 + 12 + 16×2 = 72`）和一个封顶上限 640×212。窗口 = 最大页形状 300×212 + 16 超调 + 20 阴影 = **316×232**，切页只改绘制形状与命中矩形。

**高度占比（三个独立口径，分母都是面板高）**：不再有把 chrome 与 padding 算进去的「内容区」。`PageMetrics.HeightBudget` 把面板高度拆成互不重叠的三桶，`selftest` 断言三者相加等于面板高，且占比合计 100%。

| 页面 | 实际内容块 | chrome | padding + 间距 | 面板高 | 内容份额下限 30% |
|---|---|---|---|---|---|
| 首页 | 56 → **43.8%** | 28 → 21.9% | 44 → 34.4% | 128 | 过 |
| 文件架（0–1 条 / 2 条 / 3 条 / ≥4 条） | 32 / 72 / 112 / 140 → **30.8% / 50.0% / 60.9% / 66.0%** | 28 → 26.9% / 19.4% / 15.2% / 13.2% | 44 → 42.3% / 30.6% / 23.9% / 20.8% | 104 / 144 / 184 / 212 | 过（最低 30.8%，刚过线） |
| 计时器 | 15 → 17.2% | 28 → 32.2% | 44 → 50.6% | 87 | **豁免**（占位页，见下） |
| 播放器兼容 | 112 → **60.9%** | 28 → 15.2% | 44 → 23.9% | 184 | 过 |

首页额外断言「实际内容块是三者中最大的一份」（43.8% > 34.4% > 21.9%）：媒体页的内容必须压过 chrome 和留白。旧版报的 80.6% 是旧口径（把 28pt chrome 和底部 padding 都算进内容区）算出来的，同时又说 chrome 19.4%，两边不自洽；旧版真实内容块只有 56/180 = 31.1%。

**每一页都生效的内容份额下限：30%**（`PageMetrics.minContentRatio`）。这条是「无效内容不能占一半以上」的量化口径，不是只对首页成立的特例：

- 固定骨架 = chrome 28 + 上下内边距 32 + 行间距 12 = **72pt**，任何一页都要先付这笔钱，而且它不承载任何内容；
- 30% 反解出内容高度 ≈ 31pt，正好是**两条正文行高（15 × 2 = 30）**或**一个控件档位（32）**——一页的内容至少要顶得上两行字，低于这个量级，继续把面板加高只是在放大留白；
- 取值 30% 而不是 40%：文件架（30.8%）的空状态虚线框是一个**真实可交互元素**、且已被控件阶梯钉死（`Control.lg` = 32），把阈值抬到 40% 只能靠把空状态框撑高来凑数，那是为了过门禁而造假内容。

**豁免页只有一个，写在断言里并逐页打印**（`PageMetrics.contentShareExemptions`，不是「默认放过」）：

| 豁免页 | 份额 | 原因 |
|---|---|---|
| 计时器 | 17.2%（15/87） | 占位页：内容只有一行「后续接入」。72pt 骨架下份额上限是 15/(15+72) = 17.2%，把形状压到最小档 72pt 也只是把留白换成骨架，份额不会变好——要过线只能先有真实内容（倒计时读数 + 控制），属于后续实现，不是本轮尺寸问题 |

`--selftest` 的输出（逐页报数，豁免带原因）：

```text
[SHARE] 首页 内容 43.8% (56/128) ≥ 下限 30%
[SHARE] 文件架 0 个 内容 30.8% (32/104) ≥ 下限 30%
[SHARE] 计时器 内容 17.2% (15/87) 豁免：占位页：内容只有一行「后续接入」（15pt）。72pt 固定骨架下上限就是 17.2%，把形状压到最小档 72pt 也只是把留白换成骨架，份额不会变好
[SHARE] 播放器兼容 内容 60.9% (112/184) ≥ 下限 30%
[SELFTEST] PASS  every page keeps content above 30% of panel height  (…)
```

**四边内边距**：整块只挂一个 `.padding(DesignSystem.Spacing.lg)`（16pt）。渲染图实测：首页封面左缘距面板左 16.0pt、封面底距面板底 16.0pt；chrome 行图标字形距面板左 22.0pt（16pt padding + 28pt 命中区里 20pt 视觉块内缩 4pt + 图标再内缩 2pt）。

**控件尺寸 token**（`DesignSystem.Control`，阶梯 20/24/28/32，视图只引用档位）：`xs 20` = Tab 选中色块的视觉尺寸；`sm 24` = 上一首/下一首命中区；`md 28` = 唯一一行 chrome、Tab 命中区（透明扩边，图标仍是 16、色块仍是 20，相邻命中区间隙 4pt 不重叠）、播放大按钮直径；`lg 32` = 文件架行高与空状态区高度。图标 16（`Size.icon`）、文件图标 20（`Size.fileIcon`）、封面 56（`Size.cover`）、封面音符 24（`Size.coverGlyph`）、封面圆角 8（`Radius.medium`）。

**动画**：仍然只有一个 `.animation(vm.currentAnimation, value: vm.animationTrigger)`，触发值是「尺寸 + 路由」的组合值 —— 开合只改 `state`、切页只改 `route`，两者都让同一个触发值变化，因此只有一条曲线，不会互相覆盖。`select(_:)` 只发布 `route` 一次。

**本轮未做（按优先级调整，等界面形态定了再补）**：切页逐帧插值探针、切页动画期间命中矩形取新旧并集、命中矩形与形状矩形相等的断言。当前命中的实现已经按**形状矩形**（`viewModel.notchSize`）而非窗口矩形计算。

`--render` 出图：`closed.png`、`closed-playing.png`、`open-home.png`、`open-files.png`、`open-timer.png`、`open-players.png`、`open-home-denied.png`、`open-home-empty.png`、`settings-players.png`（`open.png` 仍是首页，兼容旧命名）。后三张用 `MediaFixture` 注入状态，**不发 Apple Event**；`settings-players.png` 是独立设置窗口的内容（420pt 宽），`open-players.png` 是刘海里的摘要入口。注意截图里第三方开关显示成黄色禁止符号：`ImageRenderer` 画不出 `NSSwitch`，这是离线渲染的占位符，真机是正常开关。

---

## M2：媒体接入（AppleScript 主路径）

信息分级见 [DESIGN.md](DESIGN.md)「媒体（M2）」一节；本节只记录实现与验收。

### 分层

| 文件 | 职责 |
|---|---|
| `MediaService.swift` | 快照模型（含只有状态的 `audioProcess`）、`MediaBackend` 协议、`AppleScriptBackend`、两通道合流 |
| `AudioPresence.swift` | IOPM 断言读取（状态语义）+ `AudioProcessMonitor`（CoreAudio 音频进程事件源，零轮询） |
| `ClosedMediaBadge.swift` | 闭合态 20×20 槽位：封面 / 三根 8pt 跳动条（仅「有曲目没封面」）/ 播放器应用图标（仅状态） |
| `Scripts/make-app.sh` | 打最小 `.app`，让 Automation 授权有真实身份；支持 `SCRATCH`、`OUT` 两个环境变量指定构建/输出位置 |

### 刷新策略（耗电是同类产品被投诉最多的问题）

| 时机 | 行为 |
|---|---|
| 启动 | AppleScript 与 IOPM 各读一次，决定闭合态显示缩略图还是播放器图标 |
| 播放器事件 | 订阅 `com.apple.Music.playerInfo`、`com.spotify.client.PlaybackStateChanged`，250ms 合并后读一次 |
| 面板展开 | 读一次 |
| 播放中且面板展开 | 5s 低频校正（`tolerance = 2`） |
| CoreAudio 音频进程事件 | 监听 `kAudioHardwarePropertyProcessObjectList` + 每个进程的 `kAudioProcessPropertyIsRunningOutput`，120ms 合并后重读一次 IOPM。**开始播放、切歌、App 启动/退出都是即时的，不需要定时器** |
| IOPM 断言复核 | **只在「确实有断言」期间挂一条 2s 表**（`tolerance = 0.5`）。暂停/退出后断言消失，表随之停掉；没有播放时定时器数为 0 |

为什么不把 2s 表彻底删掉：暂停不产生任何事件。IOPM 没有变更通知（实测给 `IOPMrootDomain` 挂 general-interest 通知，音频客户端起停时 0 次回调）；CoreAudio 的 `IsRunningOutput` 在客户端自己暂停时实测仍为 1（详见「媒体通道实测结论」）。所以要靠这条表发现断言被撤掉，代价是播放期间 0.5 次/秒的唤醒。

AppleScript 侧仍然是「暂停 / 无播放 → 停表」。封面只在曲目变化（`trackKey`）时重读：Music 走 `data of artwork 1`，Spotify 走 `artwork url` 再下载。

不对未运行的播放器发 Apple Event：`tell application "Music" ...` 连 `it is running` 都会把 App 拉起来，所以运行判定放在 `NSWorkspace`，只在已运行时才发脚本。

### 授权降级

| 状态 | 表现 |
|---|---|
| `unknown` | 首次读时由系统弹一次授权；允许后 `granted` |
| `denied`（-1743） | 立即挂起自动刷新，**不再重发事件、不再弹窗**；首页换成一行可点击引导「允许控制音乐，去系统设置开启」，点击打开 `x-apple.systempreferences:…Privacy_Automation` |
| 已授权但没播放 | 空态一行「暂无播放，先在 Music 里放一首」，面板高度不变（仍是 300×128） |
| 非 AppleScript 播放器在播（如网易云） | 走 IOPM：展开态首页一行「网易云音乐 · 正在播放」+ 右侧「用键盘媒体键 ⏮ ⏯ ⏭ 控制」；闭合态**不写任何文字**，而是在右侧 +28pt 的徽标槽位里放该播放器的应用图标（取不到图标用音符），不加宽就没有位置、所以宁可用图标也不往摄像头模组下面写字。**不放假的播放按钮**：读不到就控制不了，画出来只会点不动 |

## 媒体通道实测结论

2026-11-15 在本机 macOS 27.2 上，用正在播放的**网易云音乐**（pid 90938）逐条实测。前提先确认：`pmset -g assertions` 显示
`"com.apple.audio.AppIsRunning 网易云音乐 is playing music"`（已持续 3 分钟），mediaremoted 也把它列为当前会话
`【 LOCL (Mac) ❯ com.netease.163music (90938) 网易云音乐 ❯ default 】`。

| 通道 | 可用性 | 证据 | 失败原因 |
|---|---|---|---|
| MediaRemote | **不可用**（符号全在、daemon 有应答，返回空） | 12 个符号 `FOUND`；`MRMediaRemoteGetNowPlayingInfo` 回调 keys=nil、`GetNowPlayingApplicationPID`=0、`IsPlaying`=false、`GetNowPlayingClient`=nil | **entitlement 拒绝**：日志 `entitlements=0` → `kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted"` |
| 系统 Now Playing | **不可读**（面板有数据，无公开读取 API） | `MPNowPlayingInfoCenter.default().nowPlayingInfo`=nil、`playbackState`=0 | 公开 API 对第三方**只写不读**；面板数据来自 mediaremoted 的私有接口，与上一行同一个门 |
| 网易云自动化 | **不可用** | `CFBundleURLSchemes=orpheus`（只能拉起/下命令）；无 `.sdef`、`NSAppleScriptEnabled` 未设；`get player state` 直接 -2740 解析失败；`get name` 能答（标准属性）；二进制里只有 `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` | 没有献给第三方的状态通道；它只把数据交给系统 |
| 辅助功能 | **不可用** | `AXIsProcessTrusted=true`，但 `AXWindows`=1 且 children=0，全树 `visited=1`、文本节点 0；`AXEnhancedUserInterface` set → -25208 notImplemented；`AXManualAccessibility` → -25205 | 界面是 CEF（Chromium Embedded Framework），渲染层默认不建 AX 树，且两个能打开它的开关都没实现 |

MediaRemote 的关键日志原文：

```text
Adding client <MRDMediaRemoteClient ..., bundleIdentifier = nexus-probe-5555..., pid = 92151, entitlements=0>
Response: handlePlaybackQueueRequest<...> returned with error
  <Error Domain=kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted">
  for 【 LOCL (Mac) ❯ com.netease.163music (90938) 网易云音乐 ❯ default 】
```

这行日志同时说明两件事：**daemon 有能力解析出网易云是当前播放器**（所以不是播放器没注册），**拒绝的唯一原因是我们没有 `com.apple.mediaremote`**。补做了一次 ad-hoc 自签名实验（只加这个 entitlement），重跑后 daemon 仍记 `entitlements=0` —— 受限 entitlement 不认 ad-hoc 签名，必须 Apple 签发的 provisioning。所以「自己签一下就可用」这条路不存在。

分布式通知那条也试过（10s 全量监听，0 条），但它**不能单独当结论**：CLI 进程的分布式通知监听在本机就没跑通（自己发一条自检通知、跨进程发都收不到）。真正的依据是二进制里扫不到 `NSDistributedNotificationCenter`，只有 `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`。

### 事件源：CoreAudio 能用，但不能拿来判暂停

目标是「零轮询」。两条候选都是零权限的，实测结论如下：

| 候选 | 能否当事件源 | 实测证据 |
|---|---|---|
| `IOPMrootDomain` 的 general-interest 通知 | **不能** | `IOServiceAddInterestNotification` 返回成功，但在两个音频客户端起停的 10s 窗口里 **0 次回调**。IOPM 断言本身没有任何变更通知 |
| CoreAudio 进程对象 | **能** | `kAudioHardwarePropertyProcessObjectList` 枚举到 28 个对象；`kAudioProcessPropertyIsRunningOutput` 对网易云 = 1；起停两个静音客户端（`afplay -v 0`）时进程列表属性监听各触发 2 次，时间戳与客户端起停对齐（1.09s / 3.99s / 6.08s / 9.98s） |

但 `IsRunningOutput` **表示「这个客户端挂着 IO proc」，不等于「有声音」**。用一个自己 `AudioQueuePause()` 的静音客户端实测：暂停后该属性全程保持 1，属性监听 **0 次回调**，500ms 采样 20 次都是 1。播放器如果暂停时不拆掉音频客户端，CoreAudio 完全看不出「暂停」。

所以最终形态是**事件驱动 + 极窄复核**：CoreAudio 负责「开始/停止输出、App 起停」的即时触发（这些场景不需要定时器），状态语义仍由 IOPM 断言判定；只有断言存在时才挂一条 2s 复核表，用来发现「暂停撤掉了断言」这件没有任何事件的事。暂停/退出后断言消失，表立即停掉 —— 空闲时定时器数为 0。

### 功耗实测

`--power-probe` 是**同进程 A/B**：不建窗口，只跑被测组件 `MediaService`（后端换成 `NoopBackend`，避免 AppleScript 把播放器拉起来），同一个实例交替「复核表 ON / 播放中」与「复核表 OFF / 无播放」各 20s，两臂只差一条播放断言。之前按「idle-1 → playing → idle-2」各起一个 `MediaService`，既混进了启动开销，也无法把差异归因到具体组件。

仪器两条一起读，互相印证：

- `task_info(TASK_POWER_INFO_V2)`：本进程的 `task_interrupt_wakeups`（定时器唤醒落在这一项）与 `task_energy`（nJ）；
- `proc_pid_rusage(RUSAGE_INFO_V4)`：`ri_interrupt_wkups` / `ri_pkg_idle_wkups`。

两条仪器每次读数完全相同。**先校准再测**：0.4s 定时器跑 10s（理论 25 次）→ `+27`；空跑 10s 底噪 → `+6`。仪器能 1:1 数出定时器唤醒，所以测不到差异时不能拿「颗粒度不够」当借口。另外，采样窗口内只调一次 `run(until:)`：分片轮询会让主线程每 0.5s 醒一次，自己造出 2.4 次/秒的底噪，把被测差异淹掉（中途试过一版，OFF 臂凭空多了 48 次/20s）。

```text
[POWER] 底噪：空跑 10s（无定时器、无 MediaService）
[POWER] 底噪结果  taskInterrupt=+6  rusageInterrupt=+6  idle=+0  energy=+2.24mJ
[POWER] 仪器校准：0.4s 定时器跑 10s（理论 ~25 次触发）
[POWER] 校准结果  taskInterrupt=+27  rusageInterrupt=+27  taskTimerBin=+0  energy=+0.43mJ
[POWER] A1 复核表 ON  20s  verifyFires=10  中断唤醒=+10  空闲唤醒=+0  能耗=+1.08mJ  CPU=+0.000s
[POWER] B1 复核表 OFF 20s  verifyFires= 0  中断唤醒=+2   空闲唤醒=+0  能耗=+0.11mJ  CPU=+0.000s
[POWER] A2 复核表 ON  20s  verifyFires=10  中断唤醒=+11  空闲唤醒=+0  能耗=+2.30mJ  CPU=+0.000s
[POWER] B2 复核表 OFF 20s  verifyFires= 0  中断唤醒=+2   空闲唤醒=+0  能耗=+0.08mJ  CPU=+0.000s
[POWER] 汇总：ON 平均中断唤醒 10.5/20s（复核平均 10.0 次），OFF 平均 2.0/20s，差 8.5
```

读法：OFF 臂 2 次/20s 是进程自身底噪；ON 臂 10.5 次/20s 里多出来的 8.5 次归给复核表。**同一实验共跑三次**（不同构建），差值分别是 7.5、9.0、8.5，触发数都是 10——10 次触发对应 7.5–9.0 次唤醒，即**每次触发 ≤1 次唤醒**，差额来自 `Timer.tolerance = 0.5` 的合并：定时器本来就会被系统并到相邻唤醒点，所以「唤醒数 ≤ 触发数」是正常形态，不是漏记。空闲（无播放）时定时器为 0、唤醒 2 次/20s、CPU 0.000s（精度 1ms）。

上一版那两段数据（三段全是 6、并解释成「复用 RunLoop 时间片」）是错的，已删除：那个 6 是启动/分片采样的固定开销，与复核表无关。这条结论现在有校准、有对照臂、有重复臂，写进 README 才敢当产品承诺。

### IOPM 是钝器：闭合态还要过一层「音乐类」过滤

IOPM 只知道「有进程在出声」。网页视频（Chrome/Safari）、微信语音、游戏都会命中；同类产品靠 Now Playing 会话天然只登记媒体 App，换成 IOPM 后丢了这层过滤，不过滤就会在刘海右边莫名弹出浏览器或微信图标。判定顺序（`MusicAppClassifier`）：

1. **白名单命中直接放行**：Music、Spotify、网易云、QQ 音乐、酷狗、酷我、YouTube Music；
2. 白名单之外再看 App 自报类别：`LSApplicationCategoryType == public.app-category.music` 放行（用来接住没收录的新播放器）；
3. 两条都不满足 → **不点亮闭合态**，但展开态照常显示，交给用户判断。

顺序是先白名单、后类别。反过来会误伤：国内播放器的 `LSApplicationCategoryType` 常自报 entertainment / utilities（不是 data bug，是厂商没按音乐类别填），先按类别筛会把已经核过的 App 挡掉。白名单只用于「这个 bundle id 我们已经确认是音乐播放器」，类别用于「没见过的 App 自报是音乐」。

`--presence-probe` 会把白名单里每个 App **实际读到的 Info.plist 值**打出来，不假设（2026-11-15 实测）：

```text
com.apple.Music        category=public.app-category.music  whitelist=true  accept=true  path=/System/Applications/Music.app
com.spotify.client     category=<未读到>                   whitelist=true  accept=true  path=<未安装/未运行>
com.netease.163music   category=public.app-category.music  whitelist=true  accept=true  path=/Applications/NeteaseMusic.app
com.tencent.QQMusic    category=<未读到>                   whitelist=true  accept=true  path=<未安装/未运行>
com.kugou.mac          category=<未读到>                   whitelist=true  accept=true  path=<未安装/未运行>
com.kuwo.KuwoMusic     category=<未读到>                   whitelist=true  accept=true  path=<未安装/未运行>
com.google.YouTubeMusic category=<未读到>                  whitelist=true  accept=true  path=<未安装/未运行>
非白名单 com.google.Chrome      category=<未读到>                        accept=false
非白名单 com.apple.Safari       category=public.app-category.productivity accept=false
非白名单 com.tencent.xinWeChat  category=public.app-category.social-networking accept=false
```

这台机器只装了 Music、网易云和三个浏览器/微信样本，所以 Spotify / QQ 音乐 / 酷狗 / 酷我 / YouTube Music 读不到值——它们的 `accept=true` 全部靠白名单，不靠类别。网易云这里自报的正好是 music，但**不能拿这一台机器的结果当规律**：白名单优先级就是为「自报 entertainment/utilities 的版本」准备的。另外 Chrome 压根没写 `LSApplicationCategoryType`，只看类别会把它漏进白名单外的判定，靠 whiteList=false + 类别 nil 才关掉。

断言（`--presence-probe` 两条 + `--selftest` 一条）：Safari 作为 presence 时闭合态宽度保持 183、无徽标；`whitelist wins over declared category` 要求 7/7 白名单通过且 3 个样本全部拒绝；纯规则断言覆盖 `QQMusic@entertainment=true`、`KuGou@utilities=true`、陌生 App `@music=true`、陌生 App `@nil=false`。

### 播放器兼容：按播放器分组，第三方默认关闭

产品规则（`PlayerRegistry`），不是可选项：

| 分组 | 成员 | 默认 | 权限 | 未开启时 |
| --- | --- | --- | --- | --- |
| 系统播放器 | Music、Spotify | 开 | Automation，首次读取时系统弹窗，一次性、只指向该 App | 恒开，不接受关闭 |
| 第三方播放器 | 网易云、QQ 音乐、酷狗、酷我、YouTube Music | **关** | **不需要额外权限**（只读系统级播放状态，IOPM 整表读，不针对单个 App） | 不读取、不显示、不请求任何权限 |

- 闸门在 `MediaService.refreshPresence`：IOPM 只能整表读（零权限、没有 per-App 请求），读到之后先过 `PlayerRegistry.allowsReading`，未开启的直接丢成 `.none`。所以「不读取」的边界是**不针对该 App 发起任何查询、界面上也不出现**，而不是不调用 `IOPMCopyAssertionsByProcess`。
- 设置窗口每项都写三句话：需要什么权限、开启后得到什么、不开会怎样。权限那句不是手写的：它由条目的 `permissions` 集合推导，`--selftest` 再逐条断言「声明的集合 == 该通道在 `MediaService.permissionsRequested(for:)` 里的实现」，多写少写都 FAIL（详见下面「权限声明与实现对齐」）。
- 入口在刘海第 4 个 tab：只放两行摘要（系统播放器 / 第三方 N/5 已开启）和按钮，真正的开关在独立窗口（420pt 宽）。原因是 7 个播放器 × 3 行说明远超面板 212pt 的高度上限，塞进面板只会滚动到看不见。
- 现实后果要说清：网易云正在播而开关没开时，闭合态和展开态都不会显示它——这是这条产品决定的预期行为，不是媒体通道坏了。
- **对外承诺收敛（2026-11-15）**：第三方播放器只承诺「**显示播放状态**；曲名不承诺」。曲名只对 Apple Music / Spotify 承诺，走 Automation。原因是目前没有任何第三方播放器验证通过——网易云连状态项都没注册。
- 控制能力按实现写：第三方没有任何 per-App 控制路径（`AppleScriptBackend.perform` 只对 Music / Spotify 生效，presence-only 界面刻意不放控制按钮），所以文案是「播放/切歌请用键盘媒体键」。本应用不代发媒体键。

#### 权限声明与实现对齐（`--selftest` 两条断言）

`PlayerEntry.permissions` 是每个条目唯一的权限声明，窗口里的那句话由它推导；`MediaService.permissionsRequested(for:)` 是**行为**的唯一声明处（switch 穷尽，新增通道必须补分支）。断言：

1. `each player's stated permission equals what the code requests` —— 逐条比对，按 `PlayerRegistry.entries` 遍历，新增播放器自动纳入，不写死这 7 条；
2. `automation players match the AppleScript targets exactly` —— 声明 Automation 的 App 集合必须与 `AppleScriptBackend.supportedBundleIDs` 完全相等，防「写了权限但永远不会弹」和「有脚本却没在设置里露出」。

`PlayerEntry.Permission` 枚举里只有 `.automation`：AX 读曲名通道暂停投入后，代码里没有任何 `AXUIElement` 调用，所以「辅助功能」这个权限项从类型层面就不存在，不会再被写进说明。

设置窗口里的开关是自绘的（`PlayerToggle`，36×20 / 圆点 16 / 边距 2，全部走 `DesignSystem.Size`）：`Toggle` 是 AppKit 控件，`ImageRenderer` 离屏渲染画不出来（会变成黄色占位符），自绘之后渲染图和真窗口一致。

### 菜单栏状态项能不能当元数据通道（网易云实测）

方法：`AXUIElementCreateApplication(pid)` → `AXExtrasMenuBar` → `AXChildren`，逐节点读 `AXTitle/AXValue/AXDescription/AXHelp/AXRole/AXSubrole/AXChildren/AXParent/actions`。**只读，没有 AXPress**，不弹开菜单。

结果（2026-11-15，网易云正在播放）：

- 辅助功能权限可用：`AXIsProcessTrusted = true`（这是给**探针脚本所在终端**开过的，应用本身从不申请辅助功能，`PlayerEntry.Permission` 里也没有这一项）。同一套只读代码在系统时钟项上读到 `AXValue = "11月15日 周日 15:55"`，Siri 项读到 `AXTitle = "Siri"`——说明「状态栏项的 AX 属性可以携带动态文字」在原理上成立（中性样本，不含任何业务信息）。
- 但网易云的 app 元素上 `AXExtrasMenuBar` **属性名存在、值为 nil**，`AXChildren` 为空：进程当前没有注册任何状态栏项。所以**状态栏项自身是否携带曲名，现在无法验证**——不是读不到属性，而是没有可读的对象。
- `com.netease.uuremote`（UU 远程）有状态栏项，但那是另一个 App，不能代替网易云。
- 网易云没有开启「菜单栏显示」类选项，状态项不存在；这轮之后**不再要求用户改设置来凑条件**。只要它没开，任何「网易云曲名可从菜单栏读取」的说法都是推测，不写进产品设计。
- 长期轮询未验证（没有对象可测）。已知风险：状态项重建会让缓存的 AX 引用失效，若将来重启这条线，每次轮询都要重新取 `AXExtrasMenuBar` 而不是复用旧引用。

结论：**状态项不存在，网易云这条通道不成立**。已验证的只是「状态栏项的 AX 属性可以携带动态文字」这个原理（中性样本：系统时钟项的 `AXValue`、Siri 项的 `AXTitle`），不代表任何一个第三方播放器能提供曲名。

### 系统「播放中」菜单栏项（`com.apple.MenuBarAgent`，只读探测）

假设：系统进程持有一个 `AXDescription = "播放中"`、`children = 1`（子节点是 `AXMenu`）的状态栏项，若能只读读到曲名/歌手，就等于一条**不依赖各播放器是否注册自己状态项**的入口。

方法：`AXUIElementCreateApplication(683)` → `AXExtrasMenuBar`，逐项递归读 `AXRole/AXSubrole/AXTitle/AXValue/AXDescription/AXHelp/AXChildren`。**没有 `AXPress`、没有 `AXShowMenu`，不展开任何菜单，不启动任何播放器。**

第一个前提是我上一轮判断错了：这一项**不是「必须 Music 播一首」才出现**，它随媒体会话出现/消失，与用哪个播放器无关。所以这一轮只做只读轮询，没有动过播放。

**它间歇存在，存活期约 1 分钟**。观测时间线（`pmset -g assertions` 全程显示 `pid 90938(NeteaseMusic) … "NetEase CloudMusic is playing music"`，累计 1:54:24；`--presence-probe` 全程 `playing=true`）：

| 时刻 | `AXExtrasMenuBar` 子项数 | 「播放中」项 | 媒体状态 |
|---|---|---|---|
| 15:55 | 5 | 不在 | 网易云在播 |
| 16:00:29 | 5 | 不在 | 网易云在播 |
| **16:01** | **6** | **在** | 网易云在播 |
| 16:02:5x | 6 | 未确认（该次只读到 wrapper 层，`AXDescription` 为空） | 网易云在播 |
| 16:03:2x | 5 | 不在 | 网易云在播 |
| 16:03:38–16:05:30（0.5s 轮询 240 次） | 恒为 5 | 不在 | 网易云在播 |
| 16:08–16:10（MediaRemote 交叉采样 24 次） | 恒为 5 | 不在 | 网易云在播 |
| 16:10:41–16:25:41（0.5s 轮询 15 分钟，1800 次） | 恒为 5 | 不在（0 次捕获） | 网易云在播 |

捕获到的那一次，结构是（wrapper 与真实项分两层，`AXDescription` 只挂在第二层）：

```text
AXExtrasMenuBar children=6
  AXGroup/AXHostingView children=1
    AXMenuBarItem/AXMenuExtra  desc=[播放中]  title=[nil]  value=[nil]  help=[nil]  children=0
```

- **只读没拿到曲名，也没拿到歌手**：`AXTitle` / `AXValue` / `AXHelp` 三个字段都是 nil，唯一可读的文字是常量 `AXDescription = "播放中"`；这几个字段里出现过的所有文字都不含曲目信息。
- 该时刻读到的 `AXChildren` 为 **0**，没有可遍历的 `AXMenu` 子节点——所以「菜单里有没有曲名」这一步没能走到。你 15:16 看到的 `children = 1 / AXMenu` 形态在这一轮没能复现（同一对象在两次观测里 children 数不同，说明菜单内容是懒加载或随会话状态变化）。
- 其余 5 项（Wi‑Fi / 电池 / 控制中心 / 时钟 / 隐藏菜单栏项目）都不含业务文字，只有时钟项的 `AXValue` 是动态时间。
- 交叉验证：`MediaRemote` 的 `MRMediaRemoteGetNowPlayingInfo` 从第三方进程读到 **nil**（macOS 26 上很可能受 entitlement 限制），所以「系统是否认为有媒体会话」这一项**没有可信数据**，不作为证据。

结论：**这条通道到此为止，记为「未验证、低优先、暂停投入」**。要产出曲名需要两个条件同时成立：(a) 该项存在（实测每小时只有约 1 分钟存在），(b) 它的 `AXMenu` 已生成且只读可遍历（捕获到时 `AXChildren = 0`）——两个条件从未同时满足；就算成立，也只能靠 `AXPress` 展开菜单才能读，那已经不满足 glanceable。投入产出不成立，所以不再挂监听、也不再请用户切歌凑时机。

零权限方案的上限到此为止：**状态 + 控制**。曲名只走 Apple Music / Spotify 的 Automation 通道。如果将来必须验证 press 形态：`AXPress` 会在这个状态栏项下方展开媒体控制面板（露出曲名/歌手/播放控制，需要在菜单外再点一次才收起），属于可见的界面变化，所以没有执行。


### 为什么最终选 IOPM

- **零授权、零 entitlement、对任意播放器都成立**：coreaudiod 会给每个正在播声的进程建一条 `PreventUserIdleSystemSleep` 断言，`AssertName` 形如 `<App> is playing music`，字典键就是 pid。读它只是 `IOPMCopyAssertionsByProcess` 一次调用。
- 代价明确：**只有状态、没有元数据**，而且**暂停时会撤掉断言**（正好是我们要的语义：断言在 = 在播）。多路同时播放时取 `AssertionId` 最大的那一路。
- **触发交给 CoreAudio，语义留给 IOPM**：CoreAudio 给得出零轮询的事件，但分不清「暂停但客户端还挂着」和「正在播」；IOPM 分得清但没有通知。各取一半，才既不轮询又不误报。
- 界面据此分叉：有曲目走 AppleScript（封面 + 曲名），没曲目但有断言 → 闭合态只在右侧徽标槽位放播放器图标（**不放文字**：183pt 的形状正中就是摄像头模组的实体遮挡区），展开态首页一行「App · 正在播放」。
- MediaRemote 已**整体删除**（含调用即 SIGSEGV 的 `MRMediaRemoteGetNowPlayingApplicationDisplayName`），不留开关、注释或占位：它现在恒返回空，留着会让「没权限」和「没在播」看起来一样，掩盖真实故障。
- 网易云 `127.0.0.1:20017` 那个本地端口**按约定不碰**，任何形式的探测都不做；它也不是元数据来源。

### 打包与授权测试

```bash
Scripts/make-app.sh                 # 产出 build/Brimio.app（含 NSAppleEventsUsageDescription，未签名）
open build/Brimio.app            # 首次启动会弹 Automation 授权
open build/Brimio.app --args --media-probe --out /tmp/media-probe.txt
```

`.build` 或 `build/` 不可写时（沙箱 / CI），两个环境变量把产物挪到可写路径：

```bash
CONFIG=release SCRATCH=/abs/scratch OUT=/abs/build/Brimio.app bash Scripts/make-app.sh
shasum -a 256 /abs/build/Brimio.app/Contents/MacOS/Brimio /abs/scratch/out/Products/Release/Brimio
```

打包后务必核对这两个 sha256 一致——`cp` 失败时 `open` 旧 bundle 不会报错，只会跑上一版二进制。

脚本**不签名**（`make-app.sh` 只 `cp` + 写 `Info.plist`）。不要手工给 bundle 补 `codesign`：重签会改写 Mach-O 的签名 blob，sha256 立刻与 release 产物分叉，上面这条完整性核对就失效了。本机没有分发需求，ad-hoc 的链接器签名足够启动；TCC 按 bundle id + 路径记住授权，重打后需要重新授权属于预期。

`swift run` 仍是开发路径，但裸二进制的 Automation 授权会被 TCC 记在**终端**头上，无法测「拒绝 → 引导」这条路径，所以授权相关验收必须用 `.app`。

### 闭合态缩略图

有播放会话时闭合形状向右加宽 28pt（**恰好一个 20pt 徽标 + 8pt 间距**），高度仍是 32；`closedBadgeOffset = 增量/2` 抵消居中绘制，刘海本体左缘不动。无播放会话时增量为 0，完全回落到刘海，不占位。

**闭合态不放任何文字**。183pt 的闭合形状约等于物理刘海宽度（`屏幕宽 − 左辅助区 − 右辅助区 + 4`），它的正中就是摄像头模组的实体遮挡区；离屏渲染看不到硬件挖孔，所以图上看不出问题、真机上文字是藏在模组后面的。`--selftest` 里有一条静态断言专门守这件事：`NotchRootView.swift` 中 `Text(` / `Label(` 出现次数必须为 0。

**只有状态、没有曲目时（IOPM 通道）**走同一个右侧槽位：放该播放器的应用图标（按 bundle id 查 `NSRunningApplication.icon`，取不到再退化成音符），20×20、4pt 连续圆角。不画缩略图、不画跳动条 —— 没有曲目信息就不假装有。暂停时 IOPM 断言被撤掉，2s 复核表发现后立即隐藏；App 退出时 CoreAudio 的进程列表事件会立刻触发一次重读，不等复核表。

没有封面时显示三根跳动条：`TimelineView(.periodic)` 的采样间隔从 0.45s（2.2Hz，肉眼能数出台阶）改成 `1/15` 秒，相位乘 3.2 使视觉起伏约 1Hz。没选「静态音符图标」是因为跳动条是闭合态唯一能表达「正在播放」的线索，去掉后只剩一枚封面；而 15fps 每帧只重绘 3 根 `Capsule`，开销可忽略。暂停时 `isPlaying == false`，视图不随 timeline 重算，不产生空转重绘。注意跳动条只在 **AppleScript 拿到曲目但封面还没解析出来** 时出现；presence-only 状态一律不画。

离屏渲染新增 `closed-presence.png`（`MediaFixture.presence`），可直接对照检查槽位里是不是应用图标、且没有文字。

### 实测记录

| 项 | 结果 |
|---|---|
| `--media-probe`（Music 未运行） | `[MEDIA] no track: 播放器未运行或已停止（source=music）`，exit 0 |
| `--selftest` | 71 项 PASS，含 `closed media badge widens to the right only (closed=183 badge=211 offset=14.0)`、`presence-only uses the right badge slot (never centered text)`、`non-music audio process keeps the closed notch quiet`、`closed layer contains no text nodes`、`third-party player is off by default`、`system players stay enabled and cannot be switched off`、`each player's stated permission equals what the code requests`、`automation players match the AppleScript targets exactly`、文件架五状态尺寸与份额（`file shelf holds its size and content share in all five states`）、`file shelf height is derived from the entry count`、`moving an entry out removes it immediately`、`deleting outside the app removes the entry on the next user action`、`hovering during a file drag does not expand the notch`、`app sources never call the accessibility API`、`lint discovers every swift file recursively (17/17)`、`lint checks discovered files minus explicit exemptions (14/14, 3 exempt)`、`recursion proven by a negative case in a temp subdirectory`、`every page keeps content above 30% of panel height` |
| `--presence-probe`（网易云在播，2026-11-15） | `live pid=90938 bundle=com.netease.163music app=网易云音乐 playing=true`；14 项 PASS（暂停 / 退出 / 音乐类过滤 / 白名单优先级 / 三行真实类别 / presence→UI / track→UI / CoreAudio 挂载与摘除），未发送任何播放控制指令 |
| `--power-probe`（打包后的 `.app` 二进制，无窗口、同进程 A/B） | 校准 `+27`（0.4s 定时器 25 次）；三次运行 ON `+10/+11`、`+11/+8`、`+11/+11`，OFF 恒为 `+2/+2`，差 8.5 / 7.5 / 9.0（fires 均为 10），CPU 全 0.000s |
| 播放器兼容开关（`--selftest` + `settings-players.png`） | 第三方默认关、开启持久化、能再关回、系统播放器恒开且不可关；每项都写权限 / 收益 / 后果；权限声明与 `MediaService.permissionsRequested(for:)` 逐条相等；第三方=「不需要额外权限」，系统播放器=Automation |
| 网易云菜单栏 AX（只读，pid 90938） | `AXExtrasMenuBar = nil`、`AXChildren` 为空（当前没有状态栏项）；同一套代码在系统时钟项上读到 `AXValue` 动态文字，证明通道可用但网易云当前无对象 |
| `com.apple.MenuBarAgent`「播放中」项（只读，2026-11-15 15:55–16:25） | 该项**间歇存在**（16:01 有一次 6 项、含 `desc=播放中`，其余时段恒为 5 项；同期网易云 `pmset` 断言持续 `is playing music`）。捕获时 `AXTitle/AXValue/AXHelp` 全为 nil、`AXChildren=0`（无可遍历的 `AXMenu`）。结论：**未验证、低优先、暂停投入**；不再挂监听、不再请用户切歌 |
| bundle 内二进制一致性 | sha256 **相同**：`135408c1…368d91`（bundle 内与 `.notch-build/out/Products/Release/Brimio` 逐字节一致）。上一轮的 `6f516b57…` / `1fe5adf4…` 分叉是因为 bundle 被人手重签过；现已用 `CONFIG=release SCRATCH=… OUT=… bash Scripts/make-app.sh` 干净重打，脚本只 `cp`、不跑 `codesign`，`cp` 不改字节，因此 sha 必然相等。上表所有探针都跑 bundle 内这个路径 |
| 真实播放（曲名/歌手/封面一致、按钮生效） | **待你在 Music 里放一首歌后跑** `--media-probe` |
| 拒绝授权 / 跳设置 | **待 `.app` 首次启动时验证**（需要你在系统弹窗点「不允许」） |

### WindowServer bounds 与 frame 的缩放差异（已查清，不再放宽断言）

现象（2026-11-14 那一轮，窗口当时是 316×148）：`CGWindowList` 报的窗口 bounds 稳定为 286×134 @ (592,47)，而 `panel.frame` 一直是 316×148 @ (577,808)。比例 0.905，宽高比与水平居中都保持。窗口后来改成 316×232，缩放的成因与标定逻辑不受影响。

用 `--window-probe` 查清了根因（五个时间点 + 五个参考窗口）：

```text
[WPROBE] t=0ms  (+17ms)  panel frame=316.0x148.0@(577.0,808.0) cg=286.0x134.0@(592.0,47.0) backing=2.0 mode=1470x956 px=2940x1912 refresh=60.0 screen.frame=1470.0x956.0@(0.0,0.0)
[WPROBE] t=0ms  (+17ms)  control（无 hud/utility 样式、level=.normal）与上面逐项相同
[WPROBE] t=3s   (+3019ms) panel/control 与 0ms 逐项相同（100ms/500ms/1s 同样）
[WPROBE] ref-full   frame=1470.0x956.0@(0.0,0.0)  cg=1324.0x862.0@(73.0,47.0)
[WPROBE] ref-center frame=100.0x100.0@(685.0,428.0) cg=90.0x90.0@(690.0,433.0)
[WPROBE] VERDICT: bounds == frame × 桌面变换，残差 1.39pt（CG bounds 逐边取整）—— 对不上的两个量是
         【NSScreen.frame / CGDisplayBounds 的 point 空间】与【CGWindowList 的全局空间】；窗口自身尺寸与位置没有偏差
[WPROBE] VERDICT: 对照窗口（无 hud/utility 样式、level=.normal）合成 rect 完全相同 —— 与面板样式、窗口层级无关
```

结论：

1. **不是启动瞬态**：0/100/500ms/1s/3s 五个时刻的 frame、contentLayoutRect、CG bounds、backingScaleFactor、CGDisplayMode 完全一致。
2. **不是面板样式**：不设 `.hudWindow` / `.utilityWindow`、`level = .normal` 的无边框对照窗口，合成 rect 与面板逐字节相同（`panel composites exactly like a plain window of the same frame`，0 容差）。
3. **是坐标系**：`NSScreen.frame = CGDisplayBounds = CGDisplayMode = 1470×956`、`backingScaleFactor = 2`、`CGDisplayPixelsWide = 2940`，这些都自洽；但 `CGWindowList` 的全局空间里整块桌面是 **1324×862 @ (73,47)** —— 等比缩小到 ≈0.90（宽 0.9007、高 0.9017，逐边取整带来 ±0.001 抖动）并居中留 73/47 内边距（`73+1324+73 = 1470`、`47+862+47 = 956`）。用 5 个已知位置的参考窗口（左下、右上、右下、整屏、屏幕中心）反解，同一条仿射变换都能对上，说明是**整块桌面**被变换，不是某个窗口。

所以断言恢复严格：先用两个角落参考窗口标定 `AppKit point → CG 全局空间` 的映射（正常机器上是恒等），再把 `window.frame` 映射过去做逐项比较，容差 2.5pt。上面的 0.90 缩放是那一轮测量环境的现象；当前一轮 `--selftest` 打印 `scale=1.0000/1.0000 inset=0.0/0.0`、残差 0.00pt —— 断言走的是标定后的映射，两种情况都成立。

### 肩部对称性（闭合加宽 28pt 之后）

`--shoulder-probe` 在 @4x 下逐行量左右边界（覆盖率反插值到亚像素），和 `NotchShape` 二次曲线的解析解比较：

```text
[SHOULDER] closed        shape=183x32 offset=0.0  rows=128 maxMirrorDiff=0.00px spread=0.00px maxCurveError=1.47px PASS
[SHOULDER] closed+badge  shape=211x32 offset=14.0 rows=128 maxMirrorDiff=0.00px spread=0.00px maxCurveError=1.47px PASS
[SHOULDER] closed 直边段边缘亮度 背景:177 左-2:178 左-1:178 左+0:12 左+1:0 左+2:0 右-2:0 右-1:0 右+0:12 右+1:178 右+2:178
```

- 左右逐行内缩量**完全相同**（`maxMirrorDiff = 0.00px`，128 行）；两侧抗锯齿灰度也是镜像的（12 / 0 ↔ 0 / 12）。
- 两侧都落在同一条二次曲线上：y=1pt 内缩 3.99、y=3pt 5.50、y=6pt 6.00（解析解 6·(2t−t²)，t=√(y/6)），最大偏差 1.47px（0.37pt，来自按行取中心近似）。
- 加宽只作用在中间直边段：183 → 211 后拓扑位移 offset=14，两个肩部形状与未加宽时逐行一致。
- 放大图：`notch-m1/closed-shoulder-left-4x.png`、`closed-shoulder-right-4x.png`（各 40pt 宽 × 44pt 高 @4x = 160×176px）。

所以**右肩没有外翻，路径不需要改**。之前渲染图上「右边像圆角外翻」，其实是 20×20 缩略图（自身带 4pt 圆角）紧贴右肩 8pt 处、两个圆角并排产生的观感；形状本身左右镜像。

### `.app` 打包（未签名）

`bash Scripts/make-app.sh` 只做三件事：`swift build`、`cp` 二进制到 `Contents/MacOS`、写 `Info.plist`（含 `NSAppleEventsUsageDescription`）。**不跑 `codesign`，也不额外 `chmod`**（`cp` 保留可执行位），产物是本机直接 `open` 就能启动的未签名 bundle。

代价：arm64 上链接器仍会给二进制打 ad-hoc 标记，TCC 按这个身份（含二进制内容）记授权 —— **重新构建后可能重新弹一次授权**。需要稳定身份时再自行 `codesign --force --sign - --identifier io.github.yunyu697.brimio`。

版本号不在脚本里手写：`make-app.sh` 从 `git describe --tags --exact-match` 取 tag，经 `Scripts/version-check.sh` 校验后注入 `CFBundleShortVersionString`（去掉 `v` 与预发布后缀），`CFBundleVersion` 取 `git rev-list --count HEAD`；注入后回读 plist 与 tag 比对，不一致直接 FAIL。没有精确 tag 时注入 `0.0.0/0` 并打印 WARN，只用于本地调试。

名字同样不在脚本里手写：显示名、`.app` 名、bundle id、GitHub 仓库名、Release 资产模板都来自 [Config/naming.env](Config/naming.env)，代码侧读生成文件 `Sources/Brimio/Generated/Naming.swift`（`Scripts/naming.sh --emit-swift`），漂移由 `naming.sh --check` 报出。Release 资产固定为 `brimio-vX.Y.Z.zip`（含预发布后缀时如 `brimio-v0.1.0-alpha1.zip`），`PACKAGE=1` 时由同一模板生成到 `dist/`。


---

## M3：文件架（拖入 / 列表 / 拖出）

信息分级（每条先答「不显示会怎样」）、版式预算、交互边界见 [DESIGN.md](DESIGN.md)「文件架（M3）」；本节只记录实现与验收。

**只读展示所需的最少元数据**：`FileManager.attributesOfItem` 取 `size`，`NSWorkspace.icon(forFile:)` 取类型图标。不读文件内容、不生成缩略图、不拷文件——`ShelfItem` 只有 `url` + `fileSize`，条目只是引用。`FileShelfStore` 的每一个写操作（`add` / `remove` / `pruneMissing` / `applyDragOut`）都只改数组，不碰磁盘。

### 五个状态的自报尺寸

`PageMetrics.shapeSize(for: .files, shelfCount:)` 直接派生，`--selftest` 逐状态打印（不是只断言最大那个）：

```text
[SHELF] 0 条 -> 248x104 内容 32/104 30.8%
[SHELF] 1 条 -> 248x104 内容 32/104 30.8%
[SHELF] 2 条 -> 248x144 内容 72/144 50.0%
[SHELF] 3 条 -> 248x184 内容 112/184 60.9%
[SHELF] 4 条 -> 248x212 内容 140/212 66.0%
```

与 DESIGN 的版式表逐行一致；`panel height cap stays at 212pt` 单独断言上限，防止以后回到 224。溢出线索只有「第 4 行露出 20pt」，不靠滚动条、不出计数文字。

第一版给的 8pt 是错的：图标 20pt 在 32pt 行里垂直居中、顶部缩进 6pt，视口 128 时第 4 行只能看到 6→8pt 的一条白杠，读起来像脏点。加 12pt 到 20pt 后图标主体与文件名上半行才露出来。

### 三条拖放验收怎么跑出来的

真实文件拖拽**无法在本仓库里自动化**：它要求一个持有 `NSPasteboard(name: .drag)` 拖动会话的外部进程与真实鼠标事件流，`--selftest` 进程既不是拖动源也没有辅助功能权限去合成全局鼠标。所以验收用**控制器 API 级驱动 + 真实等待采样**：

| 验收 | 驱动 | 采样 | 实测 |
|---|---|---|---|
| 非拖动时 `ignoresMouseEvents` 恒 true | 先断言闭合态穿透 | 立即 | `true` |
| 拖动中悬停 > 0.3s 不展开 | `controller.beginFileDrag()`（内部置 `isFileDragTarget`、`setInteractive(true)`） | `sleep(0.45)` 后读 `vm.isOpen`，0.45 > `hoverDelay` 0.3 | `open=false after 0.45s`；同时 `ignoresMouseEvents=false`（收 drop 必须能接收事件） |
| 松手 200ms 内恢复穿透 | `controller.endFileDrag()` | 立即 + `sleep(0.2)` 再读 | 立即 `true`，200ms 后仍 `true` |

采样点是 `panel.ignoresMouseEvents` 与 `vm.isOpen` 两个离散状态，不采中间动画帧——这三条验收问的是「展开/穿透有没有发生」，不是「动画第几帧在第几像素」。

### 死链规则的可复现验证

- **move 到别处后立即消失**：`applyDragOut(url:operation:.move)` 对 `.move` 直接移除该条（拖出即已移动，原路径失效）；`.copy` 保留。selftest 用真实临时文件跑一遍，`move` 后列表只剩其余条目。
- **外部删除后下一次用户动作触发移除**：`pruneMissing` 挂在 `open()` 与 `select(.files)` 上；selftest 物理删除临时文件后调用 `open()`，断言 `pruned=["素材.zip"] remaining=0`。

实现上踩到一个坑：`URL.resourceValues(forKeys: [.isRegularFileKey])` 对**已删除/已移走**的路径仍返回 `1`（同一路径 `FileManager.fileExists` 为 false），导致死链不消失。已改为 `FileManager.attributesOfItem` + `attributes[.type] == .typeRegular` 判活，`makeItem` 与 `pruneMissing` 共用这一条。

### 离屏渲染

`ImageRenderer` 不支持 `ScrollView`（画成黄色/空白占位），所以 `--render` 时把 `FileShelfRendering.isOffscreen` 置 true，列表改用同尺寸 `.clipped()` 容器；运行时仍是 `ScrollView`。这条开关默认 `false`，全仓唯一的赋值点在 `main.swift` 的 `renderSnapshots` 里（`--render` 分支），正常运行路径碰不到它。

**这条捷径只能证明裁切位置，不能证明滚动行为。** 离屏图能说明「140pt 视口里前三行完整、第四行露 20pt」，不能说明滚轮/触控板真的能滚、滚动条是否遮挡、滚动到底会不会回弹。滚动属于手动验收，见下一节。

`--render` 新增：`open-files.png 248x104`（空架）、`open-files-1.png 248x104`、`open-files-2.png 248x144`、`open-files-3.png 248x184`、`open-files-4.png 248x212`（shape 即上文自报值）。渲染用 5 个中性临时文件（`设计稿-final.pdf` / `IMG_2043.HEIC` / `录音.m4a` / `素材包.zip` / `笔记.md`），不发任何系统请求。

人工核对三件事：空架图里只有虚线框与「暂无文件，拖入后在这里显示。」、chrome 行右侧**没有**垃圾桶（隐藏但保留 28pt 占位）；≥4 条图里 3 行完整（图标 20 / 文件名 / 大小右对齐）、第 4 行露出 20pt（图标主体 + 文件名上半行，如 `素材包.zip` 与 `23 MB`）；没有文件名被尾部截断或挤压大小槽位。两张图底部两角的黄色小块与 `open-home.png` 完全一致，是 `ImageRenderer` 阴影遮罩的既有占位，不是本轮引入。

### 手动验收清单（文件架）

前置：`CONFIG=release bash Scripts/make-app.sh` 打包，`open build/Brimio.app` 启动；准备 5 个临时文件放在桌面（不要用真实工作文件，其中一条要用于删除）。

| # | 做什么 | 预期看到什么 | 不符合时怎么判断 |
|---|---|---|---|
| 1 | 从 Finder 拖 1 个文件到闭合态刘海上，松手 | 刘海自动展开并切到「文件架」，列表第一条就是该文件（图标 + 文件名 + 大小）；原文件仍在 Finder 原位置 | 松手后没展开 / 展开停在首页 / 列表为空 / 文件被移走——任一出现即 FAIL；再查 Console 里有没有 `addShelfFiles` 的落点日志 |
| 2 | 依次拖入共 5 个文件，用滚轮或触控板在列表上滚动 | 第 4、5 条能滚出来并完整显示；滚动时右侧出现系统 overlay 滚动条，**不压住文件名**（overlay 不占布局宽；若系统设为「始终显示滚动条」，则预留约 11–15pt，文件名更早中间截断，但仍不与滚动条重叠） | 滚不动（说明 `ScrollView` 没吃到滚动事件，多半被面板穿透逻辑吃掉）/ 滚到底看不到第 5 条 / 滚动条盖住文件名——任一出现即 FAIL |
| 3 | 按住 ⌘ 把列表里的某条拖到桌面，松手 | 该条**立即**从列表消失（move 语义）；桌面上出现该文件，Finder 原路径已不存在 | 条目还在（残留死链）/ 原文件仍在原处但桌上多一份（成了 copy）/ 两者都不在（文件丢失，最严重）——任一即 FAIL |
| 4 | 在 Finder 里删掉一个已入架的文件（移到废纸篓即可），回到面板重新展开或切到「文件架」 | 该条自动消失，列表数量减 1，其余条目不动 | 该条仍在（点它是死链）/ 整表被清空 / 其余条目顺序被打乱——任一即 FAIL |
| 5 | 拖一个文件从刘海上方**经过**但不停留（不在刘海上悬停），移开后再看 | 不展开；闭合态保持原样，鼠标离开后 300ms 内不延时展开 | 经过瞬间就展开（说明拖动态把 hover 打开逻辑带起来了）/ 移开后仍然展开——任一即 FAIL |

第 3、4 条对应 `--selftest` 里已自动化的死链断言（`moving an entry out removes it immediately`、`deleting outside the app removes the entry on the next user action`）；这里用手真实操作复核一遍，因为自动化只驱动了 `FileShelfStore`，没有驱动真实的 ⌘ 修饰键与 Finder 删除动作。

界面文案只写已实现的行为：空架「暂无文件，拖入后在这里显示。」——没有「自动整理」「云端同步」「过期提醒」这类未验证承诺。

---

## 后续可扩展点

1. **多屏**：`ScreenGeometry.displayUUID` 已经预留，把 `NotchWindowController` 改成 `[String: Controller]`，按 UUID 懒创建/清理即可。
2. **真实刘海形状**：`closedSize(for:)` 已用 `safeAreaInsets.top` 与 `auxiliaryTopLeftArea/RightArea` 推导；需要更精细时可改成按机型查表。
3. **全屏/Space 覆盖**：`level = .mainMenu + 3` + `.canJoinAllSpaces` 已能覆盖大多数场景；要压在原生全屏之上，可再加私有 `CGSSpace`（代价是不可上架、跨版本易碎）。
4. **锁屏显示**：需要 SkyLight 私有框架，建议单独文件隔离。
5. **手势**：在 `NotchRootView` 上加 `DragGesture`，超过阈值时调用 `vm.open()/close()`；命中仍由 `contentShape` 控制。
6. **内容路由**：`NotchRootView` 目前写死一段占位内容，替换成 `switch coordinator.currentView` 即可接 Home / Shelf 这类页面。
7. **菜单栏点击的进一步保证**：如果遇到某些系统版本仍拦截点击，可把 `interactiveRect` 调小到精确外形，或在闭合态直接 `orderOut` 窗口、只保留一个极小的 hover 感应窗口。

---

## License

本项目整体以 **GNU General Public License v3.0（GPL-3.0）** 分发，全文见仓库根目录的 [LICENSE](LICENSE)。

为什么是 GPL-3.0：`Sources/Brimio/NotchShape.swift` 里刘海形状的路径几何（顶部圆角、底部外扩曲线与 `Shape` 的 path 构造）源自一个以 GPL-3.0 授权的上游项目。衍生自 GPL-3.0 代码的作品需要以同一协议分发，因此本仓库采用 GPL-3.0。具体来源、链接与上游 LICENSE 的 sha256 记录在 [NOTICE](NOTICE)。

对第三方使用者来说，这意味着（以 LICENSE 全文为准）：

- 分发本项目的源码或二进制（含改动版）时，需要一并提供 GPL-3.0 全文与源码，并保留版权与来源声明；
- 若分发二进制，还需要让接收者能够获得对应源码；
- 不能对本项目追加额外限制（例如把衍生作品改成闭源专有分发）；
- 上游项目的作者与版权持有人保留其各自权利，本项目不改变这一点。

本仓库不附带任何超出 GPL-3.0 的额外授权声明。
