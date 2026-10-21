# xbot for iOS

Swift 6 + SwiftUI 原生 iPhone / iPad 客户端，支持 iOS 17+。按 [xbot-android](https://github.com/ai-pivot/xbot-android/tree/761ec91893cedf94329c1e9de87d0743942c0692) 的功能及 REST / RPC / SSE 协议实现。

## 运行

用 Xcode 打开 `Xbot.xcodeproj`，选择 **Xbot** Scheme 和模拟器运行。真机需选择自己的 Apple 开发团队和 xbot App ID。输入服务器地址及账号密码连接；也可在登录页进入离线界面预览。

Swift 部分无外部包依赖；Mermaid 使用随 App 打包的 MIT 许可离线资源。新增 Swift 文件后运行 `python3 scripts/generate_project.py` 重新生成工程。

## 已实现

- 服务器检测、首个管理员注册、Cookie 登录恢复、钥匙串保存、401 自动重新登录。
- 会话树、搜索、运行 / 错误状态、最近活动时间、轮询、创建、重命名、删除、分支。
- 历史分页、轮次与迭代、流式文本及思考、工具参数 / 摘要 / 详细输出 / 耗时。
- SSE 字节解析、心跳超时重连、指数退避、Last-Event-ID、路由过滤、去重和重同步。
- 消息发送、忙时排队、取消、历史回退与草稿恢复、首尾跳转。
- 文件 / 照片上传及附件消息；Markdown 表格、链接、代码复制、认证图片加载与全屏缩放。
- 离线 Mermaid 图表、源码复制、全屏查看；浅色、深色与跟随系统。
- AskUser 单选、多选、自由回答、稍后、取消；兼容新旧事件格式。
- 会话 / 默认模型、订阅 / 模型 / 工具开关、思考、上下文、Token 上限、并发、压缩阈值。
- 当前会话的后台本地提醒及系统后台刷新；可配置 APNs 桥接用于长期通知。
- iOS 专用更新清单、自动 / 手动检查、更新说明及 TestFlight / App Store 跳转。
- 应用内隐私说明、按服务器和账号隔离的 AI 分享确认／撤回、接收方变化后重新确认。
- 自托管订阅与工具配置说明、本机会话屏蔽、内容举报及导出、可选服务端删除申请与回执。

完整对应关系和平台差异见 [功能对齐清单](docs/PARITY.md)，实测范围见 [验证记录](docs/VALIDATION.md)。界面：[浅色](docs/screenshots/chat-light.png) · [深色](docs/screenshots/chat-dark.png) · [表格与图表](docs/screenshots/chat-rich.png)。

## 连接与媒体

支持 HTTPS、局域网 HTTP 和反向代理子路径。模拟器可访问开发机 `127.0.0.1`；真机需使用服务器实际 IP 或域名。登录请求不跟随重定向，请填写最终地址。公网使用 HTTPS。

这是通用自托管客户端，不要求统一服务器运营主体或固定 AI 服务商。公网裸域名默认 HTTPS；明文 HTTP 仅允许明确的本机、私有／链路本地 IP 和 `.local` 地址。全局 ATS 例外已移除，外部图片重定向也遵循相同限制。

首次登录需确认应用隐私说明；旧版本保存的登录信息也需先完成此确认。发送消息、回答或上传附件前，会读取服务器的模型订阅、服务地址及已启用工具，并请求明确同意。可补充实际 AI／代理／工具接收方，或声明仅使用本地模型；不会把 OpenAI 兼容协议误认成 OpenAI 服务商。变更服务地址（包括代理路径）、订阅或工具配置后需重新确认，拒绝时保留草稿，不自动发送。取消任务、查看历史、账号管理不依赖 AI 分享同意。

[隐私说明](docs/PRIVACY.md) 已在登录页和设置内提供，对外链接指向本仓库公开文档。[提审准备说明](docs/APP_STORE.md) 区分客户端修复、自托管服务责任和商店配置。

同源图片带 xbot 登录凭据请求，外部对象存储不附带 xbot Cookie。消息中绝对 `localhost` 图片链接需要在「设置 → 媒体 / 对象存储地址」填写实际对象存储域名；留空时不请求这些本机链接。这里没有沿用 Android 写死的第三方媒体默认域名。

## 通知与签名

默认构建提供本地提醒和系统后台刷新。iOS 的后台连接有时限，系统刷新也可能延迟；长时间后台的即时通知需要 APNs。

[推送桥接](push-relay/README.md) 已提供设备绑定、归属校验、SSE 监听、APNs 投递、恢复与解除绑定。桥接按单个 xbot 账号隔离部署。App 不向桥接提交 xbot 密码或 Cookie。

本地及 APNs 通知只显示通用完成／提问提示，不再包含聊天正文或会话名称。后台仅声明实际使用的 `fetch` 模式；普通 APNs alert 不需要声明静默推送后台模式。

启用推送的归档示例（只构建，不上传，不自动修改 Apple 配置）：

```bash
XBOT_TEAM_ID=<TEAM_ID> XBOT_BUNDLE_ID=<XBOT_APP_ID> \
XBOT_PUSH_ENABLED=YES APS_ENVIRONMENT=production bash scripts/archive_ios.sh
```

需要与该 App ID 匹配的推送描述文件和 APNs 密钥。本轮按要求先完成代码，没有配置真实 APNs、部署桥接或发布 TestFlight / App Store。米可现有推送应用身份不作为 xbot 身份使用。

## 更新清单

「设置 → 版本更新」配置 iOS 清单地址。清单含 `platform: "ios"`、`versionName`、`versionCode`、`url`、`changelog`、`mandatory`。只接受 HTTPS 的 App Store / TestFlight 安装链接，不使用 Android APK 清单。

```bash
python3 scripts/make_update_manifest.py --version 1.0.1 --build 2 \
  --url https://testflight.apple.com/join/EXAMPLE --changelog '版本说明'
```

此命令只生成清单，须先有可用的分发版本再发布。

## 验证

```bash
swift test --scratch-path /tmp/xbot-ios-core-build
node --test push-relay/relay.test.mjs
node --test compliance-service/service.test.mjs

# 单独启动虚构账号的本地协议服务器
python3 scripts/fixture_server.py

# 替换为实际模拟器 UUID，保留模拟器本地签名供钥匙串使用
xcodebuild -project Xbot.xcodeproj -scheme Xbot \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath /tmp/xbot-ios-build -parallel-testing-enabled NO test
```

真实服务器的 Debug 原生验收工具读取私有两行账号文件，不打印凭据。它会创建并删除自己的测试会话、写回设置原值、上传小型测试图片、调用模型和回退自己创建的历史：

```bash
python3 scripts/run_native_validation.py --device <SIMULATOR_UUID> \
  --app /tmp/xbot-ios-build/Build/Products/Debug-iphonesimulator/Xbot.app \
  --server https://your-xbot.example.com --credentials /private/xbot_user \
  --consent-to-ai-sharing --ai-recipients '你已核实的实际 AI / 代理接收方'
```

纯本地模型可改用 `--consent-to-ai-sharing --local-models-only`。此 Debug 工具也遵循分享确认，不绕过正式客户端的传输检查。构建后可运行 `python3 scripts/check_app_privacy.py --app /path/to/Xbot.app` 核对实际包内隐私清单、ATS 和离线图表资源。

## 自托管账号删除与举报

旧服务器继续支持原有聊天和管理功能，不强制部署新后台。远端账号／数据删除及私有举报受理需要服务器实际提供能力；App 不会把退出登录或本机清除伪装成远端删除。

仓库提供可选的 [配套服务](compliance-service/README.md)：同源接口、密码重新验证、私有举报队列、删除申请、随机回执、状态查询及本机管理员处理工具。它不会盲目修改 xbot 数据库；管理员须按部署实际归属执行数据删除，并在承诺期限内处理申请。未接入时，App 明确显示未受理，仍可清除本机当前账号数据、屏蔽会话，或导出举报交给自己的管理员。

## 目录

- `Sources/XbotCore`：协议、SSE、状态机、Markdown、通知快照。
- `Sources/XbotApp`：SwiftUI、网络、钥匙串、通知与更新。
- `Tests` / `XbotUITests`：核心和模拟器测试。
- `push-relay`：Node.js APNs 桥接与协议测试。
- `compliance-service`：用户自托管的可选删除申请／举报服务及测试，不是聊天必需依赖。
- `scripts`：工程生成、归档、更新清单、fixture 与真实验收工具。

与 Android 一致，GenUI / 插件展示文本；没有 Web 插件运行时、离线历史缓存、终端或插件市场。参考项目及 Mermaid 的 MIT 版权声明分别见 `LICENSE` 与 `Sources/XbotApp/Resources/Mermaid/LICENSE`。
