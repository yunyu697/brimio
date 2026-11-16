//
//  NotchShape.swift
//  Brimio
//
//  刘海路径几何：从左上角 (minX, minY) 起笔逆时针一圈，4 条直线 + 4 条二次贝塞尔。
//  顶部角的控制点落在「角点沿顶边内移 t」处、终点 (minX+t, minY+t)，于是起点切线水平、
//  终点切线垂直；t 是切点偏移（x / y 共用），不是 cornerRadius。
//  顶部切点偏移：闭合 6 / 展开 19；底部切点偏移：闭合 14 / 展开 24。
//  两个偏移都参与 animatableData，开合过程中形状连续插值。
//  来源与协议声明见仓库根目录 NOTICE。
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

    /// 路径构造（逆时针）：顶边 → 左肩 → 左侧壁 → 左下弧 → 底边 → 右下弧 → 右侧壁 → 右肩 → 顶边闭合。
    ///
    /// 顶部肩是**内凹**的：控制点在 `(minX + t, minY)`（角点沿顶边内移 t），终点 `(minX + t, minY + t)`，
    /// 曲线中点过 `(minX + 0.75t, minY + 0.25t)`——比同半径圆弧更贴角点约 6%，所以 t 不是 cornerRadius。
    /// 该曲线在高度 y 处的边界是 `x = minX + t(2√(y/t) − y/t)`；y = t/2 时为 `minX + 0.914t`。
    /// t 同时是 x / y 方向的切点偏移，占一个 t×t 的方区；t = 0 退化成方角。
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topTangentOffset,
                y: rect.minY + topTangentOffset
            ),
            control: CGPoint(
                x: rect.minX + topTangentOffset,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX + topTangentOffset,
                y: rect.maxY - bottomTangentOffset
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topTangentOffset + bottomTangentOffset,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + topTangentOffset,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topTangentOffset - bottomTangentOffset,
                y: rect.maxY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - topTangentOffset,
                y: rect.maxY - bottomTangentOffset
            ),
            control: CGPoint(
                x: rect.maxX - topTangentOffset,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topTangentOffset,
                y: rect.minY + topTangentOffset
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control: CGPoint(
                x: rect.maxX - topTangentOffset,
                y: rect.minY
            )
        )

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
