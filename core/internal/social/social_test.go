package social

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"

	"github.com/nexmem/core/internal/store"
)

func testDAO(t *testing.T) *store.DAO {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA journal_mode=WAL; CREATE TABLE kv (k TEXT PRIMARY KEY, v BLOB NOT NULL);`); err != nil {
		t.Fatal(err)
	}
	// 直接用 social 表的最小结构，避免依赖 migrations 包（内部路径约束）。
	stmts := []string{
		`CREATE TABLE contacts (account_pub BLOB PRIMARY KEY, account_x_pub BLOB, alias TEXT, group_name TEXT, blocked INTEGER NOT NULL DEFAULT 0, profile BLOB, updated_at INTEGER NOT NULL)`,
		`CREATE TABLE friend_requests (id TEXT PRIMARY KEY, from_pub BLOB NOT NULL, to_pub BLOB NOT NULL, message TEXT, status INTEGER NOT NULL DEFAULT 0, direction TEXT NOT NULL, created_at INTEGER NOT NULL, responded_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE group_join_requests (id TEXT PRIMARY KEY, group_id TEXT NOT NULL, group_title TEXT, applicant BLOB NOT NULL, message TEXT, status INTEGER NOT NULL DEFAULT 0, direction TEXT NOT NULL, created_at INTEGER NOT NULL, responded_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE member_profiles (group_id BLOB NOT NULL, account_pub BLOB NOT NULL, role TEXT NOT NULL DEFAULT 'member', title TEXT, mute_until INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (group_id, account_pub))`,
		`CREATE TABLE presence_cache (account_pub BLOB PRIMARY KEY, online INTEGER NOT NULL DEFAULT 0, last_seen_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE notifications (id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT, body TEXT, payload TEXT, read INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)`,
		`CREATE TABLE moments (id TEXT PRIMARY KEY, account_pub BLOB NOT NULL, text TEXT, attachments TEXT, likes INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)`,
		`CREATE TABLE moment_likes (moment_id TEXT NOT NULL, voter TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (moment_id, voter))`,
		`CREATE TABLE moment_comments (id TEXT PRIMARY KEY, moment_id TEXT NOT NULL, account_pub BLOB NOT NULL, text TEXT NOT NULL, created_at INTEGER NOT NULL)`,
		`CREATE TABLE group_polls (id TEXT PRIMARY KEY, group_id TEXT NOT NULL, creator BLOB NOT NULL, question TEXT NOT NULL, options TEXT NOT NULL, votes TEXT NOT NULL DEFAULT '{}', created_at INTEGER NOT NULL, closes_at INTEGER NOT NULL DEFAULT 0)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { _ = db.Close() })
	return store.NewDAO(db)
}

func TestControlFrameRoundTrip(t *testing.T) {
	f := Frame{Kind: KindFriendRequest, ID: "r1", From: strings.Repeat("a", 64), To: strings.Repeat("b", 64), Text: "你好", Timestamp: 123}
	enc := Encode(f)
	if !IsControlFrame(enc) {
		t.Fatal("未识别为控制帧")
	}
	got, ok := Decode(enc)
	if !ok {
		t.Fatal("控制帧解码失败")
	}
	if got.Kind != KindFriendRequest || got.ID != "r1" || got.Text != "你好" {
		t.Fatalf("解码内容不符: %+v", got)
	}
	if _, ok := Decode("普通聊天文本"); ok {
		t.Fatal("普通文本不应解码为控制帧")
	}
}

func TestGroupInviteNoticeFlow(t *testing.T) {
	ctx := context.Background()
	dao := testDAO(t)
	admin := bytes32(11)
	invitee := bytes32(12)
	var sent string
	adminSvc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return admin },
		Send: func(_ context.Context, peer []byte, text string) (string, error) {
			if hex.EncodeToString(peer) != hex.EncodeToString(invitee) {
				t.Fatalf("邀请通知目标错误: %x", peer)
			}
			sent = text
			return "msg-1", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := adminSvc.SendGroupInvite(ctx, "Z3JvdXA", "周末爬山", invitee); err != nil {
		t.Fatalf("发送群邀请失败: %v", err)
	}
	frame, ok := Decode(sent)
	if !ok || frame.Kind != KindGroupInvited || frame.GroupID != "Z3JvdXA" || frame.Extra["group_title"] != "周末爬山" {
		t.Fatalf("邀请控制帧内容不符: %+v", frame)
	}

	emitted := []string{}
	inviteeSvc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return invitee },
		Emit: func(name string, _ any) { emitted = append(emitted, name) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := inviteeSvc.HandleFrame(ctx, frame); err != nil {
		t.Fatalf("处理邀请控制帧失败: %v", err)
	}
	notifs, _ := dao.ListNotifications(ctx, 10, false)
	if len(notifs) != 1 || notifs[0].Kind != "group.invited" ||
		!strings.Contains(notifs[0].Body, "周末爬山") {
		t.Fatalf("邀请通知未生成: %+v", notifs)
	}
	if len(emitted) != 1 || emitted[0] != "group.invited" {
		t.Fatalf("邀请事件不完整: %v", emitted)
	}
}

func TestFriendRequestCarriesXPub(t *testing.T) {
	ctx := context.Background()
	dao := testDAO(t)
	sender := bytes32(13)
	receiver := bytes32(14)
	senderXPub := bytes32(23)
	var sent string
	svc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return sender },
		XPub: func() []byte { return senderXPub },
		Send: func(_ context.Context, _ []byte, text string) (string, error) {
			sent = text
			return "msg-xpub", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SendFriendRequest(ctx, receiver, "加个好友"); err != nil {
		t.Fatalf("发起申请失败: %v", err)
	}
	frame, ok := Decode(sent)
	if !ok || frame.Extra["xpub"] != hex.EncodeToString(senderXPub) {
		t.Fatalf("好友申请未携带 XPub: %+v", frame)
	}
	// 同一本地库里已有 out 记录，改成入站 ID 避免主键冲突。
	frame.ID = "in-xpub"
	receiverSvc, err := New(Options{DAO: dao, Self: func() []byte { return receiver }})
	if err != nil {
		t.Fatal(err)
	}
	if err := receiverSvc.HandleFrame(ctx, frame); err != nil {
		t.Fatalf("处理好友申请失败: %v", err)
	}
	c, err := dao.GetContact(ctx, sender)
	if err != nil || !bytes.Equal(c.AccountXPub, senderXPub) {
		t.Fatalf("对端 XPub 未缓存: %+v err=%v", c, err)
	}
}

func TestXPubRequestResponse(t *testing.T) {
	ctx := context.Background()
	dao := testDAO(t)
	requester := bytes32(15)
	responder := bytes32(16)
	responderXPub := bytes32(25)
	var reqText string
	requesterSvc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return requester },
		Send: func(_ context.Context, peer []byte, text string) (string, error) {
			if !bytes.Equal(peer, responder) {
				t.Fatalf("公钥请求目标错误: %x", peer)
			}
			reqText = text
			return "req-1", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := requesterSvc.RequestXPub(ctx, responder); err != nil {
		t.Fatalf("发起公钥请求失败: %v", err)
	}
	reqFrame, ok := Decode(reqText)
	if !ok || reqFrame.Kind != KindXPubReq {
		t.Fatalf("公钥请求控制帧非法: %+v", reqFrame)
	}

	var respText string
	responderSvc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return responder },
		XPub: func() []byte { return responderXPub },
		Send: func(_ context.Context, peer []byte, text string) (string, error) {
			if !bytes.Equal(peer, requester) {
				t.Fatalf("公钥应答目标错误: %x", peer)
			}
			respText = text
			return "resp-1", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := responderSvc.HandleFrame(ctx, reqFrame); err != nil {
		t.Fatalf("处理公钥请求失败: %v", err)
	}
	respFrame, ok := Decode(respText)
	if !ok || respFrame.Kind != KindXPubResp || respFrame.Extra["xpub"] != hex.EncodeToString(responderXPub) {
		t.Fatalf("公钥应答控制帧非法: %+v", respFrame)
	}

	notified := false
	receiverSvc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return requester },
		OnXPubReceived: func(_ context.Context, peer, xpub []byte) {
			notified = bytes.Equal(peer, responder) && bytes.Equal(xpub, responderXPub)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := receiverSvc.HandleFrame(ctx, respFrame); err != nil {
		t.Fatalf("处理公钥应答失败: %v", err)
	}
	c, err := dao.GetContact(ctx, responder)
	if err != nil || !bytes.Equal(c.AccountXPub, responderXPub) || !notified {
		t.Fatalf("公钥未缓存或回调未触发: %+v err=%v notified=%v", c, err, notified)
	}
}

func TestFriendRequestFlow(t *testing.T) {
	dao := testDAO(t)
	self := bytes32(1)
	peer := bytes32(2)
	added := [][]byte{}
	emitted := []string{}
	svc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return self },
		Send: func(_ context.Context, _ []byte, _ string) (string, error) { return "m1", nil },
		Emit: func(name string, _ any) { emitted = append(emitted, name) },
		OnFriendAccepted: func(_ context.Context, p []byte) error {
			added = append(added, p)
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	id, err := svc.SendFriendRequest(ctx, peer, "加个好友")
	if err != nil || id == "" {
		t.Fatalf("发起申请失败: %v", err)
	}
	list, err := dao.ListFriendRequests(ctx, self, nil, 10)
	if err != nil || len(list) != 1 || list[0].Direction != "out" {
		t.Fatalf("申请未落库: %v %+v", err, list)
	}
	if err := svc.RespondFriendRequest(ctx, id, true); err != nil {
		t.Fatalf("同意失败: %v", err)
	}
	if len(added) != 1 || hex.EncodeToString(added[0]) != hex.EncodeToString(peer) {
		t.Fatalf("未回调加好友: %+v", added)
	}
	req, _ := dao.GetFriendRequest(ctx, id)
	if req.Status != 1 {
		t.Fatalf("状态未更新: %d", req.Status)
	}
	hasContactNew := false
	hasResolved := false
	for _, name := range emitted {
		if name == "contact.new" {
			hasContactNew = true
		}
		if name == "friend.request.resolved" {
			hasResolved = true
		}
	}
	if !hasContactNew || !hasResolved {
		t.Fatalf("同意后事件不完整: %v", emitted)
	}
}

func TestHandleIncomingFriendRequest(t *testing.T) {
	dao := testDAO(t)
	self := bytes32(3)
	peer := bytes32(4)
	svc, _ := New(Options{DAO: dao, Self: func() []byte { return self }})
	f := Frame{Kind: KindFriendRequest, ID: "in1", From: hex.EncodeToString(peer), To: hex.EncodeToString(self), Text: "你好", Timestamp: 100}
	if err := svc.HandleFrame(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	list, _ := dao.ListFriendRequests(context.Background(), self, nil, 10)
	if len(list) != 1 || list[0].Direction != "in" {
		t.Fatalf("入站申请未落库: %+v", list)
	}
	notifs, _ := dao.ListNotifications(context.Background(), 10, false)
	if len(notifs) != 1 || notifs[0].Kind != "friend.request" {
		t.Fatalf("通知未生成: %+v", notifs)
	}
}

func TestHandleFriendAcceptEmitsContactNew(t *testing.T) {
	dao := testDAO(t)
	self := bytes32(6)
	peer := bytes32(7)
	emitted := []string{}
	svc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return self },
		Emit: func(name string, _ any) { emitted = append(emitted, name) },
		OnFriendAccepted: func(_ context.Context, p []byte) error {
			if hex.EncodeToString(p) != hex.EncodeToString(peer) {
				t.Fatalf("回调对端错误: %x", p)
			}
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	f := Frame{Kind: KindFriendAccept, ID: "accept1", From: hex.EncodeToString(peer), To: hex.EncodeToString(self)}
	if err := svc.HandleFrame(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, name := range emitted {
		if name == "contact.new" {
			found = true
		}
	}
	if !found {
		t.Fatalf("收到同意帧后未通知联系人刷新: %v", emitted)
	}
}

func TestMomentAndPoll(t *testing.T) {
	dao := testDAO(t)
	self := bytes32(5)
	svc, _ := New(Options{DAO: dao, Self: func() []byte { return self }})
	ctx := context.Background()
	mid, err := svc.PostMoment(ctx, "今天天气好", "", nil)
	if err != nil || mid == "" {
		t.Fatalf("发布动态失败: %v", err)
	}
	if _, err := dao.AddMomentLike(ctx, mid, "voter1"); err != nil {
		t.Fatal(err)
	}
	moments, _ := dao.ListMoments(ctx, 10)
	if len(moments) != 1 || moments[0].Likes != 1 {
		t.Fatalf("点赞数错误: %+v", moments)
	}
	pid, err := svc.CreatePoll(ctx, "group1", "去哪玩", []string{"A", "B"}, 0)
	if err != nil || pid == "" {
		t.Fatalf("创建投票失败: %v", err)
	}
	votes, err := svc.VotePoll(ctx, pid, 1)
	if err != nil || votes == "" {
		t.Fatalf("投票失败: %v %s", err, votes)
	}
	polls, _ := dao.ListGroupPolls(ctx, "group1", 10)
	if len(polls) != 1 || polls[0].Votes == "" {
		t.Fatalf("投票未落库: %+v", polls)
	}
}

func TestDeleteSocialRecords(t *testing.T) {
	dao := testDAO(t)
	ctx := context.Background()
	self := bytes32(1)
	peer := bytes32(2)

	if err := dao.InsertFriendRequest(ctx, store.FriendRequest{
		ID: "f1", FromPub: peer, ToPub: self, Direction: "in",
	}); err != nil {
		t.Fatal(err)
	}
	if err := dao.InsertFriendRequest(ctx, store.FriendRequest{
		ID: "f2", FromPub: peer, ToPub: bytes32(3), Direction: "in",
	}); err != nil {
		t.Fatal(err)
	}
	if n, err := dao.DeleteFriendRequest(ctx, self, "f2"); err != nil || n != 0 {
		t.Fatalf("不应删除他人好友申请: n=%d err=%v", n, err)
	}
	if n, err := dao.DeleteFriendRequest(ctx, self, "f1"); err != nil || n != 1 {
		t.Fatalf("删除好友申请失败: n=%d err=%v", n, err)
	}
	if n, err := dao.ClearFriendRequests(ctx, self); err != nil || n != 0 {
		t.Fatalf("清空好友申请结果错误: n=%d err=%v", n, err)
	}

	if err := dao.InsertGroupJoinRequest(ctx, store.GroupJoinRequest{
		ID: "j1", GroupID: "g1", Applicant: self, Direction: "out",
	}); err != nil {
		t.Fatal(err)
	}
	if err := dao.InsertGroupJoinRequest(ctx, store.GroupJoinRequest{
		ID: "j2", GroupID: "g1", Applicant: peer, Direction: "in",
	}); err != nil {
		t.Fatal(err)
	}
	if n, err := dao.DeleteGroupJoinRequest(ctx, self, "j1"); err != nil || n != 1 {
		t.Fatalf("删除自己的入群申请失败: n=%d err=%v", n, err)
	}
	if n, err := dao.ClearGroupJoinRequests(ctx, self); err != nil || n != 1 {
		t.Fatalf("清空入群申请应只删本机可见记录: n=%d err=%v", n, err)
	}

	for _, id := range []string{"n1", "n2"} {
		if err := dao.InsertNotification(ctx, store.Notification{ID: id, Kind: "test"}); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := dao.DeleteNotification(ctx, "n1"); err != nil || n != 1 {
		t.Fatalf("删除通知失败: n=%d err=%v", n, err)
	}
	if n, err := dao.ClearNotifications(ctx); err != nil || n != 1 {
		t.Fatalf("清空通知失败: n=%d err=%v", n, err)
	}
}

func TestDecodeAccountPub(t *testing.T) {
	raw := bytes32(41)
	cases := []string{
		hex.EncodeToString(raw),
		base64.RawURLEncoding.EncodeToString(raw),
	}
	for _, text := range cases {
		got, err := decodeAccountPub(text)
		if err != nil || !bytes.Equal(got, raw) {
			t.Fatalf("账号解码失败: text=%s err=%v got=%x", text, err, got)
		}
	}
	if _, err := decodeAccountPub("not-an-account"); err == nil {
		t.Fatal("非法账号应返回错误")
	}
}

func TestGroupJoinRequestWithBase64OwnerCarriesXPub(t *testing.T) {
	ctx := context.Background()
	dao := testDAO(t)
	applicant := bytes32(42)
	owner := bytes32(43)
	applicantXPub := bytes32(44)
	var sentPeer []byte
	var sent string

	svc, err := New(Options{
		DAO:  dao,
		Self: func() []byte { return applicant },
		XPub: func() []byte { return applicantXPub },
		Send: func(_ context.Context, peer []byte, text string) (string, error) {
			sentPeer = append([]byte(nil), peer...)
			sent = text
			return "join-msg", nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ownerText := base64.RawURLEncoding.EncodeToString(owner)
	if _, err := svc.RequestGroupJoin(ctx, "Z3JvdXA", "周末爬山", ownerText, "申请加入群聊"); err != nil {
		t.Fatalf("base64url 群主账号发起入群失败: %v", err)
	}
	if !bytes.Equal(sentPeer, owner) {
		t.Fatalf("入群申请目标错误: got=%x want=%x", sentPeer, owner)
	}
	frame, ok := Decode(sent)
	if !ok || frame.Kind != KindGroupJoinReq {
		t.Fatalf("入群申请控制帧非法: %+v", frame)
	}
	if frame.To != hex.EncodeToString(owner) {
		t.Fatalf("入群申请 To 应为 hex 群主: got=%s", frame.To)
	}
	if frame.GroupID != "Z3JvdXA" || frame.Extra["group_title"] != "周末爬山" {
		t.Fatalf("入群申请内容不符: %+v", frame)
	}
	if frame.Extra["xpub"] != hex.EncodeToString(applicantXPub) {
		t.Fatalf("入群申请未携带申请人 XPub: %+v", frame.Extra)
	}

	// 同一 DAO 已有 out 记录，改为入站 ID 避免主键冲突。
	frame.ID = "in-join"
	adminSvc, err := New(Options{DAO: dao, Self: func() []byte { return owner }})
	if err != nil {
		t.Fatal(err)
	}
	if err := adminSvc.HandleFrame(ctx, frame); err != nil {
		t.Fatalf("管理员处理入群申请失败: %v", err)
	}
	c, err := dao.GetContact(ctx, applicant)
	if err != nil || !bytes.Equal(c.AccountXPub, applicantXPub) {
		t.Fatalf("申请人 XPub 未缓存: %+v err=%v", c, err)
	}
}

func bytes32(n byte) []byte {
	b := make([]byte, 32)
	b[0] = n
	return b
}
