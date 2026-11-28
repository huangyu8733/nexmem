-- 0013_contact_x_pub —— 好友申请/同意帧里携带的账号 X25519 公钥缓存。
-- 该公钥由已验签的端到端单聊控制帧提供，群密钥信封可据此在局域网/无目录服务环境下
-- 正常封装，不再强依赖信令服务器公开档案。NULL 表示尚未从对端学到。

ALTER TABLE contacts ADD COLUMN account_x_pub BLOB;
