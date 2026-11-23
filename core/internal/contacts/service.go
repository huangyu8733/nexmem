// Package contacts 实现好友、黑名单与备注（P2-06）。
//
// 关系数据全部落在本机 contacts 表：备注（alias）与分组名只在本机生效，
// 不会写入任何上行报文，满足「备注仅本地可见」。
//
// 拉黑是双向隔离的本机一侧：拉黑方拒绝向该账号发送（dm 发送前检查），
// 同时拒绝该账号发来的消息（dm 受理入站前检查）。对端因此会收到 ACK 拒收，
// 表现为「双向不可发消息」，无需对端配合。
package contacts

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/nexmem/core/internal/store"
)

// 语义错误。
var (
	ErrInvalidPeer = errors.New("账号公钥非法")
	ErrEmptyPeer   = errors.New("账号公钥不能为空")
)

// Service 是联系人服务入口，并发安全（依赖 DAO 连接池）。
type Service struct {
	dao *store.DAO
	// now 可在测试中替换，保证 updated_at 可控。
	now func() time.Time
}

// New 基于已迁移的本地库创建联系人服务。
func New(dao *store.DAO) (*Service, error) {
	if dao == nil {
		return nil, errors.New("缺少本地 DAO")
	}
	return &Service{dao: dao, now: time.Now}, nil
}

// Add 添加好友（已存在时保持原备注与拉黑状态不变）。
func (s *Service) Add(ctx context.Context, peer []byte) (*store.Contact, error) {
	pub, err := normalizePeer(peer)
	if err != nil {
		return nil, err
	}
	if err := s.dao.EnsureContact(ctx, pub, s.now().Unix()); err != nil {
		return nil, err
	}
	return s.dao.GetContact(ctx, pub)
}

// AddWithAlias 添加好友并写入本地备注；已存在时更新备注，保留拉黑状态。
func (s *Service) AddWithAlias(ctx context.Context, peer []byte, alias string) (*store.Contact, error) {
	pub, err := normalizePeer(peer)
	if err != nil {
		return nil, err
	}
	at := s.now().Unix()
	if err := s.dao.EnsureContact(ctx, pub, at); err != nil {
		return nil, err
	}
	if err := s.dao.SetContactAlias(ctx, pub, strings.TrimSpace(alias), at); err != nil {
		return nil, err
	}
	return s.dao.GetContact(ctx, pub)
}

// List 按最近更新倒序返回联系人。
func (s *Service) List(ctx context.Context, limit int) ([]store.Contact, error) {
	return s.dao.ListContacts(ctx, limit)
}

// Get 按账号公钥读取联系人。
func (s *Service) Get(ctx context.Context, peer []byte) (*store.Contact, error) {
	pub, err := normalizePeer(peer)
	if err != nil {
		return nil, err
	}
	return s.dao.GetContact(ctx, pub)
}

// Remark 设置本地备注名；空字符串表示清除备注。
func (s *Service) Remark(ctx context.Context, peer []byte, alias string) error {
	pub, err := normalizePeer(peer)
	if err != nil {
		return err
	}
	return s.dao.SetContactAlias(ctx, pub, strings.TrimSpace(alias), s.now().Unix())
}

// SetBlocked 设置或取消拉黑。
func (s *Service) SetBlocked(ctx context.Context, peer []byte, blocked bool) error {
	pub, err := normalizePeer(peer)
	if err != nil {
		return err
	}
	return s.dao.SetContactBlocked(ctx, pub, blocked, s.now().Unix())
}

// Remove 删除联系人记录（同时清除备注与拉黑状态）。
func (s *Service) Remove(ctx context.Context, peer []byte) error {
	pub, err := normalizePeer(peer)
	if err != nil {
		return err
	}
	return s.dao.DeleteContact(ctx, pub)
}

// IsBlocked 实现 dm.Blocklist：报告本机是否拉黑了该账号。
func (s *Service) IsBlocked(ctx context.Context, peer []byte) (bool, error) {
	if len(peer) != ed25519.PublicKeySize {
		return false, ErrInvalidPeer
	}
	return s.dao.IsContactBlocked(ctx, peer)
}

func normalizePeer(peer []byte) ([]byte, error) {
	if len(peer) == 0 {
		return nil, ErrEmptyPeer
	}
	if len(peer) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: 长度 %d", ErrInvalidPeer, len(peer))
	}
	out := make([]byte, len(peer))
	copy(out, peer)
	return out, nil
}
