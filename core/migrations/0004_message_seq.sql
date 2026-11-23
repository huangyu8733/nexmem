-- 0004_message_seq —— 为消息增加本地单调递增序号（P1-21 msg.listSince）
-- 序号是本机事件顺序，与 sent_at 无关；重建表以使用 AUTOINCREMENT，
-- 保证删除最新消息后新消息不会复用旧序号，客户端 after_seq 游标永不回退。

CREATE TABLE messages_new (
  seq             INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_uuid        TEXT NOT NULL UNIQUE,
  conversation_id TEXT NOT NULL,
  sender_account  BLOB NOT NULL,
  sent_at         INTEGER NOT NULL,
  direction       INTEGER NOT NULL,
  content_type    INTEGER NOT NULL,
  body_enc        BLOB NOT NULL,
  state           INTEGER NOT NULL,
  raw             BLOB
);

INSERT INTO messages_new
  (msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw)
SELECT msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw
FROM messages ORDER BY rowid;

DROP TABLE messages;
ALTER TABLE messages_new RENAME TO messages;

CREATE INDEX idx_messages_conv ON messages(conversation_id, sent_at);
CREATE INDEX idx_messages_conv_seq ON messages(conversation_id, seq);
