# xbot APNs 桥接

Node.js 22+，仅使用标准库。每个实例对应一个 xbot 测试/个人账号，不是多租户推送平台。该账号的密码保存在桥接所在服务器；App 只提交设备标识、服务器和当前会话，不向桥接发送 xbot 密码或 Cookie。

## 配置和运行

1. 为 xbot 注册独立 App ID，启用 Push Notifications，生成对应描述文件。准备具有该 topic 权限的 APNs token key（ES256 `.p8`、Key ID、Team ID）。App Store Connect 上传密钥不能直接作为 APNs 密钥。
2. 在服务所在机器的受限目录保存 `config.example.json` 的实际配置、APNs 私钥和账号文件，设置目录权限 700、文件权限 600。账号文件第一行为用户名，第二行为密码。`secret` 用随机生成、至少 32 个字符的专用绑定密钥。
3. `sandbox` 必须与 App 签名的 `aps-environment` 一致；`topic` 必须与 App 的 Bundle ID 一致。
4. 启动：

   ```bash
   XBOT_PUSH_CONFIG=/private/xbot-push/config.json node push-relay/server.mjs
   ```

5. 进程只监听 `127.0.0.1:18882`。在既有服务器上配置 HTTPS 反向代理到此端口，保留 `/devices` 路径及 Authorization 请求头，并由服务管理器负责重启。
6. 在 App「设置 → 会话通知 → 配置推送桥接」填写 HTTPS 地址与专用绑定密钥，再开启会话通知。每个设备只订阅最后打开的会话；切换会话会替换绑定。关闭通知或退出登录会解除绑定，失败时保留待清理记录并提示重试。

生产配置和设备注册表均不应加入 Git。注册表包含设备标识，自动以 600 权限保存。本轮没有实际配置或部署桥接，没有向 Apple 发送真实推送。

## 协议与恢复

- `POST /devices`，`Authorization: Bearer <secret>`；JSON：`device_token`、`server`、`chat_id`、`channel`。返回 `{"ok":true,"id":"<sha256>"}`。
- `DELETE /devices/<id>` 使用相同鉴权解除绑定。
- 绑定前从 xbot 会话树校验账号归属，以当前历史序号为基线，不重发旧消息。
- SSE 按会话共享连接，带 Cookie 与 Last-Event-ID；401 自动重新登录，断线指数退避。仅将完成文本和 AskUser 转成 APNs alert，过滤取消、打断、错误会话与重复序号。
- 注册表保存游标。服务器要求重同步时从历史恢复最后完成轮次和待答问题，并重建 SSE。APNs 无效设备自动移除；暂时失败保留游标供重试。
- App 在前台不显示系统通知；桥接绑定成功后暂停本地提醒投递以避免重复。iOS 对推送、网络、Focus 与通知权限的调度仍决定实际到达。

## 验证

```bash
node --test push-relay/relay.test.mjs
```

测试使用临时 ES256 密钥、本地 HTTP/2 模拟 Apple 和虚构 xbot 账号，不使用生产凭据。

Apple 文档：[注册 APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[Token 连接](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)、[发送请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)。
