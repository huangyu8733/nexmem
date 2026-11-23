-- 0008_message_expiry —— 定时消息的本机销毁时间（推荐功能：阅后即焚/定时消息）
-- expires_at 为 Unix 毫秒，0 表示永不过期。发送时正文 InnerMessage.ttl_hours
-- 随消息到达双方，各自按 sent_at + ttl_hours*3600*1000 算出本机销毁时间写入此列；
-- 后台 sweeper 定期物理删除 expires_at 已到期的消息并发出 message.expired 事件。

ALTER TABLE messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_messages_expiry ON messages(expires_at)
  WHERE expires_at > 0;
