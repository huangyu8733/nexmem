package backup

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

const testPassphrase = "correct horse battery staple"

func newTestStore(t *testing.T) (*sql.DB, *store.DAO) {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("打开内存库: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := store.Migrate(context.Background(), db); err != nil {
		t.Fatalf("迁移: %v", err)
	}
	return db, store.NewDAO(db)
}

func newTestAccount(t *testing.T) *identity.Account {
	t.Helper()
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	return acc
}

func seed(t *testing.T, dao *store.DAO, accountID string) {
	t.Helper()
	ctx := context.Background()
	peer := append([]byte(nil), make([]byte, 32)...)
	peer[0] = 0x42
	peer[1] = 0x43
	if err := dao.UpsertContact(ctx, store.Contact{
		AccountPub: peer,
		Alias:      "备份好友",
		Blocked:    false,
		UpdatedAt:  1700000000,
	}); err != nil {
		t.Fatalf("写入联系人: %v", err)
	}
	convID := "dm:peer"
	if err := dao.UpsertConversation(ctx, store.Conversation{
		ID:        convID,
		Kind:      store.ConversationKindDM,
		Title:     "备份好友",
		LastMsgAt: 1700000100,
		Unread:    2,
	}); err != nil {
		t.Fatalf("写入会话: %v", err)
	}
	for i, text := range []string{"备份消息一", "备份消息二"} {
		if err := dao.PutMessage(ctx, store.Message{
			MsgUUID:        "msg-" + string(rune('a'+i)),
			ConversationID: convID,
			SenderAccount:  peer,
			SentAt:         int64(1700000100 + i),
			Direction:      store.DirectionIn,
			ContentType:    0,
			BodyEnc:        []byte("cipher"),
			State:          store.MessageStateReceived,
			Body:           text,
		}); err != nil {
			t.Fatalf("写入消息: %v", err)
		}
	}
	groupID := []byte{0x01, 0x02, 0x03}
	if err := dao.PutGroup(ctx, store.Group{
		GroupID:     groupID,
		Title:       "备份群",
		MyRole:      1,
		KeyVersion:  2,
		GroupKeyEnc: []byte("group-key-enc"),
	}); err != nil {
		t.Fatalf("写入群: %v", err)
	}
	if err := dao.ReplaceMembers(ctx, groupID, []store.GroupMember{
		{GroupID: groupID, AccountPub: peer, Role: 0, JoinedAt: 1700000200},
	}); err != nil {
		t.Fatalf("写入群成员: %v", err)
	}
	if err := dao.PutGroupKey(ctx, groupID, 2, []byte("version-2-key")); err != nil {
		t.Fatalf("写入群密钥: %v", err)
	}
	if err := dao.SetKV(ctx, "last_login", []byte(accountID)); err != nil {
		t.Fatalf("写入 KV: %v", err)
	}
	if err := dao.PutCursor(ctx, store.InboxCursor{
		Scope:     "dm:" + accountID,
		ObjectKey: "im_offline/x/inbox/y.msg",
		SeenAt:    1700000300,
	}); err != nil {
		t.Fatalf("写入游标: %v", err)
	}
}

func TestExportImportRestoresEverything(t *testing.T) {
	ctx := context.Background()
	db, dao := newTestStore(t)
	acc := newTestAccount(t)
	seed(t, dao, acc.ID())

	path := filepath.Join(t.TempDir(), "backup.nexbak")
	manifest, err := Export(ctx, ExportOptions{
		DB:         db,
		Account:    acc,
		Path:       path,
		Passphrase: []byte(testPassphrase),
	})
	if err != nil {
		t.Fatalf("导出: %v", err)
	}
	if manifest.AccountID != acc.ID() {
		t.Fatalf("清单账号不一致: %s != %s", manifest.AccountID, acc.ID())
	}
	if manifest.Messages != 2 || manifest.Conversations != 1 || manifest.Contacts != 1 || manifest.Groups != 1 {
		t.Fatalf("清单统计错误: %+v", manifest)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("备份文件不存在: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("备份文件权限应为 0600，实际 %o", info.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取备份文件: %v", err)
	}
	for _, leak := range []string{"备份消息一", "备份好友", "group-key-enc", "account_ed25519_seed"} {
		if bytesContains(raw, []byte(leak)) {
			t.Fatalf("备份文件出现明文 %q", leak)
		}
	}

	_, dstDAO := newTestStore(t)
	res, err := Import(ctx, ImportOptions{
		DB:         dstDAO.DB(),
		Path:       path,
		Passphrase: []byte(testPassphrase),
	})
	if err != nil {
		t.Fatalf("导入: %v", err)
	}
	if res.Account.ID() != acc.ID() {
		t.Fatalf("恢复账号不一致: %s", res.Account.ID())
	}
	assertRestored(t, dstDAO, acc.ID())

	// 重复导入必须幂等。
	if _, err := Import(ctx, ImportOptions{
		DB:         dstDAO.DB(),
		Path:       path,
		Passphrase: []byte(testPassphrase),
	}); err != nil {
		t.Fatalf("重复导入: %v", err)
	}
	assertRestored(t, dstDAO, acc.ID())
	if n, err := dstDAO.CountMessages(ctx, "dm:peer"); err != nil || n != 2 {
		t.Fatalf("重复导入后消息数 %d, err=%v", n, err)
	}
}

func assertRestored(t *testing.T, dao *store.DAO, accountID string) {
	t.Helper()
	ctx := context.Background()
	contacts, err := dao.ListContacts(ctx, 10)
	if err != nil || len(contacts) != 1 || contacts[0].Alias != "备份好友" {
		t.Fatalf("联系人未恢复: %+v err=%v", contacts, err)
	}
	conv, err := dao.GetConversation(ctx, "dm:peer")
	if err != nil || conv.Unread != 2 || conv.LastMsgAt != 1700000100 {
		t.Fatalf("会话未恢复: %+v err=%v", conv, err)
	}
	msgs, err := dao.ListMessages(ctx, "dm:peer", nil, 10)
	if err != nil || len(msgs) != 2 {
		t.Fatalf("消息未恢复: %d err=%v", len(msgs), err)
	}
	hits, err := dao.SearchMessages(ctx, store.MessageSearchQuery{Query: "备份消息二", Limit: 5})
	if err != nil || len(hits) != 1 {
		t.Fatalf("全文索引未恢复: %+v err=%v", hits, err)
	}
	groups, err := dao.ListGroups(ctx)
	if err != nil || len(groups) != 1 || groups[0].KeyVersion != 2 {
		t.Fatalf("群未恢复: %+v err=%v", groups, err)
	}
	keys, err := dao.ListGroupKeys(ctx, groups[0].GroupID)
	if err != nil || len(keys) != 1 || keys[0].Version != 2 {
		t.Fatalf("群密钥未恢复: %+v err=%v", keys, err)
	}
	if v, err := dao.GetKV(ctx, "last_login"); err != nil || string(v) != accountID {
		t.Fatalf("KV 未恢复: %q err=%v", v, err)
	}
	if c, err := dao.GetCursor(ctx, "dm:"+accountID); err != nil || c.ObjectKey == "" {
		t.Fatalf("游标未恢复: %+v err=%v", c, err)
	}
}

func TestImportRejectsWrongPassphraseAndTampering(t *testing.T) {
	ctx := context.Background()
	db, dao := newTestStore(t)
	acc := newTestAccount(t)
	seed(t, dao, acc.ID())
	path := filepath.Join(t.TempDir(), "backup.nexbak")
	if _, err := Export(ctx, ExportOptions{
		DB: db, Account: acc, Path: path, Passphrase: []byte(testPassphrase),
	}); err != nil {
		t.Fatalf("导出: %v", err)
	}

	_, dstDAO := newTestStore(t)
	_, err := Import(ctx, ImportOptions{
		DB: dstDAO.DB(), Path: path, Passphrase: []byte("wrong-pass"),
	})
	if !errors.Is(err, ErrDecrypt) {
		t.Fatalf("错误口令应返回 ErrDecrypt，实际 %v", err)
	}
	if n, _ := dstDAO.CountMessages(ctx, "dm:peer"); n != 0 {
		t.Fatalf("失败导入不应写入数据，实际 %d 条", n)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取备份: %v", err)
	}
	raw[len(raw)-20] ^= 0xff
	tampered := filepath.Join(t.TempDir(), "tampered.nexbak")
	if err := os.WriteFile(tampered, raw, 0o600); err != nil {
		t.Fatalf("写入篡改文件: %v", err)
	}
	_, err = Import(ctx, ImportOptions{
		DB: dstDAO.DB(), Path: tampered, Passphrase: []byte(testPassphrase),
	})
	if !errors.Is(err, ErrDecrypt) && !errors.Is(err, ErrFormat) {
		t.Fatalf("篡改文件应被拒绝，实际 %v", err)
	}

	if _, err := Export(ctx, ExportOptions{
		DB: db, Account: acc, Path: path,
	}); !errors.Is(err, ErrPassphraseRequired) {
		t.Fatalf("空口令应返回 ErrPassphraseRequired，实际 %v", err)
	}
	if _, err := Import(ctx, ImportOptions{
		DB: dstDAO.DB(), Path: path,
	}); !errors.Is(err, ErrPassphraseRequired) {
		t.Fatalf("空口令导入应返回 ErrPassphraseRequired，实际 %v", err)
	}
}

func TestImportRejectsNonBackupFile(t *testing.T) {
	ctx := context.Background()
	_, dao := newTestStore(t)
	path := filepath.Join(t.TempDir(), "random.bin")
	if err := os.WriteFile(path, []byte("not a nexmem backup file"), 0o600); err != nil {
		t.Fatalf("写入文件: %v", err)
	}
	if _, err := Import(ctx, ImportOptions{
		DB: dao.DB(), Path: path, Passphrase: []byte(testPassphrase),
	}); !errors.Is(err, ErrFormat) {
		t.Fatalf("非备份文件应返回 ErrFormat，实际 %v", err)
	}
}

func TestGatewayBackupRoundTrip(t *testing.T) {
	ctx := context.Background()
	db, dao := newTestStore(t)
	acc := newTestAccount(t)
	seed(t, dao, acc.ID())

	gw := gateway.New()
	if err := Bind(gw, &Service{
		DB:      func() *sql.DB { return db },
		Account: func() *identity.Account { return acc },
	}); err != nil {
		t.Fatalf("绑定网关: %v", err)
	}

	path := filepath.Join(t.TempDir(), "gw.nexbak")
	pass := base64.StdEncoding.EncodeToString([]byte(testPassphrase))
	params, _ := json.Marshal(map[string]any{"path": path, "passphrase_b64": pass})
	data, gerr := gw.Handle(ctx, "backup.export", params)
	if gerr != nil {
		t.Fatalf("backup.export: %v", gerr)
	}
	if got, _ := data.(map[string]any)["path"].(string); got != path {
		t.Fatalf("导出路径回包错误: %v", data)
	}

	_, dstDAO := newTestStore(t)
	var restored *identity.Account
	gw2 := gateway.New()
	if err := Bind(gw2, &Service{
		DB:      func() *sql.DB { return dstDAO.DB() },
		Account: func() *identity.Account { return acc },
		OnRestoredAccount: func(a *identity.Account) error {
			restored = a
			return nil
		},
	}); err != nil {
		t.Fatalf("绑定网关: %v", err)
	}
	if _, gerr := gw2.Handle(ctx, "backup.import", params); gerr != nil {
		t.Fatalf("backup.import: %v", gerr)
	}
	if restored == nil || restored.ID() != acc.ID() {
		t.Fatalf("OnRestoredAccount 未拿到恢复账号")
	}
	assertRestored(t, dstDAO, acc.ID())

	// 口令错误应映射为 CRYPTO_ERROR。
	badPass := base64.StdEncoding.EncodeToString([]byte("nope"))
	badParams, _ := json.Marshal(map[string]any{"path": path, "passphrase_b64": badPass})
	if _, gerr := gw2.Handle(ctx, "backup.import", badParams); gerr == nil || gerr.Code != gateway.CodeCryptoError {
		t.Fatalf("错误口令应返回 CRYPTO_ERROR，实际 %v", gerr)
	}

	// 缺少口令字段属于参数错误。
	noPass, _ := json.Marshal(map[string]any{"path": path})
	if _, gerr := gw2.Handle(ctx, "backup.import", noPass); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少口令应返回 INVALID_ARG，实际 %v", gerr)
	}

	// 未接入内核时返回 NOT_STARTED。
	gw3 := gateway.New()
	if err := Bind(gw3, &Service{}); err != nil {
		t.Fatalf("绑定空服务: %v", err)
	}
	if _, gerr := gw3.Handle(ctx, "backup.export", params); gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未接入应返回 NOT_STARTED，实际 %v", gerr)
	}
}

func bytesContains(haystack, needle []byte) bool {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := range needle {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
