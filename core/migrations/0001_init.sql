-- 0001_init —— Nexmem 本地库初始结构
-- 时间戳统一为 Unix 秒；密钥与密文均为 BLOB。

CREATE TABLE account (
  id                   INTEGER PRIMARY KEY CHECK (id = 1),
  account_pub          BLOB NOT NULL,
  account_priv_enc     BLOB NOT NULL,
  account_x_pub        BLOB NOT NULL,
  account_x_priv_enc   BLOB NOT NULL,
  device_pub           BLOB NOT NULL,
  device_priv_enc      BLOB NOT NULL,
  device_cert          BLOB NOT NULL,
  display_name         TEXT
);

CREATE TABLE contacts (
  account_pub BLOB PRIMARY KEY,
  alias       TEXT,
  group_name  TEXT,
  blocked     INTEGER NOT NULL DEFAULT 0,
  profile     BLOB,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE conversations (
  id          TEXT PRIMARY KEY,
  kind        INTEGER NOT NULL,
  title       TEXT,
  last_msg_at INTEGER,
  unread      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  msg_uuid        TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  sender_account  BLOB NOT NULL,
  sent_at         INTEGER NOT NULL,
  direction       INTEGER NOT NULL,
  content_type    INTEGER NOT NULL,
  body_enc        BLOB NOT NULL,
  state           INTEGER NOT NULL,
  raw             BLOB
);

CREATE INDEX idx_messages_conv ON messages(conversation_id, sent_at);

CREATE TABLE inbox_cursors (
  scope      TEXT PRIMARY KEY,
  object_key TEXT NOT NULL,
  etag       TEXT,
  seen_at    INTEGER NOT NULL
);

CREATE TABLE groups (
  group_id        BLOB PRIMARY KEY,
  title           TEXT,
  my_role         INTEGER NOT NULL,
  key_version     INTEGER NOT NULL,
  group_key_enc   BLOB NOT NULL,
  storage_cfg_enc BLOB,
  offline_enabled INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE group_members (
  group_id    BLOB NOT NULL,
  account_pub BLOB NOT NULL,
  role        INTEGER NOT NULL,
  joined_at   INTEGER NOT NULL,
  PRIMARY KEY (group_id, account_pub)
);

CREATE TABLE outbox (
  msg_uuid      TEXT PRIMARY KEY,
  peer_account  BLOB,
  attempts      INTEGER NOT NULL DEFAULT 0,
  next_retry_at INTEGER NOT NULL,
  payload       BLOB NOT NULL
);

CREATE TABLE kv (
  k TEXT PRIMARY KEY,
  v BLOB NOT NULL
);
