# Surge Config Merge

部署在 Cloudflare Workers 上的 Surge 远程配置三方增量合并系统。它保存 Remote Previous、拉取 Remote Latest，再与受保护的 Local Base 合并；只有通过校验且没有未解决冲突时才发布新的完整托管配置。

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/xytxg/one-test)

## 存储架构

当前版本使用 **SQLite-backed Durable Object**，不再需要手动创建或填写：

- D1 Database ID
- KV Namespace ID
- D1 migration 命令

Wrangler 首次部署时会自动创建 `AppState` Durable Object。配置正文、远程快照、版本、日志和登录会话都存储在其中。

## Cloudflare Builds

```text
构建命令：npm test
部署命令：npx wrangler deploy
```

提交到 `main` 后，Cloudflare 会自动测试并部署。

## 本地部署

```bash
npm install
npm test
npx wrangler login
npx wrangler deploy
```

首次访问 Worker，输入至少 8 位管理员密码完成初始化。随后填写远程订阅、粘贴本地完整配置并点击立即检查。

托管地址：

```text
https://你的域名/profile/default/config?token=你的令牌
```

## 注意

旧版 D1/KV 中的数据不会自动迁移到 Durable Object。由于旧版部署尚未成功写入有效数据，可以直接使用当前版本重新部署。

## 已知限制

首版实现了核心闭环。高级并排 Diff、逐项冲突处理、历史正文下载和 Telegram 管理界面尚未进入首版 UI。Surge 对外仍需接收完整配置；增量发生在 Worker 内部。
