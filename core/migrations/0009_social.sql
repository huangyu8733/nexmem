-- 0009_social —— QQ 式好友/群管理增强所需的本地表。
--
-- 好友申请、入群申请、群角色/禁言、在线状态快照、系统通知、群投票与动态
-- 全部保存在本机 SQLite；跨端投递复用现有单聊文本控制帧，不新增 proto 类型。

-- 好友申请：from/to 为 32 字节账号公钥，status: 0=pending 1=accepted 2=rejected。
CREATE TABLE friend_requests (
  id           TEXT PRIMARY KEY,
  from_pub     BLOB NOT NULL,
  to_pub       BLOB NOT NULL,
  message      TEXT,
  status       INTEGER NOT NULL DEFAULT 0,
  direction    TEXT NOT NULL,          -- in / out
  created_at   INTEGER NOT NULL,
  responded_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_friendreq_from ON friend_requests(from_pub, status);
CREATE INDEX idx_friendreq_to   ON friend_requests(to_pub, status);

-- 入群申请：group_id 为文本群号，status 同上。
CREATE TABLE group_join_requests (
  id           TEXT PRIMARY KEY,
  group_id     TEXT NOT NULL,
  group_title  TEXT,
  applicant    BLOB NOT NULL,
  message      TEXT,
  status       INTEGER NOT NULL DEFAULT 0,
  direction    TEXT NOT NULL,          -- in（我收到的）/ out（我发出的）
  created_at   INTEGER NOT NULL,
  responded_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_groupjoin_group ON group_join_requests(group_id, status);

-- 群成员角色与禁言：覆盖基础 role，owner/admin/member；mute_until 为 Unix 秒。
CREATE TABLE IF NOT EXISTS member_profiles (
  group_id    BLOB NOT NULL,
  account_pub BLOB NOT NULL,
  role        TEXT NOT NULL DEFAULT 'member',   -- owner / admin / member
  title       TEXT,
  mute_until  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (group_id, account_pub)
);

-- 联系人在线状态快照：由 presence 事件刷新，供离线查询。
CREATE TABLE IF NOT EXISTS presence_cache (
  account_pub  BLOB PRIMARY KEY,
  online       INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER NOT NULL DEFAULT 0
);

-- 系统通知（好友申请结果、入群结果等）：供 UI 展示通知中心。
CREATE TABLE notifications (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,      -- friend.request / friend.accepted / group.invite / group.joined ...
  title      TEXT,
  body       TEXT,
  payload    TEXT,               -- JSON
  read       INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_notif_created ON notifications(created_at DESC);

-- 好友动态（QQ 空间简化版）：本人与好友可见的图文动态。
CREATE TABLE moments (
  id          TEXT PRIMARY KEY,
  account_pub BLOB NOT NULL,
  text        TEXT,
  attachments TEXT,              -- JSON 数组：分享 ID / 文件路径
  likes       INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_moments_created ON moments(created_at DESC);

-- 动态点赞：防重复，voter 为账号公钥 hex。
CREATE TABLE moment_likes (
  moment_id   TEXT NOT NULL,
  voter       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (moment_id, voter)
);

-- 动态评论。
CREATE TABLE moment_comments (
  id          TEXT PRIMARY KEY,
  moment_id   TEXT NOT NULL,
  account_pub BLOB NOT NULL,
  text        TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_moment_comments ON moment_comments(moment_id, created_at);

-- 群投票：options 为 JSON 字符串数组，votes 为 account->optionIndex 的 JSON 映射。
CREATE TABLE group_polls (
  id          TEXT PRIMARY KEY,
  group_id    TEXT NOT NULL,
  creator     BLOB NOT NULL,
  question    TEXT NOT NULL,
  options     TEXT NOT NULL,
  votes       TEXT NOT NULL DEFAULT '{}',
  created_at  INTEGER NOT NULL,
  closes_at   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_group_polls ON group_polls(group_id, created_at DESC);
