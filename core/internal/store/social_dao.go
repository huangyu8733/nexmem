package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// ---- 好友申请 ----

// FriendRequest 是一条好友申请记录。
type FriendRequest struct {
	ID          string
	FromPub     []byte
	ToPub       []byte
	Message     string
	Status      int // 0=pending 1=accepted 2=rejected
	Direction   string
	CreatedAt   int64
	RespondedAt int64
}

// InsertFriendRequest 写入一条好友申请。
func (d *DAO) InsertFriendRequest(ctx context.Context, r FriendRequest) error {
	if r.ID == "" || len(r.FromPub) == 0 || len(r.ToPub) == 0 {
		return errors.New("好友申请字段不完整")
	}
	if r.CreatedAt == 0 {
		r.CreatedAt = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO friend_requests (id, from_pub, to_pub, message, status, direction, created_at, responded_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.FromPub, r.ToPub, r.Message, r.Status, r.Direction, r.CreatedAt, r.RespondedAt)
	if err != nil {
		return fmt.Errorf("写入好友申请: %w", err)
	}
	return nil
}

// ListFriendRequests 返回与本机相关的好友申请（收发双方任一匹配）。
func (d *DAO) ListFriendRequests(ctx context.Context, self []byte, status *int, limit int) ([]FriendRequest, error) {
	if limit <= 0 {
		limit = 100
	}
	q := `SELECT id, from_pub, to_pub, IFNULL(message,''), status, direction, created_at, responded_at
	      FROM friend_requests WHERE (from_pub = ? OR to_pub = ?)`
	args := []any{self, self}
	if status != nil {
		q += ` AND status = ?`
		args = append(args, *status)
	}
	q += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := d.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("查询好友申请: %w", err)
	}
	defer rows.Close()
	out := make([]FriendRequest, 0, limit)
	for rows.Next() {
		var r FriendRequest
		if err := rows.Scan(&r.ID, &r.FromPub, &r.ToPub, &r.Message, &r.Status, &r.Direction, &r.CreatedAt, &r.RespondedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetFriendRequest 按 ID 读取好友申请。
func (d *DAO) GetFriendRequest(ctx context.Context, id string) (*FriendRequest, error) {
	var r FriendRequest
	err := d.db.QueryRowContext(ctx, `
		SELECT id, from_pub, to_pub, IFNULL(message,''), status, direction, created_at, responded_at
		FROM friend_requests WHERE id = ?`, id).
		Scan(&r.ID, &r.FromPub, &r.ToPub, &r.Message, &r.Status, &r.Direction, &r.CreatedAt, &r.RespondedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取好友申请: %w", err)
	}
	return &r, nil
}

// SetFriendRequestStatus 更新好友申请状态。
func (d *DAO) SetFriendRequestStatus(ctx context.Context, id string, status int) error {
	res, err := d.db.ExecContext(ctx, `UPDATE friend_requests SET status = ?, responded_at = ? WHERE id = ?`,
		status, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("更新好友申请状态: %w", err)
	}
	return requireRow(res)
}

// DeleteFriendRequest 删除本机可见的一条好友申请，返回实际删除条数。
func (d *DAO) DeleteFriendRequest(ctx context.Context, self []byte, id string) (int64, error) {
	res, err := d.db.ExecContext(ctx,
		`DELETE FROM friend_requests WHERE id = ? AND (from_pub = ? OR to_pub = ?)`, id, self, self)
	if err != nil {
		return 0, fmt.Errorf("删除好友申请: %w", err)
	}
	return res.RowsAffected()
}

// ClearFriendRequests 清空本机所有好友申请，返回实际删除条数。
func (d *DAO) ClearFriendRequests(ctx context.Context, self []byte) (int64, error) {
	res, err := d.db.ExecContext(ctx,
		`DELETE FROM friend_requests WHERE from_pub = ? OR to_pub = ?`, self, self)
	if err != nil {
		return 0, fmt.Errorf("清空好友申请: %w", err)
	}
	return res.RowsAffected()
}

// CountPendingFriendRequests 统计待处理的好友申请数（收件方向）。
func (d *DAO) CountPendingFriendRequests(ctx context.Context, self []byte) (int, error) {
	var n int
	err := d.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM friend_requests WHERE to_pub = ? AND status = 0`, self).Scan(&n)
	return n, err
}

// ---- 入群申请 ----

// GroupJoinRequest 是一条入群申请。
type GroupJoinRequest struct {
	ID          string
	GroupID     string
	GroupTitle  string
	Applicant   []byte
	Message     string
	Status      int
	Direction   string
	CreatedAt   int64
	RespondedAt int64
}

// InsertGroupJoinRequest 写入入群申请。
func (d *DAO) InsertGroupJoinRequest(ctx context.Context, r GroupJoinRequest) error {
	if r.ID == "" || r.GroupID == "" || len(r.Applicant) == 0 {
		return errors.New("入群申请字段不完整")
	}
	if r.CreatedAt == 0 {
		r.CreatedAt = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO group_join_requests (id, group_id, group_title, applicant, message, status, direction, created_at, responded_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.GroupID, r.GroupTitle, r.Applicant, r.Message, r.Status, r.Direction, r.CreatedAt, r.RespondedAt)
	if err != nil {
		return fmt.Errorf("写入入群申请: %w", err)
	}
	return nil
}

// ListGroupJoinRequests 返回本机相关入群申请，可按群号过滤。
func (d *DAO) ListGroupJoinRequests(ctx context.Context, self []byte, groupID string, status *int, limit int) ([]GroupJoinRequest, error) {
	if limit <= 0 {
		limit = 100
	}
	q := `SELECT id, group_id, IFNULL(group_title,''), applicant, IFNULL(message,''), status, direction, created_at, responded_at
	      FROM group_join_requests WHERE applicant = ? OR direction = 'in'`
	args := []any{self}
	if groupID != "" {
		q += ` AND group_id = ?`
		args = append(args, groupID)
	}
	if status != nil {
		q += ` AND status = ?`
		args = append(args, *status)
	}
	q += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := d.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("查询入群申请: %w", err)
	}
	defer rows.Close()
	out := make([]GroupJoinRequest, 0, limit)
	for rows.Next() {
		var r GroupJoinRequest
		if err := rows.Scan(&r.ID, &r.GroupID, &r.GroupTitle, &r.Applicant, &r.Message, &r.Status, &r.Direction, &r.CreatedAt, &r.RespondedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetGroupJoinRequest 按 ID 读取入群申请。
func (d *DAO) GetGroupJoinRequest(ctx context.Context, id string) (*GroupJoinRequest, error) {
	var r GroupJoinRequest
	err := d.db.QueryRowContext(ctx, `
		SELECT id, group_id, IFNULL(group_title,''), applicant, IFNULL(message,''), status, direction, created_at, responded_at
		FROM group_join_requests WHERE id = ?`, id).
		Scan(&r.ID, &r.GroupID, &r.GroupTitle, &r.Applicant, &r.Message, &r.Status, &r.Direction, &r.CreatedAt, &r.RespondedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// DeleteGroupJoinRequest 删除本机可见的一条入群申请，返回实际删除条数。
func (d *DAO) DeleteGroupJoinRequest(ctx context.Context, self []byte, id string) (int64, error) {
	res, err := d.db.ExecContext(ctx,
		`DELETE FROM group_join_requests WHERE id = ? AND (applicant = ? OR direction = 'in')`, id, self)
	if err != nil {
		return 0, fmt.Errorf("删除入群申请: %w", err)
	}
	return res.RowsAffected()
}

// ClearGroupJoinRequests 清空本机所有入群申请，返回实际删除条数。
func (d *DAO) ClearGroupJoinRequests(ctx context.Context, self []byte) (int64, error) {
	res, err := d.db.ExecContext(ctx,
		`DELETE FROM group_join_requests WHERE applicant = ? OR direction = 'in'`, self)
	if err != nil {
		return 0, fmt.Errorf("清空入群申请: %w", err)
	}
	return res.RowsAffected()
}

// SetGroupJoinRequestStatus 更新入群申请状态。
func (d *DAO) SetGroupJoinRequestStatus(ctx context.Context, id string, status int) error {
	res, err := d.db.ExecContext(ctx, `UPDATE group_join_requests SET status = ?, responded_at = ? WHERE id = ?`,
		status, time.Now().Unix(), id)
	if err != nil {
		return err
	}
	return requireRow(res)
}

// ---- 成员资料（角色/头衔/禁言）----

// MemberProfile 描述群成员在本机的管理属性。
type MemberProfile struct {
	GroupID    []byte
	AccountPub []byte
	Role       string
	Title      string
	MuteUntil  int64
}

// UpsertMemberProfile 写入或更新成员资料。
func (d *DAO) UpsertMemberProfile(ctx context.Context, p MemberProfile) error {
	if len(p.GroupID) == 0 || len(p.AccountPub) == 0 {
		return errors.New("成员资料字段不完整")
	}
	if p.Role == "" {
		p.Role = "member"
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO member_profiles (group_id, account_pub, role, title, mute_until)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(group_id, account_pub) DO UPDATE SET
			role = excluded.role, title = excluded.title, mute_until = excluded.mute_until`,
		p.GroupID, p.AccountPub, p.Role, nullableText(p.Title), p.MuteUntil)
	return err
}

// GetMemberProfile 读取成员资料，不存在返回 ErrNotFound。
func (d *DAO) GetMemberProfile(ctx context.Context, groupID, account []byte) (*MemberProfile, error) {
	var p MemberProfile
	var title sql.NullString
	err := d.db.QueryRowContext(ctx, `
		SELECT group_id, account_pub, role, IFNULL(title,''), mute_until
		FROM member_profiles WHERE group_id = ? AND account_pub = ?`, groupID, account).
		Scan(&p.GroupID, &p.AccountPub, &p.Role, &title, &p.MuteUntil)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	p.Title = title.String
	return &p, nil
}

// ListMemberProfiles 返回某群全部成员资料。
func (d *DAO) ListMemberProfiles(ctx context.Context, groupID []byte) ([]MemberProfile, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, account_pub, role, IFNULL(title,''), mute_until
		FROM member_profiles WHERE group_id = ?`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MemberProfile, 0)
	for rows.Next() {
		var p MemberProfile
		if err := rows.Scan(&p.GroupID, &p.AccountPub, &p.Role, &p.Title, &p.MuteUntil); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ---- 在线状态快照 ----

// UpsertPresence 更新一个账号的在线快照。
func (d *DAO) UpsertPresence(ctx context.Context, account []byte, online bool, at int64) error {
	if at == 0 {
		at = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO presence_cache (account_pub, online, last_seen_at) VALUES (?, ?, ?)
		ON CONFLICT(account_pub) DO UPDATE SET online = excluded.online, last_seen_at = excluded.last_seen_at`,
		account, boolInt(online), at)
	return err
}

// ListPresence 返回所有在线快照。
func (d *DAO) ListPresence(ctx context.Context) (map[string]bool, error) {
	rows, err := d.db.QueryContext(ctx, `SELECT account_pub, online FROM presence_cache`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]bool)
	for rows.Next() {
		var pub []byte
		var online int
		if err := rows.Scan(&pub, &online); err != nil {
			return nil, err
		}
		out[fmt.Sprintf("%x", pub)] = online != 0
	}
	return out, rows.Err()
}

// ---- 通知 ----

// Notification 是一条系统通知。
type Notification struct {
	ID        string
	Kind      string
	Title     string
	Body      string
	Payload   string
	Read      bool
	CreatedAt int64
}

// InsertNotification 写入一条通知。
func (d *DAO) InsertNotification(ctx context.Context, n Notification) error {
	if n.ID == "" || n.Kind == "" {
		return errors.New("通知字段不完整")
	}
	if n.CreatedAt == 0 {
		n.CreatedAt = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO notifications (id, kind, title, body, payload, read, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		n.ID, n.Kind, nullableText(n.Title), nullableText(n.Body), nullableText(n.Payload), boolInt(n.Read), n.CreatedAt)
	return err
}

// ListNotifications 返回通知列表（最新在前）。
func (d *DAO) ListNotifications(ctx context.Context, limit int, unreadOnly bool) ([]Notification, error) {
	if limit <= 0 {
		limit = 100
	}
	q := `SELECT id, kind, IFNULL(title,''), IFNULL(body,''), IFNULL(payload,''), read, created_at FROM notifications`
	if unreadOnly {
		q += ` WHERE read = 0`
	}
	q += ` ORDER BY created_at DESC LIMIT ?`
	rows, err := d.db.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Notification, 0, limit)
	for rows.Next() {
		var n Notification
		var read int
		if err := rows.Scan(&n.ID, &n.Kind, &n.Title, &n.Body, &n.Payload, &read, &n.CreatedAt); err != nil {
			return nil, err
		}
		n.Read = read != 0
		out = append(out, n)
	}
	return out, rows.Err()
}

// CountUnreadNotifications 统计未读通知数。
func (d *DAO) CountUnreadNotifications(ctx context.Context) (int, error) {
	var n int
	err := d.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM notifications WHERE read = 0`).Scan(&n)
	return n, err
}

// MarkNotificationRead 标记单条通知已读。
func (d *DAO) MarkNotificationRead(ctx context.Context, id string) error {
	_, err := d.db.ExecContext(ctx, `UPDATE notifications SET read = 1 WHERE id = ?`, id)
	return err
}

// MarkAllNotificationsRead 标记全部通知已读。
func (d *DAO) MarkAllNotificationsRead(ctx context.Context) error {
	_, err := d.db.ExecContext(ctx, `UPDATE notifications SET read = 1 WHERE read = 0`)
	return err
}

// DeleteNotification 删除一条通知，返回实际删除条数。
func (d *DAO) DeleteNotification(ctx context.Context, id string) (int64, error) {
	res, err := d.db.ExecContext(ctx, `DELETE FROM notifications WHERE id = ?`, id)
	if err != nil {
		return 0, fmt.Errorf("删除通知: %w", err)
	}
	return res.RowsAffected()
}

// ClearNotifications 清空全部通知，返回实际删除条数。
func (d *DAO) ClearNotifications(ctx context.Context) (int64, error) {
	res, err := d.db.ExecContext(ctx, `DELETE FROM notifications`)
	if err != nil {
		return 0, fmt.Errorf("清空通知: %w", err)
	}
	return res.RowsAffected()
}

// ---- 动态 ----

// Moment 是一条好友动态。
type Moment struct {
	ID          string
	AccountPub  []byte
	Text        string
	Attachments string
	Likes       int
	CreatedAt   int64
}

// InsertMoment 写入一条动态。
func (d *DAO) InsertMoment(ctx context.Context, m Moment) error {
	if m.ID == "" || len(m.AccountPub) == 0 {
		return errors.New("动态字段不完整")
	}
	if m.CreatedAt == 0 {
		m.CreatedAt = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO moments (id, account_pub, text, attachments, likes, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`, m.ID, m.AccountPub, nullableText(m.Text), nullableText(m.Attachments), m.Likes, m.CreatedAt)
	return err
}

// ListMoments 返回动态流（最新在前）。
func (d *DAO) ListMoments(ctx context.Context, limit int) ([]Moment, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, account_pub, IFNULL(text,''), IFNULL(attachments,''), likes, created_at
		FROM moments ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Moment, 0, limit)
	for rows.Next() {
		var m Moment
		if err := rows.Scan(&m.ID, &m.AccountPub, &m.Text, &m.Attachments, &m.Likes, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// AddMomentLike 点赞（幂等）。
func (d *DAO) AddMomentLike(ctx context.Context, momentID, voter string) (bool, error) {
	res, err := d.db.ExecContext(ctx, `INSERT OR IGNORE INTO moment_likes (moment_id, voter, created_at) VALUES (?, ?, ?)`,
		momentID, voter, time.Now().Unix())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	if n > 0 {
		_, _ = d.db.ExecContext(ctx, `UPDATE moments SET likes = likes + 1 WHERE id = ?`, momentID)
	}
	return n > 0, nil
}

// RemoveMomentLike 取消点赞（幂等）。
func (d *DAO) RemoveMomentLike(ctx context.Context, momentID, voter string) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM moment_likes WHERE moment_id = ? AND voter = ?`, momentID, voter)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		_, _ = d.db.ExecContext(ctx, `UPDATE moments SET likes = MAX(0, likes - 1) WHERE id = ?`, momentID)
	}
	return nil
}

// MomentComment 是一条动态评论。
type MomentComment struct {
	ID         string
	MomentID   string
	AccountPub []byte
	Text       string
	CreatedAt  int64
}

// InsertMomentComment 写入评论。
func (d *DAO) InsertMomentComment(ctx context.Context, c MomentComment) error {
	if c.CreatedAt == 0 {
		c.CreatedAt = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO moment_comments (id, moment_id, account_pub, text, created_at) VALUES (?, ?, ?, ?, ?)`,
		c.ID, c.MomentID, c.AccountPub, c.Text, c.CreatedAt)
	return err
}

// ListMomentComments 返回某动态的评论。
func (d *DAO) ListMomentComments(ctx context.Context, momentID string) ([]MomentComment, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, moment_id, account_pub, text, created_at FROM moment_comments
		WHERE moment_id = ? ORDER BY created_at`, momentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MomentComment, 0)
	for rows.Next() {
		var c MomentComment
		if err := rows.Scan(&c.ID, &c.MomentID, &c.AccountPub, &c.Text, &c.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---- 群投票 ----

// GroupPoll 是一条群投票。
type GroupPoll struct {
	ID        string
	GroupID   string
	Creator   []byte
	Question  string
	Options   string
	Votes     string
	CreatedAt int64
	ClosesAt  int64
}

// InsertGroupPoll 写入投票。
func (d *DAO) InsertGroupPoll(ctx context.Context, p GroupPoll) error {
	if p.ID == "" || p.GroupID == "" || p.Question == "" {
		return errors.New("投票字段不完整")
	}
	if p.CreatedAt == 0 {
		p.CreatedAt = time.Now().Unix()
	}
	if p.Votes == "" {
		p.Votes = "{}"
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO group_polls (id, group_id, creator, question, options, votes, created_at, closes_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.GroupID, p.Creator, p.Question, p.Options, p.Votes, p.CreatedAt, p.ClosesAt)
	return err
}

// ListGroupPolls 返回群投票列表。
func (d *DAO) ListGroupPolls(ctx context.Context, groupID string, limit int) ([]GroupPoll, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := d.db.QueryContext(ctx, `
		SELECT id, group_id, creator, question, options, votes, created_at, closes_at
		FROM group_polls WHERE group_id = ? ORDER BY created_at DESC LIMIT ?`, groupID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]GroupPoll, 0, limit)
	for rows.Next() {
		var p GroupPoll
		if err := rows.Scan(&p.ID, &p.GroupID, &p.Creator, &p.Question, &p.Options, &p.Votes, &p.CreatedAt, &p.ClosesAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// VoteGroupPoll 投票（同一账号只能投一次，可改票）。返回最新的投票 JSON。
func (d *DAO) VoteGroupPoll(ctx context.Context, pollID, voter string, option int) (string, error) {
	var votesJSON string
	err := d.db.QueryRowContext(ctx, `SELECT votes FROM group_polls WHERE id = ?`, pollID).Scan(&votesJSON)
	if err != nil {
		return "", err
	}
	votes := map[string]int{}
	if err := json.Unmarshal([]byte(votesJSON), &votes); err != nil {
		votes = map[string]int{}
	}
	votes[voter] = option
	raw, _ := json.Marshal(votes)
	_, err = d.db.ExecContext(ctx, `UPDATE group_polls SET votes = ? WHERE id = ?`, string(raw), pollID)
	return string(raw), err
}

// DeleteMoment 删除本人动态。
func (d *DAO) DeleteMoment(ctx context.Context, id string, author []byte) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM moments WHERE id = ? AND account_pub = ?`, id, author)
	if err != nil {
		return err
	}
	return requireRow(res)
}
