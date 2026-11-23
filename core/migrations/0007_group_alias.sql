-- 0007_group_alias —— 群备注（本机可见的群别名，需求 §3.2）
-- 备注只保存在本机 SQLite，不上行、不同步给其他成员。
-- 空串表示未设置或已清除，写入群记录的其他操作不得清空已有备注。

ALTER TABLE groups ADD COLUMN alias TEXT NOT NULL DEFAULT '';
