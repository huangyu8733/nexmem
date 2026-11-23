-- 0005_conversation_flags —— 会话置顶与免打扰（ui-spec.md §2 状态标记）
-- pinned 参与会话列表排序（置顶优先），muted 仅影响本机展示，
-- 两者都只在本机生效，不上行、不影响对端。

ALTER TABLE conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE conversations ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_conversations_pinned ON conversations(pinned, last_msg_at);
