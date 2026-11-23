-- 0003_message_search —— 本地消息全文检索索引（P2-07）
-- 使用 FTS5 trigram 分词：中英文均按 3 字符子串建索引，支持子串匹配。
-- body 由写入方提供可检索纯文本（文本消息取正文，文件消息取文件名）。

CREATE VIRTUAL TABLE message_search USING fts5(
  msg_uuid UNINDEXED,
  conversation_id UNINDEXED,
  body,
  tokenize = 'trigram'
);
