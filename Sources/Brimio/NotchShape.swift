//
//  NotchShape.swift
//  Brimio
//
//  刘海路径几何：从左上角 (minX, minY) 起笔一圈，4 条直线 + 4 段三次贝塞尔。
//
//  ## 推导（本文件自洽，不依赖任何第三方实现）
//
//  形状是一个「顶部内凹肩 + 底部外凸圆角」的圆角矩形。四个角各自独立，取同一套约束：
//
//  1. 角点方区边长 = 该角的切点偏移 t（顶部 `topTangentOffset`，底部 `bottomTangentOffset`）。
//     t 同时是 x / y 两个方向的偏移量，所以角上被切掉的正是一个 t×t 的方区。
//  2. 曲线两端分别与相邻直线**相切**：顶部肩从顶边（水平）切出、切到侧壁（垂直）；
//     底部角从侧壁（垂直）切出、切到底边（水平）。相切是硬约束——不满足就会在接缝处出现折角。
//  3. 三次贝塞尔有 4 个控制点。端点已知（2 个），两个切线条件各消掉 1 个自由度
//     （起点控制点必须落在顶边/侧壁所在直线上，终点控制点同理），剩下 2 个自由度。
//     取「控制点到角点的距离 = 该段方区边长的 1/3 与 2/3」——这是让曲率在两端都取到最小、
//     且曲线最贴近 45° 直线的对称分配；换成 1/4 或 1/2 会让肩部出现可见的「鼓包」或「内缩」。
//
//  由此得到顶肩（左上）的控制点：
//      P0 = (minX, minY)            C1 = (minX + 2t/3, minY)
//      C2 = (minX + t, minY + t/3)  P3 = (minX + t, minY + t)
//  该曲线的边界在高度 y 处为 `x = minX + t(2√(y/t) − y/t)`，在 y = t/2 处为 `minX + 0.914t`；
//  方角（t = 0）给 0，外凸圆弧给 0.134t。验收断言就用这三个互不重叠的值做分辨。
//
//  顶部切点偏移：闭合 6 / 展开 19；底部切点偏移：闭合 14 / 展开 24。
//  两个偏移都参与 animatableData，开合过程中形状连续插值。
//

import SwiftUI

struct NotchShape: Shape {
    /// 顶部切点偏移：闭合 6 / 展开 19。参数语义见 `ScreenGeometry.shoulderTangentOffset`。
    private var topTangentOffset: CGFloat
    private var bottomTangentOffset: CGFloat

    init(
        topTangentOffset: CGFloat? = nil,
        bottomTangentOffset: CGFloat? = nil
    ) {
        self.topTangentOffset = topTangentOffset ?? 6
        self.bottomTangentOffset = bottomTangentOffset ?? 14
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topTangentOffset,
                bottomTangentOffset
            )
        }
        set {
            topTangentOffset = newValue.first
            bottomTangentOffset = newValue.second
            // 自测钩子：路径几何不变，这里只多记一行插值序列，
            // 用来证明开合过程中存在「中间形状」（圆角也在插值）。
            // 只在 DEBUG 构建存在，Release 下逐帧插值不产生任何额外写入。
            #if DEBUG
            NotchLayoutProbe.recordShape(top: newValue.first, bottom: newValue.second)
            #endif
        }
    }

    /// 路径构造：顶边 → 左肩 → 左侧壁 → 左下角 → 底边 → 右下角 → 右侧壁 → 右肩 → 顶边闭合。
    ///
    /// 三段控制点的取法见文件头推导：控制点到角点的距离取方区边长的 1/3 与 2/3，
    /// 保证两端切线分别与顶边 / 侧壁 / 底边重合。`t = 0` 时三段曲线退化成直线，得到方角。
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let t = topTangentOffset
        let b = bottomTangentOffset
        let third = CGFloat(1.0 / 3.0)
        let twoThirds = CGFloat(2.0 / 3.0)

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        // 左肩（内凹）：从顶边切出，切到左侧壁。
        path.addCurve(
            to: CGPoint(
                x: rect.minX + t,
                y: rect.minY + t
            ),
            control1: CGPoint(
                x: rect.minX + t * twoThirds,
                y: rect.minY
            ),
            control2: CGPoint(
                x: rect.minX + t,
                y: rect.minY + t * third
            )
        )

        // 左侧壁：直边。
        path.addLine(
            to: CGPoint(
                x: rect.minX + t,
                y: rect.maxY - b
            )
        )

        // 左下角（外凸）：从侧壁切出，切到底边。
        path.addCurve(
            to: CGPoint(
                x: rect.minX + t + b,
                y: rect.maxY
            ),
            control1: CGPoint(
                x: rect.minX + t,
                y: rect.maxY - b * third
            ),
            control2: CGPoint(
                x: rect.minX + t + b * third,
                y: rect.maxY
            )
        )

        // 底边：直边。
        path.addLine(
            to: CGPoint(
                x: rect.maxX - t - b,
                y: rect.maxY
            )
        )

        // 右下角（外凸）。
        path.addCurve(
            to: CGPoint(
                x: rect.maxX - t,
                y: rect.maxY - b
            ),
            control1: CGPoint(
                x: rect.maxX - t - b * third,
                y: rect.maxY
            ),
            control2: CGPoint(
                x: rect.maxX - t,
                y: rect.maxY - b * third
            )
        )

        // 右侧壁：直边。
        path.addLine(
            to: CGPoint(
                x: rect.maxX - t,
                y: rect.minY + t
            )
        )

        // 右肩（内凹）：从侧壁切出，切回顶边。
        path.addCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control1: CGPoint(
                x: rect.maxX - t,
                y: rect.minY + t * third
            ),
            control2: CGPoint(
                x: rect.maxX - t * twoThirds,
                y: rect.minY
            )
        )

        // 顶边：直边，闭合。
        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        return path
    }

    /// 点是否落在形状实体内（`drop` 落点校验用）。
    ///
    /// `Path.contains` 与 `clipShape` 用的是同一条路径，因此「能放下的地方」
    /// 就是「看得见的地方」：顶部内凹肩与底部圆角外侧的透明区都不接受落点。
    func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        path(in: rect).contains(point)
    }
}
