-- 0002_group_keys —— 保留群密钥的历史版本
-- P4-04 退群轮换后旧版本仍要能解密历史消息与群盘对象，
-- 因此按 (group_id, key_version) 逐版本留存；groups.group_key_enc 仅保存最新版本。

CREATE TABLE group_keys (
  group_id    BLOB NOT NULL,
  key_version INTEGER NOT NULL,
  key_enc     BLOB NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (group_id, key_version)
);

-- 把 0001 已存在的当前版本密钥回填为历史第一版，避免升级后旧消息无法解密。
INSERT INTO group_keys (group_id, key_version, key_enc, created_at)
SELECT group_id, key_version, group_key_enc, unixepoch() FROM groups;

