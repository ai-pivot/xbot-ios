# 自托管服务器的可选删除与举报服务

这是用户自行部署的配套服务，**不是使用 iOS 聊天功能的前提**，也不属于客户端维护者统一运营的后台。未修改的 xbot 仍通过原来的 REST / RPC / SSE 工作。客户端直接读取 `list_subscriptions` 并请求用户确认数据去向。

Node.js 22+，无外部依赖。服务仅监听 `127.0.0.1`，由现有 HTTPS 反向代理在 xbot 同源下挂载 `/api/mobile/`。不要在 App 中填写维护者托管的默认服务，也不要公开私有队列目录。

```bash
cp compliance-service/config.example.json /private/xbot-compliance.json
# 填写实际上游和私有状态目录；不要把真实配置放入 Git。
XBOT_COMPLIANCE_CONFIG=/private/xbot-compliance.json node compliance-service/server.mjs
```

Nginx 示例（保留已有的 xbot 转发；服务不代理聊天或 SSE）：

```nginx
location /api/mobile/ {
    proxy_pass http://127.0.0.1:18883/api/mobile/;
    client_max_body_size 32k;
    # 原样转发 Cookie，不记录请求正文，不能缓存响应。
    proxy_set_header Cookie $http_cookie;
    proxy_set_header Host $host;
    proxy_no_cache 1;
    proxy_cache_bypass 1;
}
```

子路径部署可使用 `/xbot/api/mobile/`，仍转发到 `http://127.0.0.1:18883/api/mobile/`。上游 HTTP 仅允许 loopback；公网必须 HTTPS。应配置代理层登录尝试限速，不能根据客户端可伪造的转发头授予权限。服务自身也有请求体限制、来源检查和限速。

## 接口

全部 POST，响应使用 `{ "ok": true, "data": ... }`，禁止跨站浏览器提交，不开放 CORS。

- `account-deletion`：`username`、`password`、UUID `request_id`。向原 xbot 登录接口重新验证密码，创建私有待处理申请，返回随机回执 `id`、`status: pending`、ISO `deadline`。不保存密码、登录 Cookie 或 IP；临时认证会话在请求后退出。重复请求号不会新建申请。
- `reports`：使用现有 xbot Cookie，对会话树进行归属／可访问性校验。提交 UUID `request_id`、`chat_id`、`channel`、`turn_id`、`reason`、可选 `detail`。只有用户明确勾选附带正文时才传 `content`。返回 `id`、`status: received`。
- `status`：凭 256 位随机回执 `id` 查询最小状态，不返回账号、聊天或举报正文。回执本身是访问凭据，请妥善保存，不要公开。
- `policy`：默认 404，客户端自动使用自托管说明，无须编造运营主体。如果确实对外运营服务，可在配置添加真实 `policy` 对象，字段为 `version`、`operator_name`、HTTPS `privacy_url`、HTTPS `support_url`、`providers: [{name, privacy_url}]`、`retention`、`deletion_days`（1–30）、`content_filtering`。这些内容必须与实际服务相符。内容过滤布尔值只是运营声明，**不会替你实现模型或工具的内容审核**。

## 申请的实际处理

本服务接收删除申请并保留回执，**不直接编辑 xbot 数据库**。不同版本 xbot 的账号、工作空间、附件、插件、备份和会话归属不同，不能把 `DELETE FROM web_users` 当成完整数据删除，更不能删除共享工作空间来替一个账号注销。

管理员必须在承诺期限内检查私有队列、处理举报，并实际完成对应账号的数据与会话删除。Apple 允许需要合理处理时间的删除申请，但不能用永久待处理的按钮替代履约。若无人值守、无处理流程，请勿宣称该部署已具备完整删除／举报服务。

```bash
node compliance-service/manage.mjs /private/xbot-mobile-requests list
# 先实际删除账号、会话凭据、历史、附件、关联工具数据，并按政策处理备份与法律保留项。
# 确认完成后，再记录完成状态；此命令本身不执行数据库删除。
node compliance-service/manage.mjs /private/xbot-mobile-requests complete-deletion RECEIPT_ID --confirm-erasure
node compliance-service/manage.mjs /private/xbot-mobile-requests resolve-report RECEIPT_ID
```

完成删除后队列记录移除用户名；举报解决后移除附带正文和补充说明。应按实际保留政策清理已完成记录及相应 `index-*` 文件，限制目录权限并保护备份。CLI 只在服务器本地使用，没有公开管理接口。

```bash
node --test compliance-service/service.test.mjs
```

测试只使用本地虚构账号，覆盖重新认证、回执幂等、敏感凭据不落盘、会话访问校验、正文选择、跨站拒绝与传输限制；不验证任何生产删除或人工处理承诺。
