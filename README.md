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

完整对应关系和平台差异见 [功能对齐清单](docs/PARITY.md)，实测范围见 [验证记录](docs/VALIDATION.md)。界面：[浅色](docs/screenshots/chat-light.png) · [深色](docs/screenshots/chat-dark.png) · [表格与图表](docs/screenshots/chat-rich.png)。

## 连接与媒体

支持 HTTPS、局域网 HTTP 和反向代理子路径。模拟器可访问开发机 `127.0.0.1`；真机需使用服务器实际 IP 或域名。登录请求不跟随重定向，请填写最终地址。公网使用 HTTPS。

同源图片带 xbot 登录凭据请求，外部对象存储不附带 xbot Cookie。消息中绝对 `localhost` 图片链接需要在「设置 → 媒体 / 对象存储地址」填写实际对象存储域名；留空时不请求这些本机链接。这里没有沿用 Android 写死的第三方媒体默认域名。

## 通知与签名

默认构建提供本地提醒和系统后台刷新。iOS 的后台连接有时限，系统刷新也可能延迟；长时间后台的即时通知需要 APNs。

[推送桥接](push-relay/README.md) 已提供设备绑定、归属校验、SSE 监听、APNs 投递、恢复与解除绑定。桥接按单个 xbot 账号隔离部署。App 不向桥接提交 xbot 密码或 Cookie。

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
  --server https://your-xbot.example.com --credentials /private/xbot_user
```

## 目录

- `Sources/XbotCore`：协议、SSE、状态机、Markdown、通知快照。
- `Sources/XbotApp`：SwiftUI、网络、钥匙串、通知与更新。
- `Tests` / `XbotUITests`：核心和模拟器测试。
- `push-relay`：Node.js APNs 桥接与协议测试。
- `scripts`：工程生成、归档、更新清单、fixture 与真实验收工具。

与 Android 一致，GenUI / 插件展示文本；没有 Web 插件运行时、离线历史缓存、终端或插件市场。参考项目及 Mermaid 的 MIT 版权声明分别见 `LICENSE` 与 `Sources/XbotApp/Resources/Mermaid/LICENSE`。
