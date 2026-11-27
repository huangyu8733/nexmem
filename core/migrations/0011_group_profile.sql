-- 0011_group_profile —— 本群称呼与群等级。
-- 群等级配置只保存在本机 groups（levels_json 以字段级信封加密），通过加密群控制帧同步；
-- 本群称呼与等级 ID 保存在 group_members，空串表示未设置或已清除。
-- 密钥轮换整体替换成员表时必须按 account 保留这两列，不能清空。

ALTER TABLE groups ADD COLUMN levels_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE groups ADD COLUMN levels_json TEXT NOT NULL DEFAULT '';
ALTER TABLE group_members ADD COLUMN nickname TEXT NOT NULL DEFAULT '';
ALTER TABLE group_members ADD COLUMN level_id TEXT NOT NULL DEFAULT '';
