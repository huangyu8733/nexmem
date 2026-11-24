-- 群设置：是否允许成员互相添加好友（默认关闭）。
ALTER TABLE groups ADD COLUMN allow_friend_add INTEGER NOT NULL DEFAULT 0;
