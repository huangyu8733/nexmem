// nexmem-backuptest 是 P6-05 的内核 CLI 验收程序：
// 写入联系人、历史消息、群与群密钥后导出加密备份，
// 再导入到全新库并逐项校验恢复结果，同时验证错误口令被拒绝。
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nexmem/core/internal/backup"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

func main() {
	dir := flag.String("dir", "", "工作目录，默认使用临时目录")
	pass := flag.String("pass", "nexmem-backup-cli", "备份口令")
	flag.Parse()

	if err := run(*dir, *pass); err != nil {
		fmt.Printf("RESULT=FAIL\nerror=%v\n", err)
		os.Exit(1)
	}
	fmt.Println("RESULT=PASS")
}

func run(dir, pass string) error {
	if dir == "" {
		var err error
		dir, err = os.MkdirTemp("", "nexmem-backup-*")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
	} else if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}

	ctx := context.Background()
	acc, err := identity.GenerateAccount()
	if err != nil {
		return fmt.Errorf("生成账号: %w", err)
	}

	srcDB, err := openDB(filepath.Join(dir, "source.db"))
	if err != nil {
		return err
	}
	defer srcDB.Close()
	if err := seed(ctx, store.NewDAO(srcDB)); err != nil {
		return err
	}

	path := filepath.Join(dir, "account.nexbak")
	manifest, err := backup.Export(ctx, backup.ExportOptions{
		DB:         srcDB,
		Account:    acc,
		Path:       path,
		Passphrase: []byte(pass),
	})
	if err != nil {
		return fmt.Errorf("导出备份: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("读取备份文件信息: %w", err)
	}
	fmt.Printf("BACKUP_PATH=%s\n", path)
	fmt.Printf("BACKUP_SIZE_BYTES=%d\n", info.Size())
	fmt.Printf("MANIFEST_MESSAGES=%d MANIFEST_CONVERSATIONS=%d MANIFEST_CONTACTS=%d MANIFEST_GROUPS=%d\n",
		manifest.Messages, manifest.Conversations, manifest.Contacts, manifest.Groups)

	dstDB, err := openDB(filepath.Join(dir, "restored.db"))
	if err != nil {
		return err
	}
	defer dstDB.Close()
	dstDAO := store.NewDAO(dstDB)

	res, err := backup.Import(ctx, backup.ImportOptions{
		DB:         dstDB,
		Path:       path,
		Passphrase: []byte(pass),
	})
	if err != nil {
		return fmt.Errorf("导入备份: %w", err)
	}
	if res.Account.ID() != acc.ID() {
		return fmt.Errorf("恢复账号 %s 与原始账号 %s 不一致", res.Account.ID(), acc.ID())
	}
	if err := verify(ctx, dstDAO); err != nil {
		return err
	}
	fmt.Println("RESTORE_CHECKS=contacts,conversations,messages,search,groups,group_keys,kv ALL_OK")

	wrongDB, err := openDB(filepath.Join(dir, "wrong.db"))
	if err != nil {
		return err
	}
	defer wrongDB.Close()
	if _, err := backup.Import(ctx, backup.ImportOptions{
		DB:         wrongDB,
		Path:       path,
		Passphrase: []byte("wrong-passphrase"),
	}); !errors.Is(err, backup.ErrDecrypt) {
		return fmt.Errorf("错误口令应被拒绝，实际 err=%v", err)
	}
	fmt.Println("WRONG_PASSPHRASE=REJECTED")
	return nil
}

func openDB(path string) (*sql.DB, error) {
	db, err := store.Open(path)
	if err != nil {
		return nil, fmt.Errorf("打开数据库 %s: %w", path, err)
	}
	if err := store.Migrate(context.Background(), db); err != nil {
		db.Close()
		return nil, fmt.Errorf("迁移数据库 %s: %w", path, err)
	}
	return db, nil
}

func seed(ctx context.Context, dao *store.DAO) error {
	peer := make([]byte, 32)
	peer[0], peer[1] = 0x51, 0x52
	if err := dao.UpsertContact(ctx, store.Contact{
		AccountPub: peer,
		Alias:      "验收好友",
		UpdatedAt:  1_700_000_000,
	}); err != nil {
		return fmt.Errorf("写入联系人: %w", err)
	}
	if err := dao.UpsertConversation(ctx, store.Conversation{
		ID:        "dm:acceptance",
		Kind:      store.ConversationKindDM,
		Title:     "验收好友",
		LastMsgAt: 1_700_000_100,
		Unread:    3,
	}); err != nil {
		return fmt.Errorf("写入会话: %w", err)
	}
	msgs := make([]store.Message, 0, 10)
	for i := 0; i < 10; i++ {
		body := fmt.Sprintf("验收历史消息 %02d：备份导入导出必须完整恢复", i)
		msgs = append(msgs, store.Message{
			MsgUUID:        fmt.Sprintf("acc-%02d", i),
			ConversationID: "dm:acceptance",
			SenderAccount:  peer,
			SentAt:         int64(1_700_000_100 + i),
			Direction:      store.DirectionIn,
			ContentType:    0,
			BodyEnc:        []byte(body),
			State:          store.MessageStateReceived,
			Body:           body,
		})
	}
	if err := dao.PutMessages(ctx, msgs); err != nil {
		return fmt.Errorf("写入消息: %w", err)
	}
	groupID := []byte{0x0a, 0x0b}
	if err := dao.PutGroup(ctx, store.Group{
		GroupID:     groupID,
		Title:       "验收群",
		MyRole:      1,
		KeyVersion:  3,
		GroupKeyEnc: []byte("sealed-group-key"),
	}); err != nil {
		return fmt.Errorf("写入群: %w", err)
	}
	if err := dao.PutGroupKey(ctx, groupID, 3, []byte("sealed-version-3")); err != nil {
		return fmt.Errorf("写入群密钥: %w", err)
	}
	if err := dao.SetKV(ctx, "device_name", []byte("acceptance")); err != nil {
		return fmt.Errorf("写入 KV: %w", err)
	}
	return nil
}

func verify(ctx context.Context, dao *store.DAO) error {
	contacts, err := dao.ListContacts(ctx, 10)
	if err != nil || len(contacts) != 1 || contacts[0].Alias != "验收好友" {
		return fmt.Errorf("联系人未恢复: %+v err=%v", contacts, err)
	}
	conv, err := dao.GetConversation(ctx, "dm:acceptance")
	if err != nil || conv.Unread != 3 {
		return fmt.Errorf("会话未恢复: %+v err=%v", conv, err)
	}
	count, err := dao.CountMessages(ctx, "dm:acceptance")
	if err != nil || count != 10 {
		return fmt.Errorf("消息未恢复: count=%d err=%v", count, err)
	}
	hits, err := dao.SearchMessages(ctx, store.MessageSearchQuery{Query: "备份导入导出必须完整恢复", Limit: 50})
	if err != nil || len(hits) != 10 {
		return fmt.Errorf("全文索引未恢复: hits=%d err=%v", len(hits), err)
	}
	groups, err := dao.ListGroups(ctx)
	if err != nil || len(groups) != 1 || groups[0].KeyVersion != 3 {
		return fmt.Errorf("群未恢复: %+v err=%v", groups, err)
	}
	keys, err := dao.ListGroupKeys(ctx, groups[0].GroupID)
	if err != nil || len(keys) != 1 {
		return fmt.Errorf("群密钥未恢复: %+v err=%v", keys, err)
	}
	if v, err := dao.GetKV(ctx, "device_name"); err != nil || string(v) != "acceptance" {
		return fmt.Errorf("KV 未恢复: %q err=%v", v, err)
	}
	return nil
}
