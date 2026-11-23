package backup

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/identity"
)

// Service 把备份能力接入网关的 backup.export / backup.import。
// DB 与 Account 以回调形式注入，便于 core.start 在启动前后切换实现。
type Service struct {
	DB      func() *sql.DB
	Account func() *identity.Account
	// OnRestoredAccount 在导入成功后把恢复出的账号写回本机 Keystore；
	// 为 nil 时只恢复数据，不切换身份（调用方应提示用户重启）。
	OnRestoredAccount func(*identity.Account) error
}

// Bind 把备份服务接入网关。
func Bind(g *gateway.Gateway, svc *Service) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if svc == nil {
		return errors.New("缺少备份服务")
	}
	handlers := map[string]gateway.HandlerFunc{
		"backup.export": exportHandler(svc),
		"backup.import": importHandler(svc),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

type request struct {
	PassphraseB64 string `json:"passphrase_b64"`
	Path          string `json:"path"`
}

func decodeRequest(method string, params json.RawMessage) (*request, []byte, *gateway.Error) {
	var req request
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, nil, gateway.NewError(gateway.CodeInvalidArg, "%s 参数不是合法 JSON: %v", method, err)
	}
	if strings.TrimSpace(req.Path) == "" {
		return nil, nil, gateway.NewError(gateway.CodeInvalidArg, "%s 缺少 path", method)
	}
	pass, err := decodePassphrase(req.PassphraseB64)
	if err != nil {
		return nil, nil, gateway.NewError(gateway.CodeInvalidArg, "%s 口令非法: %v", method, err)
	}
	return &req, pass, nil
}

func decodePassphrase(encoded string) ([]byte, error) {
	if encoded == "" {
		return nil, ErrPassphraseRequired
	}
	if raw, err := base64.StdEncoding.DecodeString(encoded); err == nil {
		return raw, nil
	}
	raw, err := base64.RawStdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, errors.New("需要标准 base64 编码")
	}
	return raw, nil
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func exportHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		req, pass, perr := decodeRequest("backup.export", params)
		if perr != nil {
			return nil, perr
		}
		defer zero(pass)
		db, account, err := svc.current()
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "%v", err)
		}
		if _, err := Export(ctx, ExportOptions{
			DB:         db,
			Account:    account,
			Path:       req.Path,
			Passphrase: pass,
		}); err != nil {
			return nil, mapError("导出备份失败", err)
		}
		return map[string]any{"path": req.Path}, nil
	}
}

func importHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		req, pass, perr := decodeRequest("backup.import", params)
		if perr != nil {
			return nil, perr
		}
		defer zero(pass)
		db, _, err := svc.current()
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "%v", err)
		}
		res, err := Import(ctx, ImportOptions{DB: db, Path: req.Path, Passphrase: pass})
		if err != nil {
			return nil, mapError("导入备份失败", err)
		}
		if svc.OnRestoredAccount != nil {
			if err := svc.OnRestoredAccount(res.Account); err != nil {
				return nil, gateway.NewError(gateway.CodeDBError, "恢复账号失败: %v", err)
			}
		}
		return map[string]any{}, nil
	}
}

func (s *Service) current() (*sql.DB, *identity.Account, error) {
	if s.DB == nil || s.Account == nil {
		return nil, nil, errors.New("备份能力尚未接入内核")
	}
	db := s.DB()
	account := s.Account()
	if db == nil || account == nil {
		return nil, nil, errors.New("备份能力尚未接入内核")
	}
	return db, account, nil
}

func mapError(prefix string, err error) *gateway.Error {
	switch {
	case errors.Is(err, ErrPassphraseRequired), errors.Is(err, ErrFormat):
		return gateway.NewError(gateway.CodeInvalidArg, "%s: %v", prefix, err)
	case errors.Is(err, ErrDecrypt):
		return gateway.NewError(gateway.CodeCryptoError, "%s: %v", prefix, err)
	default:
		return gateway.NewError(gateway.CodeDBError, "%s: %v", prefix, err)
	}
}
