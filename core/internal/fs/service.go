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
	// maxParallel 防止调用方传入超大并发把本机与种子节点打满。
	maxParallel = 32
	// partsDir 是下载临时分片的隐藏目录，按共享内相对路径原样存放，避免路径压平碰撞。
	partsDir = ".nexmem-parts"
	// partsMarker 记录当前分片属于哪份清单；清单变更时丢弃旧分片，否则续传。
	partsMarker = ".nexmem-manifest"
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
	// leases 按 share_id 串行化同一共享的下载，避免并发下载争抢 .part 文件。
	leases map[string]*sync.Mutex
}

type downloadState struct {
	total    int64
	lastEmit time.Time
	mu       sync.Mutex
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
		leases:      make(map[string]*sync.Mutex),
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

// shareLease 返回同一 share_id 的下载互斥锁。锁表本身由 s.mu 保护，
// 调用方拿到锁后方可进入下载流程；表项长期保留，数量随共享数线性增长且体积极小。
func (s *Service) shareLease(id string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	lease, ok := s.leases[id]
	if !ok {
		lease = &sync.Mutex{}
		s.leases[id] = lease
	}
	return lease
}

// mergeSeeds 按 PeerID 合并种子并补齐地址，靠前的分组优先（发现服务刷新的新地址优先）。
func mergeSeeds(groups ...[]Seed) []Seed {
	out := make([]Seed, 0)
	index := make(map[string]int)
	for _, group := range groups {
		for _, seed := range group {
			if seed.PeerID == "" {
				continue
			}
			pos, ok := index[seed.PeerID]
			if !ok {
				index[seed.PeerID] = len(out)
				out = append(out, seed)
				continue
			}
			seen := make(map[string]bool, len(out[pos].Addrs))
			for _, addr := range out[pos].Addrs {
				seen[addr] = true
			}
			for _, addr := range seed.Addrs {
				if !seen[addr] {
					seen[addr] = true
					out[pos].Addrs = append(out[pos].Addrs, addr)
				}
			}
		}
	}
	return out
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
	// 只有本机真正持有文件时才把自己写进分享码；否则会把未下载的共享
	// 伪装成种子，导致接收方连上来拿不到清单。
	if len(seeds) == 0 && rec.LocalRoot != "" {
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
	// 分享码里的地址可能已经失效：只要接入了发现能力就刷新一次，并把新地址排在前面。
	if s.resolveSeed != nil {
		if seed, err := s.resolveSeed(ctx, m.Owner); err == nil {
			seeds = mergeSeeds([]Seed{seed}, seeds)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// 同一内容可由不同账号发布并得到相同 ID。若本机已持有该文件（发布或下载完成），
	// 导入分享码不能覆盖 LocalRoot，否则本机会丢失做种能力。
	if prev, ok := s.shares[m.ID]; ok {
		if prev.LocalRoot != "" {
			prev.Seeds = mergeSeeds(prev.Seeds, seeds)
			if err := s.saveLocked(); err != nil {
				return nil, err
			}
			copyRec := *prev
			return &copyRec, nil
		}
		if prev.Kind == "imported" {
			prev.Seeds = mergeSeeds(seeds, prev.Seeds)
			prev.Manifest = m
			if err := s.saveLocked(); err != nil {
				return nil, err
			}
			copyRec := *prev
			return &copyRec, nil
		}
	}
	rec := &ShareRecord{Manifest: m, Kind: "imported", Seeds: seeds, CreatedAt: m.CreatedAt}
	s.shares[m.ID] = rec
	if err := s.saveLocked(); err != nil {
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
	// 同一共享串行下载：并发请求要么复用已下载结果，要么等待后拿到 ErrDownloadDone，
	// 否则多个协程会同时写同一批 .part 文件并互相截断。
	lease := s.shareLease(id)
	lease.Lock()
	defer lease.Unlock()

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
	if parallel > maxParallel {
		parallel = maxParallel
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
	// 避免依赖本地可能被篡改的清单。清单的 Owner 必须与导入时一致：
	// 相同内容可由不同账号发布并得到相同 ID，但不能让任意种子偷换发布者。
	sessions, verified, seedErr := s.openSessions(ctx, seeds, id, m.Owner)
	if len(sessions) == 0 || verified == nil {
		// 已知种子全部失联：通过上层发现能力刷新地址后再试一次。
		if s.resolveSeed != nil {
			if seed, err := s.resolveSeed(ctx, m.Owner); err == nil && seed.PeerID != "" {
				sessions, verified, seedErr = s.openSessions(ctx, []Seed{seed}, id, m.Owner)
			}
		}
	}
	if len(sessions) == 0 || verified == nil {
		return nil, fmt.Errorf("%w: %v", ErrNoSeeds, seedErr)
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
	// 同清单的半成品分片保留续传；清单变了才清空，避免新旧内容混淆。
	resumed, err := prepareParts(absDest, m)
	if err != nil {
		return nil, err
	}
	var done atomic.Int64
	done.Add(resumed)
	succeeded := false
	defer func() {
		if succeeded {
			// 全部校验并改名完成后不再需要临时目录。
			_ = os.RemoveAll(filepath.Join(absDest, partsDir))
		}
		// 失败保留 partsDir，下次同清单下载可以从已完成的分片继续。
	}()
	err = s.downloadFiles(ctx, m, absDest, sessions, parallel, &done, state)
	if err != nil {
		return nil, err
	}
	if s.autoSeed {
		newRec := &ShareRecord{Manifest: m, LocalRoot: absDest, Kind: "downloaded", Seeds: mergeSeeds(seeds), CreatedAt: time.Now().UnixMilli()}
		s.mu.Lock()
		s.shares[m.ID] = newRec
		err = s.saveLocked()
		s.mu.Unlock()
		if err != nil {
			return nil, err
		}
		succeeded = true
		return newRec, nil
	}
	succeeded = true
	return rec, nil
}

// openSessions 逐个连接种子并校验其清单；只有 ID 与 Owner 都匹配本机的清单才采纳。
// 全部失败时返回首个具体原因，避免只报「没有可用的共享种子」掩盖真实故障。
func (s *Service) openSessions(ctx context.Context, seeds []Seed, shareID, owner string) ([]*seedSession, *Manifest, error) {
	sessions := make([]*seedSession, 0, len(seeds))
	var verified *Manifest
	var firstErr error
	for _, seed := range seeds {
		pid, err := peer.Decode(seed.PeerID)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		ss, remoteManifest, err := s.openSeedSession(ctx, pid, seed.Addrs, shareID, owner)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		sessions = append(sessions, ss)
		if verified == nil {
			verified = remoteManifest
		}
	}
	if len(sessions) == 0 || verified == nil {
		if firstErr == nil {
			firstErr = ErrNoSeeds
		}
		return nil, nil, firstErr
	}
	return sessions, verified, nil
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
			// 已完成分片由 prepareParts 计入 done，这里不再重复请求。
			if partDone(dest, f.Path, uint32(i)) {
				continue
			}
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
			// 先落分片再打完成标记，避免中断后把未写满的分片当成已完成。
			if err := markPartDone(dest, task.file.Path, task.index); err != nil {
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
	// 多个下载协程会同时调用这里，节流时间戳必须加锁，且回调不能在锁内执行。
	state.mu.Lock()
	if done < total && now.Sub(state.lastEmit) < 200*time.Millisecond {
		state.mu.Unlock()
		return
	}
	state.lastEmit = now
	state.mu.Unlock()
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

// partPath 保留共享内的目录层级，避免 a/b 与 a_b 这类路径被压平成同一个临时文件。
func partPath(dest, rel string) string {
	return filepath.Join(dest, partsDir, filepath.FromSlash(rel))
}

// partDonePath 为每个分片单独留完成标记。分片写入是并发的，单靠 .part 文件
// 大小无法区分「分片 2 已写、分片 1 还没写」的空洞，必须逐片确认。
func partDonePath(dest, rel string, index uint32) string {
	return partPath(dest, rel) + fmt.Sprintf(".%d.done", index)
}

func partDone(dest, rel string, index uint32) bool {
	_, err := os.Stat(partDonePath(dest, rel, index))
	return err == nil
}

func markPartDone(dest, rel string, index uint32) error {
	return os.WriteFile(partDonePath(dest, rel, index), nil, 0o600)
}

// prepareParts 校验并复用上次下载留下的分片，返回已完成字节数。
// 清单 ID 不一致（内容变了）时丢弃旧分片，避免把不同版本的内容拼在一起。
func prepareParts(dest string, m *Manifest) (int64, error) {
	root := filepath.Join(dest, partsDir)
	marker := filepath.Join(root, partsMarker)
	raw, err := os.ReadFile(marker)
	if err != nil || strings.TrimSpace(string(raw)) != m.ID {
		if err := os.RemoveAll(root); err != nil {
			return 0, err
		}
		if err := os.MkdirAll(root, 0o700); err != nil {
			return 0, err
		}
		if err := os.WriteFile(marker, []byte(m.ID), 0o600); err != nil {
			return 0, err
		}
		return 0, nil
	}
	var resumed int64
	for _, f := range m.Files {
		stat, err := os.Stat(partPath(dest, f.Path))
		if err != nil {
			continue
		}
		total := (f.Size + fsChunkSize - 1) / fsChunkSize
		for i := int64(0); i < total; i++ {
			if !partDone(dest, f.Path, uint32(i)) {
				continue
			}
			off := i * fsChunkSize
			need := min64(fsChunkSize, f.Size-off)
			if stat.Size() < off+need {
				continue
			}
			resumed += need
		}
	}
	return resumed, nil
}

func writePart(dest, rel string, off int64, data []byte, total int64) error {
	path := partPath(dest, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
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
