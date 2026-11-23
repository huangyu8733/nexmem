package diag

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 打洞结果标签，与 P0 场景报告口径一致。
const (
	// HolePunchDirect 表示直连（打洞成功即直连）。
	HolePunchDirect = "direct"
	// HolePunchRelayed 表示经中继连通。
	HolePunchRelayed = "relayed"
	// HolePunchFailed 表示直连与中继都未建立。
	HolePunchFailed = "failed"
)

// maxDHTSamples 是 DHT 耗时分位数保留的最大样本数（最近样本优先）。
const maxDHTSamples = 4096

// Recorder 采集运行指标，并把同一事件写入结构化日志。
type Recorder struct {
	mu       sync.Mutex
	logger   *Logger
	start    time.Time
	now      func() time.Time
	dhtCount int64
	dhtFails int64
	samples  []int64 // 微秒
	holes    map[string]int64
	s3       map[string]int64

	// 离线通道观测（P3 门禁：桶用量与票据消耗可观测）。
	offlineUploads     int64
	offlineUploadBytes int64
	offlineFailures    int64
	ticketsTaken       int64
}

// NewRecorder 创建指标采集器；logger 可为 nil（只采集指标）。
func NewRecorder(logger *Logger) *Recorder {
	return &Recorder{
		logger: logger,
		start:  time.Now(),
		now:    time.Now,
		holes:  make(map[string]int64),
		s3:     make(map[string]int64),
	}
}

// Logger 返回绑定的日志器，可能为 nil。
func (r *Recorder) Logger() *Logger {
	if r == nil {
		return nil
	}
	return r.logger
}

// ObserveDHTLookup 记录一次 DHT 寻址耗时与结果。
func (r *Recorder) ObserveDHTLookup(d time.Duration, err error) {
	if r == nil {
		return
	}
	if d < 0 {
		d = 0
	}
	us := d.Microseconds()

	r.mu.Lock()
	r.dhtCount++
	if err != nil {
		r.dhtFails++
	}
	if len(r.samples) == maxDHTSamples {
		copy(r.samples, r.samples[1:])
		r.samples[len(r.samples)-1] = us
	} else {
		r.samples = append(r.samples, us)
	}
	r.mu.Unlock()

	if r.logger != nil {
		fields := map[string]any{
			"dht_lookup_ms": roundMS(d),
			"ok":            err == nil,
		}
		if err != nil {
			fields["error"] = err.Error()
		}
		r.logger.Info("dht", "dht.lookup", fields)
	}
}

// ObserveHolePunch 记录一次连通结果，network 取 tcp / quic / unknown。
func (r *Recorder) ObserveHolePunch(network, result string) {
	if r == nil {
		return
	}
	network = strings.ToLower(strings.TrimSpace(network))
	if network == "" {
		network = "unknown"
	}
	switch result {
	case HolePunchDirect, HolePunchRelayed, HolePunchFailed:
	default:
		result = HolePunchFailed
	}

	r.mu.Lock()
	r.holes[network+"/"+result]++
	r.mu.Unlock()

	if r.logger != nil {
		r.logger.Info("net", "net.holepunch", map[string]any{
			"network":   network,
			"holepunch": result,
		})
	}
}

// ObserveS3 记录一次 S3 请求；传输失败时 status 传 0。
func (r *Recorder) ObserveS3(method string, status int) {
	if r == nil {
		return
	}
	method = strings.ToUpper(strings.TrimSpace(method))
	if method == "" {
		method = "UNKNOWN"
	}
	key := method + "/" + strconv.Itoa(status)
	if status == 0 {
		key = method + "/io"
	}

	r.mu.Lock()
	r.s3[key]++
	r.mu.Unlock()

	if r.logger != nil {
		fields := map[string]any{
			"method":    method,
			"s3_status": status,
		}
		if status == 0 {
			fields["io_error"] = true
		}
		r.logger.Info("blob", "s3.request", fields)
	}
}

// ObserveOfflineUpload 记录一次离线对象上传结果：bytes 为对象载荷大小，
// ok=false 表示本次离线投递最终失败（计入失败数而非写入字节）。
func (r *Recorder) ObserveOfflineUpload(bytes int64, ok bool) {
	if r == nil {
		return
	}
	r.mu.Lock()
	if ok {
		r.offlineUploads++
		if bytes > 0 {
			r.offlineUploadBytes += bytes
		}
	} else {
		r.offlineFailures++
	}
	uploads, total, failures := r.offlineUploads, r.offlineUploadBytes, r.offlineFailures
	r.mu.Unlock()

	if r.logger != nil {
		r.logger.Info("blob", "offline.upload", map[string]any{
			"bytes":    bytes,
			"ok":       ok,
			"uploads":  uploads,
			"total":    total,
			"failures": failures,
		})
	}
}

// ObserveTicketTake 记录一次离线上传票据领取数量（0 表示对方票据池已空）。
func (r *Recorder) ObserveTicketTake(n int) {
	if r == nil {
		return
	}
	r.mu.Lock()
	if n > 0 {
		r.ticketsTaken += int64(n)
	}
	taken := r.ticketsTaken
	r.mu.Unlock()

	if r.logger != nil {
		r.logger.Info("blob", "offline.ticket", map[string]any{
			"taken": n,
			"total": taken,
		})
	}
}

// Snapshot 是指标的一次性快照。
type Snapshot struct {
	UptimeMS   int64            `json:"uptime_ms"`
	DHTLookups int64            `json:"dht_lookups"`
	DHTErrors  int64            `json:"dht_errors"`
	DHTP50MS   float64          `json:"dht_p50_ms"`
	DHTP95MS   float64          `json:"dht_p95_ms"`
	HolePunch  map[string]int64 `json:"holepunch"`
	S3Status   map[string]int64 `json:"s3_status"`
	LogRecords int              `json:"log_records,omitempty"`
	LogDropped int64            `json:"log_dropped,omitempty"`

	// 离线通道（P3 门禁）：已写入桶的对象数与字节数、失败数、已消耗票据数。
	OfflineUploads     int64 `json:"offline_uploads"`
	OfflineUploadBytes int64 `json:"offline_upload_bytes"`
	OfflineFailures    int64 `json:"offline_upload_failures"`
	TicketsTaken       int64 `json:"tickets_taken"`
}

// Snapshot 返回当前指标快照。
func (r *Recorder) Snapshot() Snapshot {
	if r == nil {
		return Snapshot{}
	}
	r.mu.Lock()
	samples := make([]int64, len(r.samples))
	copy(samples, r.samples)
	snap := Snapshot{
		UptimeMS:   r.now().Sub(r.start).Milliseconds(),
		DHTLookups: r.dhtCount,
		DHTErrors:  r.dhtFails,
		DHTP50MS:   percentileMS(samples, 50),
		DHTP95MS:   percentileMS(samples, 95),
		HolePunch:  make(map[string]int64, len(r.holes)),
		S3Status:   make(map[string]int64, len(r.s3)),

		OfflineUploads:     r.offlineUploads,
		OfflineUploadBytes: r.offlineUploadBytes,
		OfflineFailures:    r.offlineFailures,
		TicketsTaken:       r.ticketsTaken,
	}
	for k, v := range r.holes {
		snap.HolePunch[k] = v
	}
	for k, v := range r.s3 {
		snap.S3Status[k] = v
	}
	r.mu.Unlock()

	if r.logger != nil {
		snap.LogRecords = r.logger.Len()
		snap.LogDropped = r.logger.Dropped()
	}
	if snap.UptimeMS < 0 {
		snap.UptimeMS = 0
	}
	return snap
}

// percentileMS 用最近秩法计算分位数（输入为微秒，输出毫秒）。
func percentileMS(samples []int64, p float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	sorted := make([]int64, len(samples))
	copy(sorted, samples)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return roundMS(time.Duration(sorted[idx]) * time.Microsecond)
}

func roundMS(d time.Duration) float64 {
	return math.Round(float64(d)/float64(time.Microsecond)) / 1000
}
