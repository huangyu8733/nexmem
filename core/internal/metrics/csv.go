package metrics

import (
	"encoding/csv"
	"os"
	"path/filepath"
	"strconv"
)

// Sample 是一次连通性测量的结果，字段与 P0 报告所需指标一一对应。
type Sample struct {
	Time      string
	Scenario  string
	Role      string
	Iter      int
	Target    string
	Via       string
	Success   bool
	Direct    bool
	Relayed   bool
	Transport string
	ConnectMS int64
	UpgradeMS int64
	RTTMS     int64
	Addrs     string
	Error     string
}

var header = []string{
	"ts", "scenario", "role", "iter", "target", "via",
	"success", "direct", "relayed", "transport",
	"connect_ms", "upgrade_ms", "rtt_ms", "addrs", "error",
}

// Writer 以追加方式写 CSV，文件不存在时写入表头。
type Writer struct {
	f *os.File
	w *csv.Writer
}

// Open 打开（或创建）CSV 文件。
func Open(path string) (*Writer, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	_, statErr := os.Stat(path)
	needHeader := os.IsNotExist(statErr)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	w := csv.NewWriter(f)
	if needHeader {
		if err := w.Write(header); err != nil {
			return nil, err
		}
		w.Flush()
	}
	return &Writer{f: f, w: w}, nil
}

// Write 追加一条记录并立即刷盘，保证进程被中断时数据不丢。
func (w *Writer) Write(s Sample) error {
	row := []string{
		s.Time, s.Scenario, s.Role, strconv.Itoa(s.Iter), s.Target, s.Via,
		strconv.FormatBool(s.Success), strconv.FormatBool(s.Direct), strconv.FormatBool(s.Relayed), s.Transport,
		strconv.FormatInt(s.ConnectMS, 10), strconv.FormatInt(s.UpgradeMS, 10), strconv.FormatInt(s.RTTMS, 10),
		s.Addrs, s.Error,
	}
	if err := w.w.Write(row); err != nil {
		return err
	}
	w.w.Flush()
	return w.w.Error()
}

// Close 关闭文件。
func (w *Writer) Close() error { return w.f.Close() }
