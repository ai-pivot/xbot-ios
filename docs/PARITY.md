# Android 功能对齐清单

对齐基线：[ai-pivot/xbot-android @ 761ec91893cedf94329c1e9de87d0743942c0692](https://github.com/ai-pivot/xbot-android/tree/761ec91893cedf94329c1e9de87d0743942c0692)。日期：2026-10-21。这里区分客户端实现与外部签名、推送和商店验收。

| Android 功能 | iOS 实现 | 验证依据 |
| --- | --- | --- |
| 登录、注册首个管理员、服务器检测 | 原生登录和 bootstrap 检测 | 登录 fixture / 真实服务器；注册未在现有服务器重复执行 |
| Cookie 持久化、静默重新登录 | 按服务器隔离的钥匙串，401 单次重试 | 模拟器恢复、真实 401 后重新登录 |
| 会话树、子 Agent、搜索、轮询 | 会话页、运行与错误标记、活动时间 | 源码协议核对、真实列表 |
| 新建、重命名、删除、Fork | 行菜单及长按菜单，保留 channel | 真实创建、重命名、分支及清理 |
| 历史、turn / iteration 分组及分页 | 纯状态机和历史分页 | 核心测试、真实历史恢复 |
| SSE 增量、快照、心跳、重连 | 字节级解析、55 秒空闲超时、退避 | 核心测试、fixture、真实原生 SSE |
| Last-Event-ID、路由、重放、resync | 事件游标及完整重同步 | 核心测试及真实连接 |
| 工具参数、摘要、详情、状态、耗时 | 可展开原生卡片 | 状态机测试、界面预览 |
| 思考过程及文本流 | 可展开思考、独立迭代与最终结果 | 状态测试和真实消息 |
| 发送、忙时排队、停止 | 消息请求、队列显示、取消 | 核心测试、真实发送与取消 |
| 历史回退、恢复草稿、选取目标 | 消息菜单和历史选择器 | 真实回退并恢复原文 |
| 文件、照片、multipart、附件元数据 | 文件和照片选择器、附件移除与发送 | 真实上传与认证下载；选择器为系统组件 |
| AskUser 新旧负载、多选、自由回答、取消、稍后 | 原生问答页；1 起始题号、顿号多选 | 核心协议测试及单选提交 fixture |
| Markdown 标题、列表、引用、代码、链接、表格 | 原生块与横向表格、复制 / 选择 | Markdown 单元测试和界面验证 |
| Mermaid、图表放大 | 相同离线 Mermaid 库，隔离 WebKit | 界面渲染与全屏验证 |
| 图片加载、localhost 重写、全屏缩放 | 同源认证、媒体地址偏好、原生捏合 / 平移 | 媒体 URL 测试、真实下载、图片界面验证 |
| 首尾跳转、自动跟随 | 聊天浮动按钮和跟随状态 | 界面验证；修复布局反馈循环 |
| 默认 / 会话模型、订阅、模型、工具开关 | 对应 RPC 设置 | 真实读取及原值写回、UI 设置测试 |
| 思考 / 上下文、Token、并发、压缩阈值 | 全部对应 RPC，思考 enabled 线格式转换 | 兼容测试、真实原值写回 |
| 浅色 / 深色 / 系统 | SwiftUI 与系统外观 | 浅色 / 深色截图及 UI 测试 |
| 后台完成 / AskUser 提醒 | 有限后台 SSE、本地通知、后台刷新、可选 APNs 桥接 | 本地通知 UI；桥接 HTTP/2 与 SSE 测试；真实 APNs 待配置 |
| 自动 / 手动更新、说明、安装入口 | iOS 清单、App Store / TestFlight 链接 | 清单协议测试和 UI 检查；没有实际商店发布 |

## 平台与配置差异

1. Android 的前台服务可长时间持有 SSE；iOS 的后台执行由系统限制。客户端实现了本地提醒、系统刷新以及 APNs 桥接接入。由于暂时没有 xbot 独立推送配置，APNs 默认关闭，长期推送尚未做真机到达验收。用户已确认本轮先完成代码。
2. iOS 更新通过 App Store 或 TestFlight，替代 Android APK 下载与安装；版本清单必须显式标记 `platform: ios`。
3. Android 媒体域名存在硬编码默认值；iOS 使用明确填写的对象存储地址，避免把私有引用发给不相关默认域名。配置后使用相同 localhost 地址重写规则。
4. 密码与 Cookie 使用 Apple 钥匙串，对应 Android Keystore。Swift 使用原生视图和系统文件 / 照片选择器。

这些差异不等于已完成外部分发或推送验收。GenUI / 插件运行时、Web 终端、插件市场、离线历史、数学公式均不属于参考 Android 已实现的功能范围。

## 主要对应源文件

Android：`data/XbotApi.kt`、`data/Models.kt`、`chat/ChatReducer.kt`、`ui/ChatScreen.kt`、`ui/SettingsViewModel.kt`、`ui/components/MarkdownText.kt`、`ui/components/MermaidView.kt`、`sessions/SessionsScreen.kt`、通知服务及更新模块。

iOS：`XbotAPI.swift`、`ChatState.swift`、`SSEParser.swift`、`ChatStore.swift`、`ChatView.swift`、`SettingsView.swift`、`MarkdownParser.swift`、`MermaidView.swift`、`NotificationController.swift`、`PushRelayController.swift`、`UpdateSettingsView.swift`，以及 `push-relay/`。
