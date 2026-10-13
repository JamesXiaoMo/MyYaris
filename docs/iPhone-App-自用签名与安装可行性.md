项目维护者，**不购买 Apple Developer Program，也能把自用 App 装到 iPhone；但免费原生 App 要持续续签，不能靠局域网自签证书永久安装。** 对 MyYaris，优先考虑免签名的 PWA；若地图分享菜单入口是硬需求，优先做一个独立的小型 SwiftUI 客户端，再验证免费续签路线。

# iPhone App 自用签名与安装可行性

查询日期：**2026-10-12（Asia/Tokyo）**。本文只做调研，不代表已在你的设备上完成安装或续签验证。

## 1. 结论与证据边界

| 问题 | 结论 | 证据等级 |
| --- | --- | --- |
| 免费 Apple Account 能否装自己的 App？ | 可以，Mac 上 Xcode 的 Personal Team 支持真机测试 | Apple 官方已证实 [A1] |
| 能否永久安装、离线自动签发？ | 免费 provisioning profile 从签发起 7 天过期；续签仍需 Apple 授权，局域网服务不能替代 Apple 签发 | Apple 官方已证实 [A1][A4] |
| 能否免费自动续签？ | AltStore Classic＋本地 AltServer、SideStore 均有后台刷新机制；当前 AltStore 还文档化了 Remote AltServers | 项目官方已证实机制，成功率未实测 [B1][B2][B5][C1] |
| 能否保证不失效？ | 不能承诺；iOS 决定后台任务何时运行，网络、登录、配对和工具版本也会造成失败 | Apple／项目官方依据 [A6][C3] |
| Linux R9000P 能否替代 Mac？ | 不能替代 Xcode 的 iOS 构建环境；能用官方安装指南支持的 iloader 初始化／恢复 SideStore，也可承载 Anisette 辅助服务 | 官方项目资料 [A5][C2][C5] |
| SideStore VPN 与 Tailscale？ | 有冲突风险，缺少针对你的 iOS／版本组合的共存保证；必须测刷新期间和刷新后的私网访问 | Tailscale 官方限制＋LocalDevVPN 实现；实际组合待测 [D1][D2][C6] |
| 最适合长期零费用自用？ | 手动粘贴发送需求优先 PWA；系统分享入口、Keychain 和 iOS 集成优先 SwiftUI，但接受续签维护 | 本文工程判断 |

不采用越狱、企业证书租用、未知商业签名或利用漏洞绕过免费名额的方案。付费计划仅用于对照，本次不购买、注册服务或申请证书。

## 2. 三种“证书／授权”必须分开

1. **开发代码签名证书**：把签名者的身份、公钥与 Apple 信任链连接起来；开发者使用对应私钥签 App。自己生成私钥或 CSR，不等于能自己签发被 iOS 接受的开发证书。
2. **Provisioning Profile（描述文件）**：由 Apple 签名，限定谁签、哪个 App、哪些设备、有效时间及哪些 entitlements。iPhone 验证它及 App 是否符合授权；续签通常是重新获得授权、重签并安装更新后的包，不只是更新服务器上的文件。[A4]
3. **HTTPS／TLS 证书**：用于验证后端主机和加密 HTTP 通信。现有 Tailscale Serve 的 HTTPS 服务与 iOS App 安装授权没有替代关系；Serve 可自动配置 tailnet 主机名的 TLS 证书，但不会给 IPA 签名。[D3]

因此，局域网自建 CA、HTTPS 下载页、Linux 定时任务或把 IPA 放在私网，都不能单独绕过正常 iOS 的安装／运行验证。**“安装路径在局域网”不等于“签发授权完全在局域网”。** 免费方案明确的 7 天期限属于 profile；不能把它误写成所有开发证书都只有 7 天寿命。[A1][A4]

## 3. Xcode Personal Team：免费真机签名的官方规则

### 3.1 期限、名额和安装

Apple 当前账号帮助明确列出：最多注册 **10 个 App IDs**，7 天过期；最多注册 **3 台设备**，7 天过期；每台设备最多安装 **3 个 App**；用于安装的 provisioning profiles 自签发起 **7 天过期**，过期后需重新构建并安装。Xcode 直接管理 Personal Team 的相关签名资源。[A1]

App ID 数不等于主屏图标数：Share Extension、Widget 等扩展会额外消耗 App IDs。AltStore／SideStore 自己也占一个免费 App 安装名额，因此通常只剩两个名额给其他 App。一个 MyYaris 主 App 加一个分享扩展，也须核对扩展的 App ID 预算。[B4][C1]

Mac 可通过支持该 iPhone 系统的 Xcode 登录用户自己的 Apple Account，选择 Personal Team 和自动管理签名，再部署真机。无线开发还依赖已有的设备配对与实际连接；不应把 Xcode 自动管理签名解释成自动每周为闲置手机续签。Apple 的 Xcode 系统要求表只提供 macOS 环境；Linux 不具备官方 Xcode iOS 构建路径。[A1][A5]

### 3.2 Capabilities：不是免费账号全部不可用

已核对 Apple 官方 iOS capabilities 表的 **Apple Developer（免费）列**，包括网页 HTML 中的勾选标记；文本抓取会丢失这些标记。与 MyYaris 有关的项目如下。[A2]

| 能力／需求 | 免费列或使用边界 | MyYaris 含义 |
| --- | --- | --- |
| App groups、Keychain sharing、Background modes、Data protection | 当前免费列均有勾选 | 可作为主 App／分享扩展设计候选；最终仍需 Xcode 与所选工具实测 provisioning 和 access group |
| Maps | 免费列支持；Apple 注明非会员可使用 MapKit，但不能提供 routing directions | 本版只发送目的地，不在 iPhone 内开发路线导航 |
| Push notifications、iCloud 各项、Associated domains、Sign in with Apple | 当前免费列无勾选 | 不把原生 APNs、iCloud 同步、Universal Links 或苹果登录作为免费首版依赖 |
| Network extensions、Personal VPN | 当前免费列无勾选 | MyYaris 使用已安装的 Tailscale 提供的网络，不自行开发 VPN；SideStore 借助另一个已分发的 VPN App |
| 普通 HTTPS 请求、文本输入、前台定位、单 App Keychain | 不要与需单独签发 entitlement 的高级服务混同 | 可作为最小客户端功能；定位需用户权限，网络仍受路由／隐私规则影响 |

**capability 有勾选不等于后台永驻，也不保证第三方重签工具完整保留该 entitlement。** 特别是 App Group 和 Keychain access group，工具重签可能调整标识，须测共享凭据与升级连续性；避免轮换工具／账号后仍假设数据可读。

### 3.3 Developer Mode 和信任

对 iOS 16 及之后的开发签名安装，应准备开启 Developer Mode：配对后在“设置 → 隐私与安全 → 开发者模式”开启，按提示重启并由用户确认。Apple 说明该模式针对 Xcode／开发 IPA 等场景；App Store 和 TestFlight 普通安装不受此要求影响。[A3][B3]

信任电脑、信任开发者、Developer Mode 是不同步骤。SideStore 指南对 iOS 15、16–17、18+ 给出不同信任流程，18+ 有 Allow & Restart 的步骤；具体以设备提示为准。[C7] 本次未进行任何配对、信任设置或模式修改。

## 4. 免费续签路线对照

| 路线 | 首次安装／构建 | 续签连接条件 | 电脑是否持续需要 | 失效与恢复 | 对 MyYaris 的评价 |
| --- | --- | --- | --- | --- | --- |
| Xcode Personal Team 手动 | Mac＋Xcode 构建并部署 | 重新 provision 时需 Apple 联网；USB 最直接，无线需配对可达 | 不必常开；需定期回到 Mac | profile 过期后重新构建部署；保持身份／Bundle ID 并验证数据 | 官方支持，容易理解，需每周维护 |
| AltStore Classic＋本地 AltServer | Mac／Windows 安装 AltStore；MyYaris IPA 仍由 Mac 构建 | 同一 Wi-Fi 可发现电脑，或 USB；Wi-Fi sync／信任；Apple 公网认证 | **续签时**必须运行且可达；后台自动刷新要求提供足够在线窗口 | AltStore 到期，用 AltServer 覆盖重装，不先删除；再刷新 MyYaris | 若常回家且 Mac 经常在线，是优先验证的免费原生路线 |
| SideStore | 当前官方指南：USB＋iloader，可用 Mac／Windows／Linux | Wi-Fi，不能仅蜂窝；LocalDevVPN；有效配对；Apple 与 Anisette 可达 | 日常正常续签不需电脑；初始化／恢复可能再次需要 | 重新生成配对或 iloader 覆盖重装，先尝试保留数据 | 不依赖 Mac 常开，但多了 VPN 与配对运维风险 |
| AltStore Classic Remote AltServers | 初始 PC 配对＋官方设置流程；IPA 构建仍用 Mac | 当前文档要求 Wi-Fi＋LocalDevVPN；远端服务可用 | 正常续签不需自己的电脑在线，仍依赖远端服务 | 重试／切换服务器；过期保留本地 AltServer 恢复路径 | 官方已文档化；服务运营、认证路径与隐私细节需进一步核对，不作为首选 |
| Apple Developer Program（仅对照） | Mac 构建；官方开发／Ad Hoc／TestFlight 分发路径 | 更长授权期仍受 profile、证书、会员与分发方式约束 | 非每周续签模式；更新仍需构建 | 到期重新签发／更新；TestFlight 每个 build 最多 90 天 | 官网 $99／年，地区结算可能不同；不等于永久安装 |
| PWA 加到主屏幕 | 私网 HTTPS 网站，无 IPA | 使用时 Tailscale、HTTPS、后端可达；无需 Apple App 签名认证 | 不需签名电脑；R9000P 后端仍需运行 | 无 7 天签名到期；网络／登录／网站故障按 Web 方式恢复 | 零续签运维，适合前台手动发送；分享入口能力须单独验证 |

表格依据：[A1][A7][A8][B1–B5][C1–C3][C7][E1]。**App 可以在有效期内无需每次重新签发，但续签成功不能依靠“只连局域网、禁止公网”。**

### 4.1 AltStore／AltServer 的实际机制

本地 AltServer 与手机进行设备通信，协助获得 Apple 授权、签名和安装。Mac 安装指南明确提到向 Apple 认证；官方称凭据只发往 Apple，此处是项目声明，不是本次抓包审计结果。[B3]

AltStore 可在后台尝试刷新，也提供 Siri／Shortcuts 自动化入口。Mac 上 AltServer 可以随登录启动并留在后台；电脑不必全天运行，但**必须在刷新窗口醒着、联网、可被手机发现**。电脑睡眠、家庭路由器客户端隔离、学校 Wi-Fi 或禁用发现，都可能让 Wi-Fi 刷新失败；USB 是恢复路径。[B1][B2][B6]

当前官网同时有 Remote AltServers：初始化配对后，Wi-Fi＋LocalDevVPN 可不连接自己的 AltServer 进行刷新。不能再笼统声称“所有 AltStore 续签一定要家里电脑常开”。该页未足够解释个人自托管 Linux 的支持范围、凭据处理和后台服务保证；这些不能从名字推断。[B5]

### 4.2 SideStore 的实际机制

SideStore 是设备端重签和安装客户端，使用个人开发证书；本地 VPN 提供与设备内部安装服务通信的路径，不是 Apple CA。正常使用可免日常电脑连接，仍需 Wi-Fi、LocalDevVPN 和有效配对。官方安装指南目前以 **iOS 15+** 为前提；仓库 README 仍有旧构建要求，不据此推断当前稳定版支持 iOS 14。[C1][C2][C7]

Anisette 是 Apple 认证／签名过程所需的辅助数据。可使用项目推荐的服务器，也可自托管 v3；官方说明不会向 Anisette 服务器发送账号信息，但这不表示不向 Apple 认证，亦不表示 SideStore 整体完全离线。LocalDevVPN 的“流量留在设备上”仅描述 VPN 本身。[C4][C5][C6]

SideStore 官方说明会周期性后台刷新，却未承诺成功率；Apple 明确后台 earliestBeginDate 不保证准点启动。[C1][A6] 可以研究每天或接电时触发刷新，但不把“创建自动化成功”当成“IPA 有效期已更新”。至少每两三天检查剩余天数，并在长途出行前手动刷新，属于本文维护建议。

### 4.3 自动化失败后的恢复

- **MyYaris 过期、管理器还有效**：先连接其要求的网络，手动 Refresh All，核对新的到期时间，再实际打开 MyYaris。
- **AltStore 自己过期**：官方要求通过 AltServer 重装 AltStore，明确不要先删除；随后刷新其管理的 App。[B2]
- **SideStore 无法打开或配对失效**：优先按官方排错，用 iloader 覆盖重装／替换 pairing file；系统更新、重置或随机失效可能要求再次连接电脑。[C3][C7]
- **登录、证书或 entitlement 失败**：先查看错误与所用账号／工具版本；不要盲目撤销同一账号的其他开发证书。若最终需删除重装，App 数据可能丢失；后端 SQLite 作为任务事实来源，客户端凭据可重新配置，避免将关键数据只放客户端。

官方 SideStore 某些排错分支包含删除 App；这应是后续用户决定的恢复操作，本次没有执行。定时任务不能在管理器已无法运行时自行保证恢复。

## 5. Mac 与 Linux R9000P 的分工

| 设备／角色 | 可行性与限制 |
| --- | --- |
| Mac：Xcode 构建／签名 | SwiftUI 和 Flutter iOS 都需要这里的 Xcode 工具链；先匹配 macOS、Xcode 的 Device Support 与 iPhone iOS。本文未检查本机安装版本。[A5][F1] |
| Mac：官方本地 AltServer | 官方提供 macOS 安装指南；当前下载要求与旧版分开。是否需要 Mail plug-in 按所用版本提示判断，不照抄旧教程强制安装。[B3] |
| R9000P：官方 SideStore 初始化／恢复 | 官方 prerequisites 支持最新 Linux，iloader 与 usbmuxd；通常需要 USB、设备信任和用户登录，不是无交互远程服务。[C2][C7] |
| R9000P：Anisette v3 辅助服务 | 官方推荐仓库有 Docker 运行方式，技术上适合 Linux；它提供辅助数据，不包办 iOS 构建／安装／后台调度。[C4][C5] |
| R9000P：常驻 AltServer-Linux | 存在社区项目，README 有 daemon 和 netmuxd Wi-Fi 支持；它不是 altstoreio 官方 AltServer Linux 发行版。涉及 Apple 认证、设备发现、配对、依赖兼容性，最新 iOS 成功率未验证。[B7] |

**判断：Linux 可以承载续签链路的一部分，也有社区完整服务实现，但不应承诺“R9000P 部署个服务就能完全替代 Mac，永久自动续签”。** 原生构建仍用 Mac；常驻 Linux 也不能强制 iOS 唤醒、连接 VPN、解锁或恢复已失效管理器。

若自托管 Anisette 只放在 Tailscale 私网，刷新时 LocalDevVPN 若使 Tailscale 断开，手机便可能访问不到它。这是需要验证的依赖循环，不能为了续签方便把现有后端直接公开。局域网直达辅助服务或其他访问方式须另行授权设计；本次不部署、不改路由。

## 6. SideStore／LocalDevVPN 与 Tailscale

### 官方资料实际证明了什么

- Tailscale 的“与其他 VPN 共用”文档给出 iOS 单活动 VPN 的一般限制；On Demand 文档进一步明确，连接其他 VPN 可能关闭 Tailscale 的 On Demand，需手动再次连接。[D1][D2]
- SideStore 当前要求 LocalDevVPN 在安装、更新和刷新时开启；旧 WireGuard／StosVPN 配置不能代表当前官方推荐路径。[C2][C3]
- LocalDevVPN 官方源码使用 `NEPacketTunnelProvider`，配置特定对端 IPv4 route 并排除默认路由。**只路由本机特定地址并不能证明能与另一个 VPN 同时激活**；路由不重叠和系统允许两个配置并行是不同问题。[C6]

本次未找到官方对“你的 Tailscale 版本＋LocalDevVPN 版本＋iOS 版本”做出的明确共存保证。因而结论是**存在有官方依据的冲突风险，具体表现待实测**；不断言一切情况下必定不能共存，也不保证可共存。

### 后续实验应记录的证据（本次未执行）

1. 记录 iOS、Tailscale、LocalDevVPN、SideStore 版本；Tailscale On Demand、Exit Node、DNS 与相关网络条件，只由用户提供非敏感配置概况。
2. 开始前确认 Tailscale HTTPS `/health` 可达；再手动启用 LocalDevVPN，观察两个客户端状态及私网请求是否仍成功。
3. 在 Wi-Fi 前台刷新，核对 SideStore 和 MyYaris 的新到期时间；再停止 LocalDevVPN、恢复 Tailscale，重新查 `/health`。
4. 对比锁屏／接电／后台与前台；刷新后回到蜂窝网络，通过 Tailscale 提交一个明确坐标任务。
5. 如果需要切换 VPN，验证“刷新 → 停止本地 VPN → 恢复 Tailscale → 私网访问”的完整恢复流程；不能只看 VPN 图标或快捷指令成功通知。

日常控制依赖 Tailscale，续签工具不应默认常驻抢占其连接。若不能可靠恢复，先选择本地 AltServer 或 PWA。

## 7. MyYaris 最小客户端技术选择

### 7.1 已核对的项目信息

本地 `docs/后端需求文档_V1.md` 记录 Flutter 车机、Linux R9000P FastAPI＋SQLite、Tailscale 私网的分工；其中早期“首版只做快捷指令”是历史方案，本报告评估新的客户端选项。Tailscale Serve HTTPS 的当前部署来自用户提供的上下文，本次没有远程验证。

本地 `backend/app/schemas/destination.py` 确认输入有 `auto`、`coords`、`plus_code`、`share_link`，以及 `text`、`url`、候选确认、`idempotency_key` 等字段。可设计一个文本框接受坐标／Plus Code／地图链接，调用现有目的地接口、确认歧义、展示任务回执。正式开发时仍要核对服务端路由和解析行为，不以 schema 单独证明所有地图链接已支持。

本地没有 `ios/` 目录；`lib/services/music_service.dart` 与导航轮询使用 MethodChannel，存在 Android MediaSession／Intent 语义。这些车机能力不能通过添加 iOS 目录自动移植到手机。未读取凭据、环境变量文件或当前快捷指令中的鉴权内容。

| 维度 | 独立 SwiftUI | Flutter iOS 客户端 | PWA |
| --- | --- | --- | --- |
| 简单输入／提交／结果 | 少量原生页面＋URLSession；本文推荐原生路线 | Dart 开发熟悉，但须建 iOS target 和依赖 | 最低构建／签名成本；同源 Web 表单即可 |
| 地图分享菜单接收 | Share Extension，原生实现清晰；额外 App ID 和共享凭据实测 | 通常需插件与原生扩展，仍须理解 iOS 生命周期 | 不承诺 Web Share Target 在目标 Safari 中可用；首版采用复制／粘贴，Web Share 向外分享不能证明能接收 |
| 与车机代码复用 | 主要复用 API 契约，手机界面独立 | 可抽出模型与请求代码；车机 Intent／音乐实现不可原样复用 | 复用后端接口，不复用 Flutter Android 系统代码 |
| 凭据 | Keychain 直接使用；扩展用经验证的 access group | 采用实际使用 iOS Keychain 的受维护插件，验证升级 | JS 不能直接使用 App Keychain；避免把长期 bearer token 放 localStorage |
| 后台可靠性 | iOS 调度限制；前台发送最可靠 | 与 SwiftUI 相同，不因 Dart 绕过限制 | 不承诺后台常驻／精确定时同步／长轮询 |
| 更新与安装维护 | 免费 7 天续签＋Mac 构建 | 同样免费 7 天续签＋Mac 构建 | 无 IPA 续签，Web 更新仍需部署和缓存管理 |
| 单人小型工程成本 | iOS 集成成本较低，增加 Swift 学习 | 若做共享新手机 UI 可选；直接复用车机工程改造成本较高 | 最低，代价是系统集成较弱 |

这些成本和选型是基于当前范围的工程判断，不是已完成原型的测量结果。Flutter 官方明确 iOS 开发依赖 Xcode／macOS；换 UI 框架不会改变签名规则。[F1]

### 7.2 凭据、私网与后台边界

- **原生凭据**：只存手机的最小权限 API 凭据到 Keychain，不嵌入 IPA、源码、日志或 URL。前台为主可选解锁时可访问、仅本设备的保护级别；若未来扩展／后台需访问，再明确评估保护级别。Apple Account 的签名认证由用户在其选定工具内自行完成，不进入 MyYaris 后端，也不交给 ChatGPT。[A9]
- **PWA 凭据**：建议后续设计服务端会话＋Secure／HttpOnly／SameSite cookie，并考虑 CSRF；这是未来实现建议，不声称现有后端已支持。若暂沿用 bearer，可先每次输入或短期内存持有，不能把浏览器存储等同 Keychain。服务工作线程只缓存静态壳，不缓存凭据或敏感 API 响应。
- **网络**：沿用 Tailscale Serve 的完整 HTTPS 主机名，验证 DNS、有效 TLS、tailnet ACL 和应用鉴权。原生 URLSession／Web fetch 都经系统网络路由，不需为普通请求取得自建 VPN entitlement。Tailscale 未连接、R9000P 睡眠或 ACL 阻断应显示失败，不伪造发送成功。[D3]
- **Web 跨域**：若未来 PWA 与 API 同源，可减少 CORS／cookie 配置成本；跨源方案要核对 CORS、凭据与浏览器策略。添加页面或代理路径会是后续部署变更，本次没有操作。
- **权限**：前台定位仅在用户主动请求当前位置时申请；权限拒绝时仍允许手动输入。局域网直接访问／发现要按 Apple local network privacy 规则配置；不能仅因使用 HTTPS 就推断无需本地网络权限，Tailscale 地址的实际行为要按目标 iOS 实测。[A10]
- **后台**：首版发送放前台，切后台持久化请求 ID 与未完成状态；回来查询，不后台盲目重复派发。iOS 的 BGTask 调度不能用来保证每隔 N 秒控制车机；PWA 的 Web Push 也不是静默常驻执行许可。[A6][E2] 不使用虚假音频／定位维持任务。
- **回执**：手机发送成功最多表示服务端接收或排队；`received` 与 `launch_requested` 分开显示，后者不等于正在导航。历史记忆提示曾存在 NAVITIME 前台第二次目的地未响应问题，该记录可能过时，本次未重新验证；不能因换手机客户端而宣布已解决。

### 7.3 未来音乐控制要先定义目标

若目标是**遥控 Android 车机音乐**，手机只发送命令到 FastAPI，车机执行已有 Android 能力并回报状态；SwiftUI、Flutter iOS、PWA 都可充当请求界面。当前本地资料不能证明后端已具备手机远程音乐命令链路，未来需设计鉴权、幂等、过期和执行回执。

若目标是**控制 iPhone 上其他音乐 App**，不能把车机的 Notification Access／MediaSession 方法直接移植；必须针对目标播放器的公开 URL scheme、API 或 Apple framework 另查权限和支持范围。首版不依赖 MusicKit、未验证的自动播放参数或跨 App 全局控制。

## 8. 推荐步骤与必须补充的信息

### 推荐顺序（方案建议，未执行）

1. **确定交互优先级**：若能接受复制地图链接、打开主屏图标粘贴，选 PWA，消除每周续签；若必须从 Google Maps／Apple Maps 分享菜单直接发送，选 SwiftUI＋Share Extension。
2. **收集版本信息**：iPhone 型号与精确 iOS、Mac 的 macOS／Xcode、Apple Account 国家／地区、是否普通个人账号、已有免费开发 App 数、是否愿意自行开启 Developer Mode。只需这些信息，不需要密码、验证码、token 或 pairing file。
3. **原生路线先验证生命周期**：后续经用户授权，用 Mac Xcode Personal Team 完成一次最小安装，再检查 profile 有效期、Keychain、私网 HTTPS 请求和实际任务回执；先不扩展成大型 Flutter 手机项目。
4. **选择一种续签工具**：常回家且 Mac 可在线，先测本地 AltServer；希望免日常电脑，测 SideStore Stable／LocalDevVPN。Remote AltServers 是当前官方备选，但先核对服务与认证信息；不同时堆叠多个工具争用证书。
5. **至少覆盖两个 7 天周期**：核对有效期真实更新、管理器自身刷新、锁屏／低电量／断网恢复、Tailscale 恢复；安排一次“接近到期但仍有效”的手动补救。连续成功仍只是样本，不是永不失效保证。
6. **验收 MyYaris 功能**：明确坐标、完整 Plus Code、带地名短 Plus Code、地图 URL、歧义确认、网络中断／重复点击；车机 NAVITIME 已前台时连续发送两个不同目的地，核对任务 ID／回执与界面变化。

### 缺失信息对应的分支

| 缺失条件 | 如何继续判断 |
| --- | --- |
| iOS 版本 | iOS 15 的 SideStore 指南不含 16+ Developer Mode 路径；16+ 应准备该模式；新系统／beta 需要核对 Stable release 兼容性，不能按“18+”标签保证所有未来版本 |
| Apple Account 地区 | Personal Team 文档未把免费测试限定在某个市场；LocalDevVPN App Store 可用性需对应 storefront 核对。AltStore PAL 的市场资格不能替代 Classic 开发签名，不把 PAL 当作任意自用 IPA 免签通道 |
| macOS／Xcode 版本 | 根据 Apple Device Support 表选兼容版本；有 Mac 不等于当前已具备可用工具链，不默认升级系统 |
| Tailscale On Demand／Exit Node／版本 | 决定 VPN 切换风险和恢复实验；没有配置不能承诺双 VPN 共存 |
| “坐标”含义 | 手动目标坐标与自动采集手机当前位置分开；首版前者无需持续定位，后者只做前台按需采集 |

## 9. 已证实与待实测清单

**已证实**：Apple 免费期限／数量规则；当前 capabilities 表；Developer Mode 要求；AltStore 本地与 Remote AltServers 官方机制；SideStore 当前 Wi-Fi、LocalDevVPN、Linux 初始化支持；Anisette 可自托管但不替代 Apple；Apple 后台不保证准点；PWA 主屏安装无 IPA 签名流程。

**待实测／待补充**：你的 iOS／账号地区／工具链兼容性；SideStore 与 Tailscale 的实际切换或共存表现；免费后台续签成功率；远端 AltServer 服务和认证细节；Share Extension 重签后的 App Group／Keychain；PWA 接收分享支持；目标地图链接覆盖；远程音乐控制；当前 NAVITIME 前台连续目的地回归。

本次只新增本文档，没有改现有代码／部署，没有读取 token 或 env，没有登录或改变设备账号，没有申请／撤销证书，没有购买服务。

## 10. 官方来源与查询日期

以下链接均于 **2026-10-12** 查询；Apple／项目文档可能继续更新。GitHub 社区实现是该项目的一手资料，已明确与 Apple／altstoreio 官方支持区分。动态文档正文无法被网页工具提取时，使用同一官方站点 Markdown／HTML 核对。

| 编号 | 来源及精确链接 | 支持的内容 |
| --- | --- | --- |
| A1 | [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) | Personal Team、10 App IDs／3 设备／每设备 3 App、7 天 profile |
| A2 | [Apple Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) | 免费列逐项权限；已核对 HTML 勾选 |
| A3 | [Apple Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) | 模式、配对、重启确认、App Store／TestFlight 边界 |
| A4 | [Apple TN3125: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)；[Apple Platform Security: App code signing](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web) | Apple 授权、profile 验证、代码签名信任链 |
| A5 | [Apple Xcode system requirements](https://developer.apple.com/xcode/system-requirements) | macOS、Device Support 和 SDK 对照 |
| A6 | [Apple earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)；[Choosing Background Strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) | 系统决定后台运行时间，不保证准点 |
| A7 | [Apple Developer Program](https://developer.apple.com/programs/) | $99 年费及分发能力，仅对照 |
| A8 | [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) | 每个 build 最多 90 天 |
| A9 | [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services) | 加密保存小型秘密数据 |
| A10 | [Apple TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | 本地网络连接与权限边界 |
| B1 | [AltStore Getting Started](https://faq.altstore.io/altstore-classic/your-altstore) | 后台刷新／Siri 与 Personal Automations |
| B2 | [AltStore AltServer](https://faq.altstore.io/altstore-classic/altserver) | 同 Wi-Fi／USB、后台运行、过期覆盖重装 |
| B3 | [AltStore macOS installation](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) | macOS、Wi-Fi sync、Apple 认证、Developer Mode |
| B4 | [AltStore App IDs](https://faq.altstore.io/altstore-classic/app-ids) | 扩展占额、10 App IDs、7 天 |
| B5 | [AltStore Remote AltServers](https://faq.altstore.io/altstore-classic/remote-altservers) | 远端刷新、初始配对、Wi-Fi＋LocalDevVPN、服务故障 |
| B6 | [AltStore Troubleshooting Guide](https://faq.altstore.io/altstore-classic/troubleshooting-guide) | 本地发现／信任／网络隔离问题与 USB 补救 |
| B7 | [NyaMisty/AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) | **社区项目** daemon、netmuxd、Anisette；非官方 Linux 支持保证 |
| C1 | [SideStore FAQ](https://docs.sidestore.io/docs/faq) | 设备端重签、后台尝试、安装名额、付费 365 天的项目说明 |
| C2 | [SideStore Prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) | iOS 15+、Linux／iloader／usbmuxd、Wi-Fi、LocalDevVPN |
| C3 | [SideStore Common Issues](https://docs.sidestore.io/docs/troubleshooting/common-issues) | 配对与网络排错、无法打开及重装 |
| C4 | [SideStore Custom Anisette Server](https://docs.sidestore.io/docs/advanced/anisette)；[official server recommendations](https://github.com/SideStore/anisette-servers) | v3、辅助数据与账号信息边界 |
| C5 | [SideStore/omnisette-server](https://github.com/SideStore/omnisette-server) | 官方推荐辅助服务的 Docker 部署方式 |
| C6 | [LocalDevVPN repository](https://github.com/jkcoxson/LocalDevVPN)；[PacketTunnelProvider.swift](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift)；[App Store](https://apps.apple.com/app/localdevvpn/id6755608044) | 本地隧道与实现；不等于签名过程离线 |
| C7 | [SideStore Install](https://docs.sidestore.io/docs/installation/install) | 初次安装、iOS 分支、信任、配对失效 |
| D1 | [Tailscale alongside other VPNs](https://tailscale.com/docs/reference/faq/other-vpns) | iOS VPN 一般限制与冲突风险 |
| D2 | [Tailscale VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand) | 其他 VPN 对 On Demand 的影响 |
| D3 | [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)；[Serve CLI](https://tailscale.com/docs/reference/tailscale-cli/serve) | tailnet 私网入口及自动 HTTPS TLS 证书 |
| E1 | [Apple Safari: Turn a website into an app](https://support.apple.com/guide/iphone/iphea86e5236/ios)；[WebKit Safari 26.0 features](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/) | 添加主屏 Web App |
| E2 | [WebKit iOS Web Push](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)；[Meet Web Push](https://webkit.org/blog/12945/meet-web-push/) | iOS 16.4+ 主屏推送无需 ADP；推送不是静默后台常驻许可 |
| F1 | [Flutter Set up iOS development](https://docs.flutter.dev/platform-integration/ios/setup) | iOS 的 Xcode／macOS 工具链 |
