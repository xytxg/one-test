# Security

不要在公开 Issue 中提交订阅 URL、节点密码、Token、Cookie 或完整配置。系统实现 PBKDF2、HttpOnly/Secure/SameSite Cookie、CSRF、SSRF 基础阻止、CSP、安全响应头、请求体限制和参数化 D1 查询。建议为管理后台增加 Cloudflare Access。
