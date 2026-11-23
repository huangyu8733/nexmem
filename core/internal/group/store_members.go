package group

import (
	"context"
	"fmt"

	"github.com/nexmem/core/internal/store"
)

// StoreMembers 用本地 SQLite 的 group_members 表实现 MemberSource。
type StoreMembers struct {
	DAO *store.DAO
}

// Members 返回群成员账号公钥列表。
func (m StoreMembers) Members(ctx context.Context, groupID []byte) ([][]byte, error) {
	if m.DAO == nil {
		return nil, fmt.Errorf("群成员来源缺少 DAO")
	}
	rows, err := m.DAO.ListMembers(ctx, groupID)
	if err != nil {
		return nil, err
	}
	out := make([][]byte, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.AccountPub)
	}
	return out, nil
}
