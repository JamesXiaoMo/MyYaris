项目维护者，**可以把 SideStore 所需的 Anisette 辅助服务放在 Ubuntu R9000P 上；Apple 负责开发授权与 profile，SideStore 在 iPhone 上重签和安装。** 这能减少日常对 Mac 的依赖，但不能把 Ubuntu 变成 Apple CA，也不能保证 Ubuntu cron 远程完成手机的每一次续签。

# SideStore＋Ubuntu 自动续签工作流

查询日期：**2026-10-12，日本时间**。这是在前份[自用签名与安装调研](iPhone-App-自用签名与安装可行性.md)基础上重新联网核对的工作流设计，未部署、未登录、未签发证书、未验证你的手机。

## 1. 可直接打开的流程图

- 中文流程图 PNG（文件保留于本机，不随源码发布），1800 × 3290 像素。
- [矢量流程图 SVG](assets/SideStore-Ubuntu自动续签工作流.svg)，可在浏览器放大。

（SideStore＋Ubuntu R9000P 自动续签泳道图：验证图保留于本机，不随源码发布）

按上到下阅读：**首次准备 → 到期前续签 → 失败／到期恢复**。四条泳道分别表示 Ubuntu、iPhone、Apple 和 Mac。橙色是 Ubuntu 辅助操作，蓝色是手机执行，绿色是 Apple 授权，紫色是 Mac 构建，黄色是条件／待实测项。图中步骤是逻辑顺序，不是对工具内部请求次数或协议时序的精确描述。

## 2. “自动颁发证书服务放 Ubuntu”如何准确落地

你的目标可以拆成两个层次：

| 层次 | 真正执行者 | Ubuntu 的作用 |
| --- | --- | --- |
| 创建／管理开发证书、取得安装授权 profile | Apple 服务提供授权；iloader／SideStore 代表用户请求 | 可运行首次安装工具；不能自己签发被 iOS 接受的 profile |
| 提供 Anisette 认证辅助数据 | 可自托管的 Anisette v3 服务 | R9000P 可以承载，官方推荐项目有 Docker 运行方式 |
| 每周期限内重签与安装 | iPhone 上的 SideStore | Ubuntu 只提供可达的辅助服务，不负责唤醒手机或运行 SideStore |
| 构建 MyYaris iOS 包 | Mac 的 Xcode 工具链 | Linux 不能替代官方 iOS 构建环境 |

SideStore 官方支持自定义 Anisette 服务，并推荐 v3。Anisette 是签名／认证过程使用的辅助数据，**不是开发证书、私钥、provisioning profile 或签名 CA**。项目说明 Anisette 服务器不接收账号信息；这是项目声明，本次没有进行网络审计。即使数据由自己电脑提供，Apple 认证／授权仍需公网服务。[SideStore 自托管说明](https://docs.sidestore.io/docs/advanced/anisette)、[官方推荐服务列表](https://github.com/SideStore/anisette-servers)、[omnisette-server](https://github.com/SideStore/omnisette-server)

Apple 的 profile 将签名者、App、设备、有效时间与 entitlements 绑定，并由 Apple 签名。免费 Personal Team 的 profile 从签发起 7 天过期；不是所有开发证书都只有 7 天，也不是每次刷新都必须换一张证书。正常刷新可使用仍有效的开发证书取得新授权，证书失效或不匹配时再由工具处理。最终行为必须以实际签名资源和工具提示为准。[Apple Personal Team 规则](https://developer.apple.com/help/account/basics/about-your-developer-account)、[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

现有 Tailscale Serve 的 HTTPS 证书只负责后端连接身份与 TLS；把它更新、换成自签证书或自建 CA，都不能续签 iOS App。上述三个角色必须分开。

## 3. 图中首次准备：哪些可以用 Ubuntu

1. **Mac 构建**：为 SwiftUI／Flutter iOS 客户端生成可供工具安装的 IPA；先核对 iOS／Xcode／macOS 兼容性和打包路径。不假设免费 Xcode 存在与付费 Ad Hoc 相同的导出流程；具体交付 IPA 的构建办法留待开发阶段验证。[Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)、[Flutter iOS 设置](https://docs.flutter.dev/platform-integration/ios/setup)
2. **Ubuntu 首次初始化**：SideStore 当前指南支持 Linux，使用 iloader 与 usbmuxd，USB 连接手机；用户在工具里自行完成 Apple Account 登录和设备信任。官方 iloader 项目说明可安装 SideStore、导入 IPA，并自动放置相应 pairing 文件。[SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)、[iloader 官方仓库](https://github.com/nab138/iloader)
3. **手机权限与首刷**：依 iOS 版本信任开发者、必要时开启 Developer Mode；安装 LocalDevVPN，连接 Wi-Fi，在 SideStore 首次登录后刷新自身，再导入 MyYaris。iOS 16+ 的开发安装要准备 Developer Mode；开关、重启、设备密码确认只能由用户完成。[SideStore 安装指南](https://docs.sidestore.io/docs/installation/install)、[Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
4. **选择辅助服务**：可以使用项目提供的服务或规划自托管 v3。图选择 Ubuntu 自托管，是目标方案，不表示已经开通。后续配置服务器列表与 HTTPS 地址时才需要确定版本、网络入口和访问权限。

配对文件授权工具与设备内部服务通信，不等于 Apple 签名授权。两者都需要有效。不要把 pairing 文件内容放进文档、聊天或公共仓库；本次没有读取其内容。

免费每台设备最多 3 个 App，SideStore 包含在内；主 App 与分享扩展还会占用 App ID 预算。首版 MyYaris 应先控制 target 数，再验证分享扩展、App Group、Keychain 在重签后的行为。

## 4. 图中日常续签：手机才是执行主体

**正常链路：手机获得执行机会 → 网络／配对满足条件 → 获取 Anisette → 请求 Apple 授权 → 重签／安装 → 核对新到期日 → 恢复 Tailscale。**

SideStore 官方描述它会周期性在后台刷新；当前要求 Wi-Fi，不能仅靠蜂窝网络，并在安装／更新／刷新时开启 LocalDevVPN。Ubuntu 可保持 Anisette 在线，但无须每次把整个 IPA 重新从 Mac 构建；同一版本通常由手机刷新。更新代码时才重新构建并导入新 IPA。[SideStore FAQ](https://docs.sidestore.io/docs/faq)、[当前网络要求](https://docs.sidestore.io/docs/installation/prerequisites)

可以研究后台刷新或手机快捷指令的接电／定时触发，但不能把这些画成“准点必达”。Apple 明确后台任务的 earliestBeginDate 只是最早开始时间，不保证在指定时刻运行。锁屏、低电量、后台设置、用户强制退出、网络／登录变化等条件需要纳入实测，不把列出这些条件当作逐项已经验证的 SideStore 行为。[Apple 后台时间边界](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)

本报告建议每两三天检查一次期限、出行前前台刷新；这是维护建议。验收至少同时检查：SideStore 自身新到期日、MyYaris 新到期日、App 可启动、私网 API 可访问。单独的“自动化成功通知”、服务器请求日志或 Anisette 服务健康都不能证明安装已续期。

## 5. 自托管 Anisette 与 Tailscale 的潜在依赖循环

如果辅助服务只通过 Tailscale 私网访问，存在这样的条件分支：

> 启用 LocalDevVPN → Tailscale 连接受影响 → 手机访问不到 R9000P 的私网 Anisette → 无法完成刷新。

这是**待实测的推论**。Tailscale 官方给出 iOS 多 VPN 的一般限制，并明确其他 VPN 会影响 Tailscale On Demand；LocalDevVPN 的具体实现、手机系统与两款 App 版本还需要核对，不能断言你的组合必定不可共存，也不能保证共存。[Tailscale 与其他 VPN](https://tailscale.com/docs/reference/faq/other-vpns)、[Tailscale On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)、[LocalDevVPN 官方项目](https://github.com/jkcoxson/LocalDevVPN)

| 后续可验证的网络选择 | 判断 |
| --- | --- |
| 仅 Tailscale 私网提供 Anisette | 符合私网目标，但须证明 LocalDevVPN 开启时仍能请求；未通过前不作为可用方案 |
| 家中同一局域网直达 Ubuntu 辅助服务 | 可以作为实验候选，需独立验证 HTTPS、地址解析与权限；离开家后不可据此保证可用 |
| 使用项目推荐的公共 Anisette 服务 | 可避免依赖自家私网入口，但不满足完全自托管偏好，也仍依赖外部服务可用性 |
| 公开现有 FastAPI 后端以解决访问问题 | 不采用；不因续签需求改变 MyYaris 私网部署 |

后续测试应先读 `/health`，再开启 LocalDevVPN、请求 Anisette并刷新；完成后必要时停止 LocalDevVPN、重新连接 Tailscale，再检查 `/health` 和 App 正常请求。图中的“恢复 Tailscale”是**显式验证步骤**，不是声称当前工具会自动恢复。

## 6. 为什么 Ubuntu cron 不能包办 SideStore

cron／systemd timer 可以在 Ubuntu 上启动服务、检查辅助服务健康或执行服务端任务。它们不能直接保证 iPhone 解锁、信任电脑、授权 Developer Mode、运行 SideStore、启用所需 VPN，或在 iOS 的后台窗口内完成重签与安装。

因此，“Anisette 每天自动运行”与“iPhone 每天自动续签成功”不是同一验收目标。SideStore 不提供把手机后台调度交给 Ubuntu 的保证；管理器自身过期后，Ubuntu 上服务继续运行也不能使手机自动恢复。

### 更贴近常驻服务器目标的社区路线

**AltServer-Linux＋netmuxd＋iPhone AltStore** 是另一个架构，而不是“给 SideStore 加一个 Ubuntu 后台”。AltServer-Linux 的 README 有 daemon 模式和 Wi-Fi refresh 的 netmuxd 配合说明；netmuxd 是支持网络设备的 usbmuxd 实现。因此，从职责上，Ubuntu 可以参与签名、设备通信和安装，比只运行 Anisette 更贴近你的常驻服务目标。[AltServer-Linux 项目](https://github.com/NyaMisty/AltServer-Linux)、[netmuxd 项目](https://github.com/jkcoxson/netmuxd)

| 项目 | SideStore＋Ubuntu Anisette | AltServer-Linux＋netmuxd |
| --- | --- | --- |
| Ubuntu 日常职责 | 返回认证辅助数据 | 承载 AltServer 服务与设备通信 |
| 日常安装执行方式 | 手机 SideStore 重签、调用设备安装服务 | Linux 服务协助签名／安装，手机 AltStore 可发起刷新 |
| LocalDevVPN | 当前 SideStore 流程需要 | 该本地 AltServer 路线不是同一套 LocalDevVPN 流程；实际网络可达性仍要验证 |
| 自家电脑是否需在线 | 辅助服务被选用时需要可达 | 续签时服务器必须运行、联网且找到设备 |
| Apple 公网认证 | 需要 | 需要；自托管也不能替代 Apple |
| 当前支持证据 | SideStore 官方 Linux 初始化指南及自托管辅助服务说明 | 社区项目 README，非 Apple／altstoreio 官方 Linux 支持 |
| cron 能否保证全部完成 | 不能 | 也不能保证；设备不在线、配对／登录失效、兼容性失败会阻断 |

**判断：社区路线在职责上更贴近要求，但目前只能列为验证候选，不应优先部署成车机控制依赖。** 需要实测你的 iOS、AltStore、AltServer-Linux 和 netmuxd 版本、Wi-Fi 发现／配对、两次以上期限更新与到期恢复。Tailscale IP 可达不等于 Bonjour／网络设备发现已可用，不能假设远端手机经 Tailscale 就会被 netmuxd 找到。

其 README 出现凭据命令行参数、替换 usbmuxd 等操作；后续若测试需先设计安全凭据处理与回滚方案，本次不照抄执行、不提供真实密码参数、不停现有服务。服务能启动也不是续签成功的证据。

## 7. 失败／到期恢复

- **MyYaris 到期但 SideStore 仍能打开**：前台手动刷新，满足 Wi-Fi、LocalDevVPN、配对及 Apple／Anisette 可达条件，然后回到图中核对到期日和 Tailscale。
- **SideStore 自身打不开／到期**：可能需要回到 Ubuntu 用 USB＋iloader 重装，先尝试保留数据，再重新首刷和安装。不能指望手机上已无法运行的管理器自救。
- **配对文件失效**：官方说明系统更新、重置或其他情况可能造成失效；用 iloader 重建／替换并测试。不读取旧文件内容来制作流程图。
- **签名身份／证书错误**：用户在工具中核对实际提示，不盲目撤销其他有效证书。工具可能要求重新登录或创建／替换证书，但这不是每周必然操作。
- **仍需删除重装**：官方某些排错分支会要求删除 App，可能丢失本地数据；这是后续由用户决定的恢复操作，不自动执行。

恢复依据：[SideStore Common Issues](https://docs.sidestore.io/docs/troubleshooting/common-issues)、[SideStore Install](https://docs.sidestore.io/docs/installation/install)。

## 8. 下一步与交付边界

建议先补充非敏感信息：iPhone 精确 iOS、账号 storefront 地区、Tailscale／LocalDevVPN／SideStore 版本、Mac 的 macOS／Xcode，以及 R9000P 是否能与手机同 Wi-Fi 或 USB 连接。不需要 Apple Account 密码、验证码、token、私钥或配对文件内容。

之后若你授权实验：先证明**单次前台刷新＋Tailscale 恢复**，再验证后台／自动化与至少两个 7 天周期；若你坚持服务器主导，再独立验证社区 AltServer-Linux。当前没有证据支持把任一路线承诺为永久、完全离线、无人值守签名服务。

本次新增中文 PNG、SVG 和本文档。PNG 使用标准 SVG 图形经独立无账号的本地 Chrome 渲染，已实际打开检查中文、箭头与布局；没有安装运行环境、开发 App、部署服务、改变账号／VPN／设备设置或申请证书。

## 9. 来源核对说明

本文所有网页来源重新查询于 **2026-10-12**。Apple 和 SideStore 官方文档证明免费授权、安装条件与辅助服务角色；AltServer-Linux／netmuxd 的仓库是各社区项目的一手资料，不代表 Apple 或 altstoreio 对当前 iOS 的兼容性保证。

图中实线表示逻辑执行／数据流，黄色说明条件或待实测项。设备端刷新成功率、LocalDevVPN 与 Tailscale 共存、私网 Anisette 可达性和社区服务端安装均未在用户设备上验证。图和本文未依赖历史部署成功记录作当前兼容性结论。
