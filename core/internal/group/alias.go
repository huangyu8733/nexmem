package group

// 群备注（P6-27）。
//
// 备注是纯本机元数据：只写入本机 groups.alias，不上行、不广播、不同步给其他成员，
// 用于把群名替换成自己更容易识别的称呼（需求 §3.2「群备注保存在本机 SQLite」）。

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/nexmem/core/internal/store"
)

// MaxGroupAliasRunes 是群备注允许的最大 UTF-8 字符数。
const MaxGroupAliasRunes = 32

// ErrAliasTooLong 表示群备注超过长度上限。
var ErrAliasTooLong = errors.New("群备注最多 32 字")

// ValidateGroupAlias 校验群备注字符数；空串表示清除，合法。
func ValidateGroupAlias(alias string) error {
	if utf8.RuneCountInString(alias) > MaxGroupAliasRunes {
		return ErrAliasTooLong
	}
	return nil
}

// SetAlias 设置或清除本机群备注（空串表示清除），返回保存后的备注。
func (s *Service) SetAlias(ctx context.Context, groupID []byte, alias string) (string, error) {
	if len(groupID) == 0 {
		return "", ErrGroupIDRequired
	}
	alias = strings.TrimSpace(alias)
	if err := ValidateGroupAlias(alias); err != nil {
		return "", err
	}
	if s.dao == nil {
		return "", errors.New("缺少本地 DAO，无法保存群备注")
	}
	if err := s.dao.SetGroupAlias(ctx, groupID, alias); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return "", ErrGroupKeyNotFound
		}
		return "", err
	}
	return alias, nil
}
