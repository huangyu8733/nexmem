-- 0006_group_announcement —— 群公告（需求 §3.2）
-- 公告文本只保存在本机 SQLite；成员通过群控制帧同步，不上行到任何服务端。
-- 空串表示未设置或已清除，写入群记录的其他操作不得清空已有公告。

ALTER TABLE groups ADD COLUMN announcement TEXT NOT NULL DEFAULT '';
