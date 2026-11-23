package dm

import (
	"context"
	"fmt"
)

// isBlocked 查询本机黑名单（P2-06）；未注入 Blocklist 时一律视为未拉黑。
func (s *Service) isBlocked(ctx context.Context, accountPub []byte) (bool, error) {
	if s.blocklist == nil {
		return false, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	blocked, err := s.blocklist.IsBlocked(ctx, accountPub)
	if err != nil {
		return false, fmt.Errorf("查询黑名单: %w", err)
	}
	return blocked, nil
}
