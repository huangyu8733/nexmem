package fs

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"

	filecrypto "github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

const (
	shareKVKey      = "fs.shares"
	defaultParallel = 4
)

var (
	ErrInvalidPath  = errors.New("共享路径不可读或不是目录/文件")
	ErrNoSeeds      = errors.New("没有可用的共享种子")
	ErrNotStarted   = errors.New("文件共享服务尚未接入内核")
	ErrDownloadDone = errors.New("共享已下载完成")
)

// Progress 是一次下载的进度快照，映射到 fs.progress 事件。
type Progress struct {
	ShareID string
	Path    string
	Done    int64
	Total   int64
}

// ShareRecord 是本机保存的一条共享：Manifest 为签名清单，LocalRoot 非空表示
// 本机持有实际文件、可以作为种子；Kind 为 published / downloaded / imported。
type ShareRecord struct {
	Manifest  *Manifest `json:"manifest"`
	LocalRoot string    `json:"local_root,omitempty"`
	Kind      string    `json:"kind"`
	Seeds     []Seed    `json:"seeds,omitempty"`
	CreatedAt int64     `json:"created_at"`
}

// Options 是 Service 的构造参数。
type Options struct {
	Host      host.Host
	DeviceKey crypto.PrivKey
	DAO       *store.DAO
	Account   *identity.Account
	// OnProgress 上报下载进度，回调可能来自任意协程。
	OnProgress func(Progress)
	// ConnectSeed 连接种子地址；未注入时使用 host.Connect。
	ConnectSeed func(ctx context.Context, info peer.AddrInfo) error
	// seedAddr 把共享种子的 PeerID 与地址解析出来（由上层注入发现能力）。
	ResolveSeed func(ctx context.Context, accountID string) (Seed, error)
	// SendShare 把分享码作为聊天消息发给指定账号（由上层注入 dm 能力）。
	SendShare func(ctx context.Context, accountID, code string) (string, error)
	// DisableAutoSeed 关闭「下载完成后本机自动做种」；默认开启。
	DisableAutoSeed bool
}

// Service 管理本地共享与 P2P 下载。
type Service struct {
	host        host.Host
	deviceKey   crypto.PrivKey
	dao         *store.DAO
	account     *identity.Account
	onProgress  func(Progress)
	connectSeed func(ctx context.Context, info peer.AddrInfo) error
	resolveSeed func(ctx context.Context, accountID string) (Seed, error)
	sendShare   func(ctx context.Context, accountID, code string) (string, error)
	autoSeed    bool

	mu       sync.RWMutex
	shares   map[string]*ShareRecord
	download map[string]*downloadState
}

type downloadState struct {
	done     int64
	total    int64
	lastEmit time.Time
}

func New(opt Options) (*Service, error) {
	switch {
	case opt.Host == nil:
		return nil, errors.New("缺少 libp2p host")
	case opt.DeviceKey == nil:
		return nil, errors.New("缺少设备私钥")
	case opt.DAO == nil:
		return nil, errors.New("缺少本地 DAO")
	case opt.Account == nil:
		return nil, errors.New("缺少账号密钥")
	}
	autoSeed := !opt.DisableAutoSeed
	s := &Service{
		host:        opt.Host,
		deviceKey:   opt.DeviceKey,
		dao:         opt.DAO,
		account:     opt.Account,
		onProgress:  opt.OnProgress,
		resolveSeed: opt.ResolveSeed,
		sendShare:   opt.SendShare,
		autoSeed:    autoSeed,
		shares:      make(map[string]*ShareRecord),
		download:    make(map[string]*downloadState),
	}
	s.connectSeed = opt.ConnectSeed
	if s.connectSeed == nil {
		s.connectSeed = func(ctx context.Context, info peer.AddrInfo) error {
			return s.host.Connect(ctx, info)
		}
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	s.host.SetStreamHandler(wire.PIDFs, s.handleStream)
	return s, nil
}

// Close 注销流处理器并等待在途传输收尾（由上层 ctx 控制，这里只做注销）。
func (s *Service) Close() {
	if s.host != nil {
		s.host.RemoveStreamHandler(wire.PIDFs)
	}
}

func (s *Service) load() error {
	raw, err := s.dao.GetKV(context.Background(), shareKVKey)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		return err
	}
	var recs []*ShareRecord
	if err := json.Unmarshal(raw, &recs); err != nil {
		return fmt.Errorf("解析共享存储: %w", err)
	}
	for _, rec := range recs {
		if rec != nil && rec.Manifest != nil && rec.Manifest.ID != "" {
			s.shares[rec.Manifest.ID] = rec
		}
	}
	return nil
}

func (s *Service) saveLocked() error {
	recs := make([]*ShareRecord, 0, len(s.shares))
	for _, rec := range s.shares {
		recs = append(recs, rec)
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].Manifest.ID < recs[j].Manifest.ID })
	data, err := json.Marshal(recs)
	if err != nil {
		return err
	}
	return s.dao.SetKV(context.Background(), shareKVKey, data)
}

// localSeeds 返回本机对外公布的地址。
func (s *Service) localSeeds() []Seed {
	pid := s.host.ID().String()
	addrs := make([]string, 0, len(s.host.Addrs()))
	for _, a := range s.host.Addrs() {
		addrs = append(addrs, a.String())
	}
	return []Seed{{PeerID: pid, Addrs: addrs}}
}

// Publish 把本地目录或单个文件发布为共享，返回分享码。
func (s *Service) Publish(ctx context.Context, path, name string) (*ShareRecord, string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	m := &Manifest{Name: name, CreatedAt: time.Now().UnixMilli()}
	var files []FileEntry
	if info.IsDir() {
		m.Root = filepath.Base(abs)
		err = filepath.WalkDir(abs, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !d.Type().IsRegular() {
				return nil
			}
			return s.appendFile(&files, abs, p)
		})
	} else {
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return nil, "", ErrInvalidPath
		}
		err = s.appendFile(&files, filepath.Dir(abs), abs)
	}
	if err != nil {
		return nil, "", err
	}
	if len(files) == 0 {
		return nil, "", fmt.Errorf("%w: 目录为空", ErrInvalidPath)
	}
	m.Files = files
	for _, f := range files {
		m.TotalSize += f.Size
	}
	if m.Name == "" {
		m.Name = m.Root
		if m.Name == "" && len(files) == 1 {
			m.Name = filepath.Base(files[0].Path)
		}
	}
	if err := m.Sign(s.account); err != nil {
		return nil, "", err
	}
	rec := &ShareRecord{Manifest: m, LocalRoot: abs, Kind: "published", CreatedAt: m.CreatedAt}
	code, err := EncodeCode(m, s.localSeeds())
	if err != nil {
		return nil, "", err
	}
	s.mu.Lock()
	prev, existed := s.shares[m.ID]
	s.shares[m.ID] = rec
	err = s.saveLocked()
	s.mu.Unlock()
	if err != nil {
		if existed {
			s.shares[m.ID] = prev
		} else {
			delete(s.shares, m.ID)
		}
		return nil, "", err
	}
	return rec, code, nil
}

func (s *Service) appendFile(out *[]FileEntry, root, p string) error {
	rel, err := filepath.Rel(root, p)
	if err != nil || !safeRelativePath(filepath.ToSlash(rel)) {
		return fmt.Errorf("%w: %s", ErrPathUnsafe, p)
	}
	sum, err := hashOfFile(p)
	if err != nil {
		return err
	}
	// 密钥由内容摘要确定性派生：不同节点发布同一份内容会得到相同清单 ID，
	// 从而可以互为种子；密钥仍只在持有清单的人之间共享。
	key := contentKey(sum)
	st, err := os.Stat(p)
	if err != nil || st.Size() <= 0 {
		return ErrInvalidPath
	}
	*out = append(*out, FileEntry{
		Path:   filepath.ToSlash(rel),
		Size:   st.Size(),
		SHA256: fmt.Sprintf("%x", sum),
		Key:    base64.StdEncoding.EncodeToString(key),
		MIME:   mimeOf(p),
	})
	return nil
}

// List 返回本机全部共享摘要。
func (s *Service) List() []ShareRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]ShareRecord, 0, len(s.shares))
	for _, rec := range s.shares {
		copyRec := *rec
		copyRec.Manifest = rec.Manifest
		out = append(out, copyRec)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out
}

// Get 返回单条共享及其分享码。
func (s *Service) Get(id string) (*ShareRecord, string, error) {
	s.mu.RLock()
	rec, ok := s.shares[id]
	s.mu.RUnlock()
	if !ok || rec.Manifest == nil {
		return nil, "", ErrNotFound
	}
	seeds := rec.Seeds
	if len(seeds) == 0 {
		seeds = s.localSeeds()
	}
	code, err := EncodeCode(rec.Manifest, seeds)
	if err != nil {
		return nil, "", err
	}
	copyRec := *rec
	return &copyRec, code, nil
}

// Import 解析分享码并保存远端清单（不下载）。
func (s *Service) Import(ctx context.Context, code string) (*ShareRecord, error) {
	m, seeds, err := DecodeCode(code)
	if err != nil {
		return nil, err
	}
	if _, err := m.Verify(); err != nil {
		return nil, err
	}
	// 种子失联时尝试通过上层发现能力刷新地址。
	if len(seeds) == 0 && s.resolveSeed != nil {
		if seed, err := s.resolveSeed(ctx, m.Owner); err == nil {
			seeds = []Seed{seed}
		}
	}
	rec := &ShareRecord{Manifest: m, Kind: "imported", Seeds: seeds, CreatedAt: m.CreatedAt}
	s.mu.Lock()
	s.shares[m.ID] = rec
	err = s.saveLocked()
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return rec, nil
}

// Share 把分享码作为聊天消息发给指定账号。
func (s *Service) Share(ctx context.Context, id, accountID string) (string, error) {
	if s.sendShare == nil {
		return "", errors.New("当前内核未接入聊天发送能力")
	}
	_, code, err := s.Get(id)
	if err != nil {
		return "", err
	}
	return s.sendShare(ctx, accountID, code)
}

// Remove 删除本机共享记录（不删除实际文件）。
func (s *Service) Remove(id string) error {
	s.mu.Lock()
	_, ok := s.shares[id]
	if ok {
		delete(s.shares, id)
	}
	err := s.saveLocked()
	s.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	return err
}

// Download 从种子并行拉取共享到 dest 目录。同一文件按分片在多协程与各种子间
// 分发，完成后做整文件 SHA-256 校验；本机默认自动成为该共享的新种子。
func (s *Service) Download(ctx context.Context, id, dest string, seeds []Seed, parallel int) (*ShareRecord, error) {
	s.mu.RLock()
	rec, ok := s.shares[id]
	s.mu.RUnlock()
	if !ok || rec.Manifest == nil {
		return nil, ErrNotFound
	}
	if rec.LocalRoot != "" {
		return nil, ErrDownloadDone
	}
	m := rec.Manifest
	if len(seeds) == 0 {
		seeds = rec.Seeds
	}
	if len(seeds) == 0 && s.resolveSeed != nil {
		if seed, err := s.resolveSeed(ctx, m.Owner); err == nil {
			seeds = []Seed{seed}
		}
	}
	if len(seeds) == 0 {
		return nil, ErrNoSeeds
	}
	if parallel <= 0 {
		parallel = defaultParallel
	}

	var total int64
	for _, f := range m.Files {
		total += f.Size
	}
	state := &downloadState{total: total}
	s.mu.Lock()
	s.download[id] = state
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.download, id)
		s.mu.Unlock()
	}()

	// 连接种子，建立多条独立流；每条流会从种子重新拉取并校验清单，
	// 避免依赖本地可能被篡改的清单。
	sessions := make([]*seedSession, 0, len(seeds))
	var verified *Manifest
	for _, seed := range seeds {
		pid, err := peer.Decode(seed.PeerID)
		if err != nil {
			continue
		}
		ss, remoteManifest, err := s.openSeedSession(ctx, pid, seed.Addrs, id)
		if err != nil {
			continue
		}
		sessions = append(sessions, ss)
		if verified == nil {
			verified = remoteManifest
		}
	}
	if len(sessions) == 0 || verified == nil {
		return nil, ErrNoSeeds
	}
	defer func() {
		for _, ss := range sessions {
			_ = ss.stream.Close()
		}
	}()
	m = verified

	absDest, err := filepath.Abs(dest)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(absDest, 0o755); err != nil {
		return nil, err
	}
	var done atomic.Int64
	err = s.downloadFiles(ctx, m, absDest, sessions, parallel, &done, state)
	if err != nil {
		return nil, err
	}
	if s.autoSeed {
		newRec := &ShareRecord{Manifest: m, LocalRoot: absDest, Kind: "downloaded", Seeds: seeds, CreatedAt: time.Now().UnixMilli()}
		s.mu.Lock()
		s.shares[m.ID] = newRec
		err = s.saveLocked()
		s.mu.Unlock()
		if err != nil {
			return nil, err
		}
		return newRec, nil
	}
	return rec, nil
}

type chunkTask struct {
	file  FileEntry
	index uint32
	size  int64
}

func (s *Service) downloadFiles(ctx context.Context, m *Manifest, dest string, sessions []*seedSession, parallel int, done *atomic.Int64, state *downloadState) error {
	// 先展开任务队列，再并发处理，保证所有文件都被写满。
	var tasks []chunkTask
	for _, f := range m.Files {
		total := (f.Size + fsChunkSize - 1) / fsChunkSize
		for i := int64(0); i < total; i++ {
			tasks = append(tasks, chunkTask{file: f, index: uint32(i), size: min64(fsChunkSize, f.Size-i*fsChunkSize)})
		}
	}
	// 按文件与分片排序，配合 .part 文件支持断点续传。
	sort.Slice(tasks, func(i, j int) bool {
		if tasks[i].file.Path != tasks[j].file.Path {
			return tasks[i].file.Path < tasks[j].file.Path
		}
		return tasks[i].index < tasks[j].index
	})

	keyCache := make(map[string][]byte, len(m.Files))
	for _, f := range m.Files {
		key, err := base64.StdEncoding.DecodeString(f.Key)
		if err != nil {
			return err
		}
		keyCache[f.Path] = key
	}

	var taskMu sync.Mutex
	next := 0
	var firstErr atomic.Value
	var wg sync.WaitGroup
	worker := func(workerIdx int) {
		defer wg.Done()
		sess := sessions[workerIdx%len(sessions)]
		for {
			select {
			case <-ctx.Done():
				firstErr.CompareAndSwap(nil, ctx.Err())
				return
			default:
			}
			taskMu.Lock()
			if next >= len(tasks) {
				taskMu.Unlock()
				return
			}
			task := tasks[next]
			next++
			taskMu.Unlock()

			plain, err := sess.fetchChunk(m, task.file.Path, task.index, keyCache[task.file.Path])
			if err != nil {
				// 换一个种子重试一次，提升弱网下的成功率。
				alt := sessions[(workerIdx+1)%len(sessions)]
				if alt != sess {
					plain, err = alt.fetchChunk(m, task.file.Path, task.index, keyCache[task.file.Path])
				}
			}
			if err != nil {
				firstErr.CompareAndSwap(nil, err)
				return
			}
			off := int64(task.index) * fsChunkSize
			if err := writePart(dest, task.file.Path, off, plain, task.file.Size); err != nil {
				firstErr.CompareAndSwap(nil, err)
				return
			}
			n := done.Add(int64(len(plain)))
			s.emitProgress(ctx, m.ID, task.file.Path, n, state.total, state)
		}
	}
	for i := 0; i < parallel && i < len(tasks); i++ {
		wg.Add(1)
		go worker(i)
	}
	wg.Wait()
	if v := firstErr.Load(); v != nil {
		return v.(error)
	}
	// 汇总校验并原子改名为最终文件。
	for _, f := range m.Files {
		part := partPath(dest, f.Path)
		sum, err := hashOfFile(part)
		if err != nil {
			return err
		}
		if fmt.Sprintf("%x", sum) != f.SHA256 {
			return fmt.Errorf("%w: %s", ErrChunkMismatch, f.Path)
		}
		final := filepath.Join(dest, filepath.FromSlash(f.Path))
		if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
			return err
		}
		if err := os.Rename(part, final); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) emitProgress(ctx context.Context, id, path string, done, total int64, state *downloadState) {
	if s.onProgress == nil || total <= 0 {
		return
	}
	now := time.Now()
	if done < total && now.Sub(state.lastEmit) < 200*time.Millisecond {
		return
	}
	state.lastEmit = now
	s.onProgress(Progress{ShareID: id, Path: path, Done: done, Total: total})
}

func parseAddrs(raw []string) ([]multiaddr.Multiaddr, error) {
	out := make([]multiaddr.Multiaddr, 0, len(raw))
	for _, s := range raw {
		a, err := multiaddr.NewMultiaddr(s)
		if err != nil {
			continue
		}
		out = append(out, a)
	}
	return out, nil
}

func partPath(dest, rel string) string {
	return filepath.Join(dest, ".nexmem-part-"+strings.ReplaceAll(rel, "/", "_"))
}

func writePart(dest, rel string, off int64, data []byte, total int64) error {
	path := partPath(dest, rel)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteAt(data, off); err != nil {
		return err
	}
	if off+int64(len(data)) >= total {
		return f.Truncate(total)
	}
	return nil
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// contentKey 由文件内容摘要确定性派生 AES-256 密钥，保证内容寻址稳定。
func contentKey(sum []byte) []byte {
	key := make([]byte, filecrypto.FileKeySize)
	copy(key, sum)
	return key
}

func mimeOf(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".txt", ".md", ".log":
		return "text/plain"
	case ".json":
		return "application/json"
	case ".pdf":
		return "application/pdf"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".zip":
		return "application/zip"
	default:
		return "application/octet-stream"
	}
}
