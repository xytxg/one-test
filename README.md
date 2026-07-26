# Surge Config Merge

部署在 Cloudflare Workers 上的 Surge 远程配置三方增量合并系统。它保存 Remote Previous、拉取 Remote Latest，再与受保护的 Local Base 合并；只有通过校验且没有未解决冲突时才发布新的完整托管配置。

> 仓库为私有时 Cloudflare Deploy 按钮可能无法读取源码，请使用 Wrangler 部署或先将仓库公开。

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/xytxg/one-test)

## 部署

```bash
npm install
npx wrangler login
npx wrangler d1 create surge-config-merge
npx wrangler kv namespace create CONFIG_STORE
```

把返回的 D1 database_id 与 KV id 写入 wrangler.toml，然后：

```bash
npx wrangler d1 migrations apply DB --remote
npx wrangler deploy
```

首次访问 Worker，输入至少 8 位管理员密码完成初始化。随后填写远程订阅、粘贴本地完整配置并点击立即检查。

托管地址：

```text
https://你的域名/profile/default/config?token=你的令牌
```

## 验证

```bash
npm test
```

## 已知限制

首版实现了可部署核心闭环。高级并排 Diff、逐项冲突处理、历史正文下载和 Telegram 管理界面尚未进入首版 UI。Surge 对外仍需接收完整配置；增量发生在 Worker 内部。
