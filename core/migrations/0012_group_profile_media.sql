-- 0012_group_profile_media —— 群头像与群介绍。
-- 两个字段都是群内可见资料，落库前经字段级信封加密，通过加密群控制帧同步；
-- 空串表示未设置或已清除。密钥轮换、成员表同步等局部写入不得清空已有值。

ALTER TABLE groups ADD COLUMN avatar_b64 TEXT NOT NULL DEFAULT '';
ALTER TABLE groups ADD COLUMN description TEXT NOT NULL DEFAULT '';
