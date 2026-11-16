# Brimio 发布工程方案

> 范围：更新通道、内置加速镜像、安装包形态与版本策略。
> 约束：无 Apple 开发者证书、不做代码签名与公证、不做更新包签名（已排除，不作为可选项）、
> 当前 CI 因账单无法运行、仓库私有。
> 本文件只描述「发布侧」与「客户端应有的行为」；应用内实现需要改 `Sources/`，不在本轮。

---

## 1. 事实基线

| 项 | 现状（已核实） | 直接后果 |
| --- | --- | --- |
| 已有发布 | `v1.0.0-alpha1`，资产 397418 B，sha256 `83f5df54…5076b`，包内 `1.0.0` / build `4` | 可当作第一份真实样本做全链路校验 |
| 签名 | 无证书、未 codesign、未公证；更新包也不签名 | 首次打开被 Gatekeeper 拦；完整性只能靠 sha256 |
| CI | `.github/workflows/release.yml` 因账单无法运行，只有仓库所有者能处理 | 发布必须能在本机一条命令走完，不能依赖 Actions |
| 仓库可见性 | 私有 | 匿名 `releases/download/...` 与 `api.github.com/.../releases` 均不可用（实测 404） |
| 第三方镜像 | 只能转发公开 URL | 仓库私有期间，镜像对我们的资产一律 404 |
| 应用内更新代码 | `Sources/` 内只有 `Naming.swift` 里的 owner/repo 常量，没有更新检查实现 | 本轮交付「规范 + 可运行工具链」，Swift 侧接入留到下一轮 |
| 架构 | alpha1 可执行文件是 `arm64` only | **决策 D4（2026-11-16）：只出 arm64，不出 universal。** Intel Mac 不在支持范围；清单 `arch` 字段保留，用于下载页标注与客户端提示，不用于构建 |

关键判断：**私有仓库 + 不签名** 这两条同时成立时，「自动更新」只对仓库所有者可用（凭据来自本机 `gh` 登录）；
要让其他人也能更新，必须先把「分发端点」公开，见第 9 节。

---

## 2. 成熟方案的机制级拆解

四个方向都按同一组问题拆：怎么比版本、怎么取资产、怎么校验、失败怎么退、怎么分稳定/预发布、前置条件是什么。

| 方案 | 版本比较 | 取资产 | 校验 | 失败回退 | 稳定 / 预发布 | 前置条件 | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Sparkle 2（appcast + EdDSA）** | `CFBundleVersion`（build）严格递增 | appcast 里的 `enclosure url`，可多个；支持 delta | EdDSA 签名 appcast + 包；可选 Apple 签名校验 | 自带重试与「跳过此版本」；失败保留旧包 | `<sparkle:channel>` 标签 + `sparkle:phasedRolloutInterval` | 引入 `Sparkle` 依赖并改 `Package.swift`/`Sources`；私钥要长期保管（Keychain 或文件） | **否决**：① 改 `Sources` 越界；② 需要长期密钥，与「不做签名」冲突；③ 私有仓库下 appcast 与资产同样需要鉴权；④ 功能收益（delta、静默安装）在本项目体量下不足以抵消前三条 |
| **GitHub Releases API 轮询** | 只能按 `tag_name`/`published_at` 排，版本语义要自己补 | 匿名 `browser_download_url`；私有仓库要走 assets API + token | 只能靠 Release 附带的 `.sha256` 文件（要对同一 tag 的资产做二次请求） | 只能整体重试；没有通道概念 | `prerelease` 布尔 + 自定义 tag 约定 | 私有仓库需在客户端保存 token；匿名限速 60 次/小时 | **否决为唯一来源**：能表达的信息太少（无镜像、无最低系统版本、无逐条哈希），且私有模式下必然要把凭据塞进客户端 |
| **自建静态清单 + 有序镜像**（本方案） | 清单里写 build，客户端只比 build | 清单给 canonical URL；客户端按内置模板拼出镜像候选 | 清单写死 sha256 + size；每个候选下载后逐字节比对 | 逐镜像切换，全部失败即放弃且不落盘 | 按通道拆成不同清单文件，生成与客户端各过滤一次 | 一个能放静态文件的地址（本方案用固定 tag 的 Release） | **选定**：零依赖、可离线校验、失败路径清晰，且完全不需要证书 |
| **Homebrew cask / 镜像站转发** | brew 自己算（cask 里写 `version` + `sha256`） | cask 的 `url` 指向公开资产；镜像站做 URL 前缀转发 | cask 自带 `sha256` | `brew upgrade` 重试 | 不支持预发布通道 | 需要公开仓库；自建 tap 需要额外仓库与维护 | **不选作更新机制**：它是「安装渠道」不是「自更新」；可作为将来的第三条分发路径，但解决不了本轮问题 |

补充事实（实测，本机网络）：

- 私有资产匿名访问：`github.com/...` 与 `ghfast.top/...`、`ghproxy.net/...` 全部 `404`（约 1.0–2.8 s 返回）。
- 同一批镜像取公开小资产：`github.com` / `ghfast.top` / `ghproxy.net` 全部 `206`（Range 生效），耗时 1.7–2.2 s。
- 结论：镜像本身是活的，取不到我们的包是「可见性」问题，不是「镜像坏了」问题。这个区分写进了 `Scripts/probe-mirrors.sh` 的判定逻辑。

---

## 3. 选定方案与依据

**按通道分文件的 JSON 清单 + GitHub Release 资产 + 内置有序镜像 + sha256 唯一校验。**

依据（按权重）：

1. **能在本机闭环**：CI 挂了也不影响；`Scripts/release.sh` 一条命令完成构建、校验、记清单、生成 feed、打印上传命令。
2. **不引入任何密钥**：清单只写 sha256 与版本串，客户端没有任何需要长期保管的秘密；也不需要在 app 里放 token。
3. **失败路径可穷举**：只有三种结局——拿到并校验通过、明确没更新、明确失败（且不留半成品），没有模糊态。
4. **可持续**：换托管（对象存储、Gitee、Pages）只改一个 URL 与镜像表，不动客户端逻辑。

被否决方案的核心否决点已写在上一节表格最后一列，这里不重复。

---

## 4. 更新通道设计

### 4.1 组件与托管位置

```
客户端 ──①取清单──> https://github.com/<owner>/<repo>/releases/download/feed/feed-stable.json
       │                                     └─ 固定 tag = feed 的 Release，URL 与版本无关
       └──②下载资产──> 按 Config/mirrors.env 顺序尝试
                        github-direct → ghfast → ghproxy-net →（gitee / 对象存储，未启用）
```

- 清单存在 tag 固定为 `feed` 的 Release 上，资产名固定（`feed-stable.json` / `feed-beta.json`），
  每次发布用 `gh release upload --clobber` 覆盖。好处：URL 永远不变，客户端不需要知道版本号就能检查。
- 这个 Release 标 `--prerelease --latest=false`，不会被 GitHub 当成「最新版本」，也不影响版本 Release 的 latest 语义。
- 换托管方式（例如以后上对象存储）只需要改客户端的 feed 基址，镜像表不动。

### 4.2 清单格式（schema = 1）

```json
{
  "schema": 1,
  "channel": "stable",
  "generated_at": "2026-11-16T00:00:00Z",
  "min_os": "13.0",
  "item_count": 1,
  "items": [
    {
      "tag": "v1.0.0",
      "version": "1.0.0",
      "build": 12,
      "stage": "stable",
      "order_key": "00001.00000.00000.3.00000",
      "released_at": "2026-11-16T00:00:00Z",
      "min_os": "13.0",
      "asset": "brimio-v1.0.0.zip",
      "size": 397418,
      "sha256": "<64 hex>",
      "arch": "arm64",
      "url": "https://github.com/<owner>/<repo>/releases/download/v1.0.0/brimio-v1.0.0.zip",
      "notes_url": ""
    }
  ]
}
```

字段约束：

- `sha256` / `size` 由 `Scripts/release-verify.sh` 从**真实资产**算出，不接受手写。
- `build` 必须等于包内 `CFBundleVersion`；`release-verify --expect-build` 会挡掉不一致。
- `channel` 必须等于请求的通道，否则整份清单作废（防止把 beta 清单当 stable 用）。
- 清单只描述「已发布」的东西；`Release/feed/items.jsonl` 是发布台账，一行一条，随发布提交进 tag。

### 4.3 版本比较规则

**唯一单调键是 `CFBundleVersion`（= tag 所在提交的提交数）。** 版本串只用于展示与通道判定。

原因：`CFBundleShortVersionString` 会丢掉 `-alphaN` 后缀，`1.0.0-alpha1` 和 `1.0.0` 在 plist 里都是 `1.0.0`，
用版本串比较会出现「alpha 与正式版同号」的歧义；提交数是天然单调的，能覆盖任意 tag。

`order_key`（`major.minor.patch.rank.num`，rank：alpha=0 / beta=1 / rc=2 / stable=3）只用于：

- 清单内排序（可读性）；
- 「同版本不同 stage」的先后判定（alpha1 < beta1 < RC1 < 正式版）。

判定顺序（客户端）：`stage 在通道可见集合内` → `build > 本机 build` → `min_os ≤ 本机系统` → 取 `build` 最大者。
`build ≤ 本机` 一律视为不更新，这同时挡住降级攻击与旧清单重放。

通道可见性（生成时过滤一次，客户端再过滤一次）：

| 清单 | 可见 stage | 说明 |
| --- | --- | --- |
| `feed-stable.json` | `stable` | 正式用户只看到正式版 |
| `feed-beta.json` | `stable beta rc` | beta 用户能看到正式版（正式版通常更新） |
| `feed-alpha.json` | 全部 | 只在本机生成（`--include-alpha`），**永不发布** |

### 4.4 下载与校验流程

1. 取清单（https，10–20 s 超时，最多 5 次重定向，仅允许 https→https）。
2. 解析并选条目（见 4.3）；无可用条目 → 退出码 2。
3. 按镜像表顺序下载到临时文件；每个候选依次检查：字节数 → sha256。
4. 通过后落盘，并写同名 `.sha256`（裸文件名格式，用户可 `shasum -c` 复核）。
5. 解开包读 `Info.plist`，交叉核对 tag / build / bundle id / 最低系统（`release-verify.sh`）。
6. 任何一步失败：删除下载物，退出码 4，不存在「跳过校验继续装」的分支。

### 4.5 检查频率与静默策略

| 时机 | 行为 |
| --- | --- |
| 启动后 10 s | 静默检查，不弹窗、不占用 UI |
| 之后每 24 h（±15% 抖动） | 静默检查；抖动避免同一时刻集中请求 |
| 连续失败 | 退避 24 h → 48 h → 72 h，封顶 72 h，不清空用户已有授权 |
| 用户手动「检查更新」 | 忽略退避立即检查；这是唯一会弹出「已是最新」文字的路径 |
| 检查到新版本 | 只提示，不自动下载、不自动替换（无签名前提下不做静默安装） |

静默的含义：检查失败不产生任何用户可见错误；只有「用户主动点」才显示结果。

### 4.6 离线 / 无网络

- 清单取不到（DNS 失败、超时、404、证书错误）→ 视为「本轮跳过」，退出码 3，不写任何状态。
- 不缓存清单副本：避免用户长期看到过期版本；下次周期重新取。
- 已经下载并校验通过的包保留在 `~/Downloads`，用户可手动安装，不因下次检查失败而删除。

### 4.7 私有模式与公开模式的差别

| | 私有模式（现在） | 公开分发（过渡后） |
| --- | --- | --- |
| 清单 | 需要凭据（`gh` 登录或 token） | 匿名可读 |
| 资产 | `gh release download`（本机凭据）或带 token 直连 | 匿名 `releases/download/...` |
| 第三方镜像 | 全部 404，**不使用** | 生效 |
| 适用对象 | 只有你本人的机器 | 所有用户 |
| 实现开关 | `Scripts/fetch-update.sh --use-gh` | 去掉 `--use-gh` 即可 |

---

## 5. 内置加速镜像

### 5.1 评估口径

| 维度 | 含义 | 判定方式 |
| --- | --- | --- |
| 可达性 | 本机能建立 TLS 并取到字节 | `Scripts/probe-mirrors.sh` 实测 code / 耗时 |
| 可校验 | 原样转发，不重打包、不改文件名 | 下载后 sha256 必须等于清单值 |
| 长期稳定 | 有明确维护方、无频繁改域名 | 人工判断 + 观察；公共反代默认「无 SLA」 |
| 授权 | 是否需要账号、是否允许转发 | 公共反代不需要；自建需要账号与费用 |
| 覆盖场景 | 是否能取私有资产 | 不能，`PUBLIC_ONLY=1` 标注 |

### 5.2 候选与实测（本机，`probe-mirrors.sh --timeout 10`）

| 镜像 | 我们的资产 | 公开样本 | 判定 |
| --- | --- | --- | --- |
| `github-direct` | 404 / 2.98 s | 206 / 2.10 s | 可达，但取不到私有资产 |
| `ghfast.top` | 404 / 1.49 s | 206 / 1.76 s | 同上 |
| `ghproxy.net` | 404 / 2.81 s | 206 / 2.22 s | 同上 |
| `gitee` | 未启用 | - | 需账号 + 手工同步 |
| `对象存储` | 未启用 | - | 需账号 + 计费 |

注：本机 DNS 走 fake-IP 代理，耗时只代表当前环境；换网络请重跑脚本，不要照抄结论。

### 5.3 顺序与切换

顺序写在 `Config/mirrors.env`，按 `MIRROR_n` 递增尝试：

1. `github-direct`（权威源；私有模式下配 `gh` 凭据仍然可用）
2. `ghfast.top`（公共反代）
3. `ghproxy.net`（同类，互为备份）
4. `gitee`（默认关闭，开通后建议排到第 1）
5. 自建对象存储（默认关闭，开通后建议排到第 1）

切换规则：任一候选失败（HTTP 错误 / 体积不符 / 哈希不符 / 超时）→ 记录原因 → 下一个，**不回退到「跳过校验」**。
全部失败 → 退出码 4，明细逐条打印（实测输出见第 10 节 S1/S2）。

### 5.4 校验落地

- 清单里的 `sha256` 是唯一真值；镜像只是搬运工，不参与信任判断。
- 每个候选都要过「体积 + 哈希」两道；体积先判可以省掉一次全量哈希，但**不能**替代哈希。
- 落盘后写 `<asset>.sha256`，用户可自行 `shasum -a 256 -c`。
- 公开模式下可再用 GitHub 服务端 `digest` 字段做交叉核对（`gh release view --json assets`），
  这是无签名条件下唯一的外部独立佐证。

### 5.5 镜像失效时的自愈与提示

- 单次失败：静默切下一个，用户无感。
- 连续 N 次某镜像失败（建议 N=3，客户端侧计数）：本轮先跳过该镜像，下次启动再试（软熔断，不写死）。
- 全部失效且已有可用包：保留旧包，提示「网络异常，稍后重试」，不提示「更新失败」这种吓人的词。
- 内置清单本身可被 feed 里的 `mirrors` 覆盖（带 `mirrors_version` 递增），这样换镜像不必发新版；
  本轮只实现内置表，覆盖机制写进下一轮客户端需求。

### 5.6 「下载加速」≠「更新通道」

- 更新通道 = 清单 + 版本判定 + 信任根（sha256）。它必须只有一个权威来源，否则无法判断「谁说了算」。
- 下载加速 = 同一份字节的不同传输路径，可以有多个、可任意增删，**不影响**更新是否发生。
- 因此：镜像只出现在「下载候选」这一层；清单地址永远只有一个（可换托管，但同时只有一个生效）。
  镜像挂了最多是下载慢，不会让客户端认为「有新版本」或「没有新版本」。

---

## 6. 失败模式清单

| # | 现象 | 检测点 | 处理 | 用户可见 |
| --- | --- | --- | --- | --- |
| 1 | 清单地址 404 / 仓库私有 | HTTP 状态 | 跳过本轮，退出码 3 | 无（手动检查时提示「无法获取更新信息」） |
| 2 | 清单 JSON 损坏 / schema 不符 | 解析异常 | 整份作废，不猜 | 同上 |
| 3 | 清单通道与请求不符 | `channel` 字段 | 整份作废 | 同上 |
| 4 | 镜像返回 HTML 错误页 | 体积不符 + 哈希不符 | 丢弃，切下一个 | 无 |
| 5 | 镜像返回同体积但被篡改的包 | sha256 不符 | 丢弃，切下一个，记一次失败 | 无 |
| 6 | 所有镜像失败 | 候选耗尽 | 不落盘，退出码 4 | 手动检查时提示「下载失败，已放弃」 |
| 7 | 下载中断（半包） | 体积不符 | 删除临时文件 | 无 |
| 8 | 包内版本与清单不符 | `release-verify` 交叉核对 | 删除下载物，退出码 4 | 手动检查时提示「更新包校验失败」 |
| 9 | 磁盘空间不足 | 写入失败 | 保留旧版本，清理 `.part` | 提示剩余空间 |
| 10 | 清单 build ≤ 本机（重放/降级） | build 比较 | 不更新 | 无 |
| 11 | 系统时间错乱 | 仅影响 `released_at` 展示 | 不参与判定（判定只看 build） | 无 |
| 12 | 首次打开被 Gatekeeper 拦 | 系统弹窗 | 见第 8 节绕行 | 有，且必须解释清楚 |
| 13 | 更新后 Automation/麦克风授权失效 | 系统权限页 | 重新授权（无证书时不可避免） | 有，需在更新说明里写明 |
| 14 | Intel Mac 装 arm64 包 | `arch` 字段 | 清单可做架构过滤（下一轮） | 有，需在下载页标注 |
| 15 | GitHub 匿名 API 限速 | 403 + `rate limit` | 计数退避，不用 API 作为唯一来源 | 无 |

---

## 7. 安装包形态与版本策略

### 7.1 zip 还是 dmg

| | zip（`ditto -c -k --sequesterRsrc --keepParent`） | dmg（`hdiutil`，附 `/Applications` 快捷方式） |
| --- | --- | --- |
| 自动更新 | **首选**：无需挂载，展开即得 `.app`，可原子替换 | 需要 attach/detach，程序化安装容易卡在挂载点 |
| 首次安装 | 解压后拖入「应用程序」，多一步 | **首选**：双击 → 拖过去 |
| 体积 | 小（无 HFS 开销） | 略大 |
| 损坏检测 | 用户可直接解压看结构 | 挂载失败即坏 |
| 结论 | 更新通道只用 zip | 只有 stable 额外发 dmg，作为首次安装的便利 |

两者都必须附同名 `.sha256`（裸文件名）。dmg 不进 feed，不参与自动更新。

### 7.2 资源命名（与 `Config/naming.env` 同源）

- zip：`{repo}-{tag}.zip` → `brimio-v1.0.0-beta1.zip`
- 校验：`brimio-v1.0.0-beta1.zip.sha256`（内容：`<64 hex>  brimio-v1.0.0-beta1.zip`）
- dmg：`brimio-v1.0.0.dmg` + `.sha256`
- 清单：`feed-stable.json` / `feed-beta.json`（tag 固定为 `feed` 的 Release）

### 7.3 版本串与构建号

| 项 | 规则 | 来源 |
| --- | --- | --- |
| tag | `vMAJOR.MINOR.PATCH[-alphaN\|-betaN\|-RCN]`，MINOR/PATCH ≤ 10 | 人工按 `Scripts/version-check.sh` 校验 |
| `CFBundleShortVersionString` | tag 去掉 `v` 与后缀 | 打包脚本注入并回读比对 |
| `CFBundleVersion` | tag 所在提交的提交数 | 自动，天然单调 |
| `BrimioReleaseTag` | 完整 tag | 本轮新增，解决「plist 里看不出预发布」的问题 |
| `BrimioChannel` | `alpha\|beta\|rc\|stable\|dev` | 本轮新增，客户端据此决定默认通道 |

### 7.4 alpha → beta → stable 过渡

| 阶段 | tag 示例 | 谁可见 | feed | GitHub Release | dmg |
| --- | --- | --- | --- | --- | --- |
| alpha | `v1.0.0-alpha1` | 只有开发机（客户端显式 `--channel alpha`） | 不发布 | 可发，标 prerelease | 不发 |
| beta | `v1.0.0-beta1` | beta 通道用户 | 写进 `feed-beta.json` | 标 prerelease，`latest=false` | 不发 |
| rc | `v1.0.0-RC1` | 同 beta | 写进 `feed-beta.json` | 标 prerelease | 不发 |
| stable | `v1.0.0` | 所有人 | 写进两个 feed | 不标 prerelease（成为 latest） | 发 |

过渡规则：

- 同一 `MAJOR.MINOR.PATCH` 内，alpha → beta → rc → stable 只靠 build 递增来「推进」，不需要改版本串语义。
- 正式版发布后，beta 通道用户看到 build 更大的 stable，会自动升到 stable；不需要额外动作。
- alpha 永远不发布 feed：`release-feed.sh --emit` 默认不出 alpha 文件；`release.sh --publish` 拒绝 alpha（除非显式 `--allow-alpha-publish`）。

### 7.5 架构

**决策 D4（2026-11-16，项目所有者拍板）：只出 `arm64`，不出 universal，不做 `lipo` 合并。**

- 影响：Intel Mac 无法运行，需在下载页与 Release 说明里明确写「Apple Silicon（M 系列）专用」。
- 清单 `arch` 字段保留并照常写 `arm64`，用途是**标注与提示**，不是构建分支；
  客户端将来若做架构过滤，判据就是这个字段（属下一轮，不在本轮）。
- 不做的代价写清楚：覆盖面少一批老机型；换来的是打包链路少一条分支、校验口径不变。
- 重新评估条件：只有当目标用户里 Intel 占比被证明不可忽略时才重开这条，且届时仍需走同一套 `release-verify` 校验。

---

## 8. 无签名的后果与应对

这是本方案最重要的一节：不做签名不是「少一道手续」，而是会改变用户的安装体验与权限模型。

### 8.1 首次打开会被 Gatekeeper 拦

未签名 + 未公证的包，从浏览器下载后会带 `com.apple.quarantine` 扩展属性，双击表现为：

- macOS 13–14：「无法打开“Brimio”，因为无法验证开发者。」
- macOS 15 及以后：「Apple 无法验证“Brimio”是否包含可能危害 Mac 的恶意软件。」

这不是「包坏了」，是被策略拦下。可行绕行（按推荐顺序）：

1. **右键（或按住 Control 点击）→ 打开 → 再点「打开」**。只需一次，之后正常。
2. **系统设置 → 隐私与安全性 → 底部「仍要打开」**（在尝试打开被拦后出现）。
3. **命令行清除隔离属性**（只作用于本 app，不关闭全系统防护）：

```bash
xattr -dr com.apple.quarantine /Applications/Brimio.app
```

   若 app 在 `/Applications` 且当前用户没有写权限，先复制到用户目录再处理，或由用户自行加 `sudo`
   （属于用户侧操作，本方案不代跑）。

明确**不要**做的事：`sudo spctl --master-disable`（关闭全局 Gatekeeper）、修改系统策略数据库。
代价远大于收益，且会让整机暴露。

### 8.2 更新后会不会再被拦

取决于「文件是怎么来的」，而不是「版本变没变」：

| 来源 | 是否带 quarantine | 更新后是否再弹 |
| --- | --- | --- |
| 浏览器下载 zip/dmg | 会 | **会**（每次从浏览器下都会） |
| 本方案的内建更新器（`curl` 拉取） | **不会**（`curl` 不写该属性） | 不会 |
| 解压已下载的 zip 后拖入 | 否（属性在 zip 上，`ditto -x -k` 不会传播到 app 内容） | 不会 |

自查命令：

```bash
xattr -p com.apple.quarantine /Applications/Brimio.app   # 有输出=会被拦；报「No such xattr」=不会
```

因此建议：首次安装可以把「右键打开」写进下载页；之后的自动更新走 `curl` 路径，不再打扰用户。

### 8.3 更新后系统授权会被重置

没有稳定代码身份（证书）时，TCC 记录的是二进制指纹；换一个 build，指纹就变了，
于是 **「自动化（Apple Events）」与麦克风等授权会在每次更新后重新询问**。
这是无签名方案的固有代价，本轮不做任何「保身份」手段（也不建钥匙串条目），
因此必须在更新说明里明确写「更新后需要重新授权一次」，避免用户以为是 bug。

### 8.4 镜像与源必须同哈希

用户无法用签名判断「这个包是不是官方给的」，只能靠哈希。因此：

- 清单里的 `sha256` 是唯一真值，镜像与 GitHub 源必须逐字节一致；
- 校验失败一律丢弃，不提供任何「仍然安装」入口；
- 客户端必须把「实际来源 + 实际哈希」打印出来（`fetch-update.sh` 已这样做），
  方便用户/支持人员对照；
- 公开模式下，用户还可以用 GitHub 服务端 `digest` 做第三方核对。

### 8.5 风险声明（必须让用户知道）

在「不签名 + 只靠 sha256」的前提下，**能防的是传输与镜像篡改，防不了发布端被攻破**：
如果清单托管账号被控制，攻击者可以同时替换包与哈希。现有缓解手段只有三条，且都不是密码学保证：

1. 发布账号只在你手上，开启双因素；
2. 清单地址固定、TLS 有效，且更新器拒绝明文 http；
3. GitHub 服务端对每个资产计算的 `digest` 可被第三方独立查询，形成弱交叉验证。

这一条写在这里，是为了不在文档里制造「有哈希就等于签名」的错觉。

---

## 9. 必须由你本人执行的步骤

| # | 事项 | 前置条件 | 为什么必须你 | 不做的后果 |
| --- | --- | --- | --- | --- |
| 1 | 处理 GitHub Actions 账单 | 账号 + 付费 | 涉及付款与账号 | CI 继续不可用；本方案已提供本机等价流程，不阻塞发布 |
| 2 | 决定仓库可见性，或新建公开分发仓（只放资产 + feed） | 账号 + 可见性决策 | 属于对外可见性变更 | 其他人无法自动更新；镜像全部 404 |
| 3 | 开通 Gitee 镜像仓（可选） | Gitee 账号 + 建仓 + 每版同步 | 需要账号与仓库所有权 | 少一条国内加速路径 |
| 4 | 开通对象存储 / CDN（可选） | 账号 + 计费 + 上传凭据 | 涉及付费与凭据 | 少一条最稳定的加速路径 |
| 5 | 首次安装时的 Gatekeeper 放行 | 本机管理员操作 | 属于系统安全策略 | 首次打不开（右键打开即可） |
| 6 | 每次更新后重新授予自动化/麦克风权限 | 本机操作 | 系统权限只能人工点 | 功能不可用（属预期，见 8.3） |
| 7 | 提交 `Release/feed/items.jsonl` 与打 tag | git 写操作 | 本轮明确不做 git 提交 | 下一轮发布无法判断历史版本 |

以下事项**不需要**做，也不要去做：申请证书、公证、建钥匙串条目、生成更新签名密钥、
关闭 Gatekeeper、用 `spctl --master-disable`。

---

## 10. 本轮落地物与实测记录

### 10.1 文件

| 文件 | 作用 |
| --- | --- |
| `Config/release.env` | feed 位置、通道可见性、检查节奏、下载超时 |
| `Config/mirrors.env` | 内置镜像顺序、模板、启用开关、是否仅公开 |
| `Scripts/version-check.sh` | 版本语法 + `--stage` / `--order-key` / `--compare`（比较口径唯一实现） |
| `Scripts/release-verify.sh` | 资产 sha256 / zip 结构 / 包内 plist / 架构校验 |
| `Scripts/release-feed.sh` | 发布台账 `--add`、按通道 `--emit`、`--list` |
| `Scripts/fetch-update.sh` | 取清单 → 选条目 → 逐镜像下载 → 校验（客户端参考实现） |
| `Scripts/update-sim.sh` | 离线端到端模拟（镜像切换 / 投毒包 / 通道隔离 / 防降级） |
| `Scripts/probe-mirrors.sh` | 镜像实测（我们的资产 + 公开样本双探针） |
| `Scripts/make-dmg.sh` | 首次安装用 dmg（含挂载回读校验） |
| `Scripts/release.sh` | 本机一条龙发布（替代 CI，默认只打印上传命令） |
| `Scripts/make-app.sh` | 追加 `BrimioReleaseTag` / `BrimioChannel` 两个 plist 键并回读校验 |
| `.github/workflows/release.yml` | 账单恢复后可直接接管；新增 feed 与 dmg |
| `.github/workflows/ci.yml` | 新增更新链路模拟步骤 |
| `Release/feed/items.jsonl` | 发布台账（已含 alpha1 真实记录） |

`Sources/`、`README.md`、`DESIGN.md` 未改动。

### 10.2 实测证据

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| 版本规则 | `Scripts/version-check.sh --self-test` | 27/27 通过（含 beta/RC/stage/order-key 用例） |
| 真实资产校验 | `Scripts/release-verify.sh v1.0.0-alpha1 <alpha1.zip>` | PASS，build=4、stage=alpha、arch=arm64、sha256 与 GitHub `digest` 一致 |
| 发布台账 / 通道隔离 | `Scripts/release-feed.sh --emit` | stable/beta 均 0 条（alpha 被正确排除）；`--include-alpha` 时 alpha 清单 1 条 |
| 端到端模拟 | `Scripts/update-sim.sh` | 12/12 通过；见下表 |
| 真实下载（私有模式） | `Scripts/fetch-update.sh --use-gh --current-build 3` | 经 `gh` 凭据成功取包并通过校验，落盘哈希与清单一致 |
| dmg 打包 | `Scripts/make-dmg.sh <fake>.app --tag v1.0.0` | 生成 32559 B，挂载回读版本/可执行位/`/Applications` 链接均通过 |
| 发布守卫 | `Scripts/release.sh --tag v1.0.0-alpha1 --skip-build` | 在工作区有未提交改动时正确拒绝（产物会包含 tag 之外代码） |
| 镜像实测 | `Scripts/probe-mirrors.sh` | 见 5.2 表格 |

`update-sim.sh` 明细：

| 场景 | 断言 | 结果 |
| --- | --- | --- |
| S1 | 镜像 1 返回 404 → 镜像 2 返回同体积投毒包（只翻一个字节）→ 镜像 3 正常 | 12 项全 PASS：识别 `hash_mismatch` 后切换成功，落盘哈希正确 |
| S2 | 所有镜像失效 | 退出码 4，目录为空（无半成品） |
| S3 | stable 清单里塞入 beta 条目 | 退出码 2（拒绝跨通道） |
| S4 | 清单 build 低于本机 | 退出码 2（不降级） |
| S5 | 非 loopback 的明文 http 清单 | 退出码 3（拒绝） |

---

## 11. 下一轮（不在本轮）

1. **Swift 侧接入**（需改 `Sources/`）：按本方案实现「取清单 → 比 build → 逐镜像下载 → sha256 → 提示」，
   以及 feed 里 `mirrors` 覆盖、软熔断计数。
2. **安装替换**：`ditto` 解到临时目录 → 校验 → 原子替换（`renamex_np(RENAME_SWAP)`）→ 失败回滚；
   需要处理「app 正在运行」「/Applications 无写权限」两种现实情况。
3. **多架构**：~~`lipo` 出 universal，或在清单里按 `arch` 过滤~~ → **决策 D4 已否决 universal**（见 §7.5）。
   只剩「清单按 `arch` 过滤 + 下载页标注」这一半，属客户端提示逻辑。
4. **Sparkle 迁移条件**：只有在「允许长期密钥 + 允许改 `Package.swift` + 分发端点公开」三条同时成立时才值得重估；
   当前均不成立，故不保留为可选项。
