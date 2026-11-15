// 本文件由 `Scripts/naming.sh --emit-swift` 从 `Config/naming.env` 生成，不要手改。
// 改名字：编辑 Config/naming.env，然后重跑该命令（`--check` 会在 selftest / CI 里发现漂移）。
enum Naming {
    /// 产品显示名。
    static let appDisplayName = "Brimio"
    /// .app 包名 / 可执行名。
    static let bundleName = "Brimio"
    /// 反向域名 bundle id。
    static let bundleID = "io.github.yunyu697.brimio"
    /// 设置窗口标题。
    static let settingsWindowTitle = "播放器兼容"
    /// 更新检查的数据源。
    static let updateOwner = "yunyu697"
    static let updateRepo = "brimio"

    /// Release 资产名。模板来自 Config/naming.env 的 RELEASE_ASSET_TEMPLATE，
    /// 更新检查器用它匹配资产，打包脚本用它命名产物——两边同源。
    static func releaseAssetName(tag: String) -> String {
        "brimio-{tag}.zip".replacingOccurrences(of: "{tag}", with: tag)
    }

    /// 从资产名反解 tag；不匹配任何模板形状时返回 nil（更新检查器的「命名不符」用例）。
    static func versionTag(fromAssetName name: String) -> String? {
        let suffix = ".zip"
        let prefix = "brimio-"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(name[start..<end])
    }
}
