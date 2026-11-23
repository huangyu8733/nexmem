package contacts

// 好友分组（P6-30）。
//
// 分组名是纯本机元数据：只写入本机 contacts.group_name，不上行、不同步给任何人，
// 用于把好友归入自定义分组（需求 §3.2「好友分组…均保存在本机 SQLite 数据库中」）。

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"
)

// MaxContactGroupRunes 是好友分组名允许的最大 UTF-8 字符数。
const MaxContactGroupRunes = 32

// ErrGroupTooLong 表示好友分组名超过长度上限。
var ErrGroupTooLong = errors.New("好友分组名最多 32 字")

// ValidateContactGroup 校验好友分组名字符数；空串表示清除，合法。
func ValidateContactGroup(name string) error {
	if utf8.RuneCountInString(name) > MaxContactGroupRunes {
		return ErrGroupTooLong
	}
	return nil
}

// SetGroup 设置或清除本机好友分组名（空串表示清除），返回保存后的分组名。
func (s *Service) SetGroup(ctx context.Context, peer []byte, name string) (string, error) {
	pub, err := normalizePeer(peer)
	if err != nil {
		return "", err
	}
	name = strings.TrimSpace(name)
	if err := ValidateContactGroup(name); err != nil {
		return "", err
	}
	if err := s.dao.SetContactGroup(ctx, pub, name, s.now().Unix()); err != nil {
		return "", err
	}
	return name, nil
}
