# Architecture

fetch 入口分发管理 UI、JSON API 和 Surge 托管配置。D1 保存元数据；KV 保存大文本、远程快照、最终配置与 Session。scheduled 逐个处理启用的 Profile，单个失败不会影响其他任务。
