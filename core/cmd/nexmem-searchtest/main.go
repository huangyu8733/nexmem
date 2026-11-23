// nexmem-searchtest 是 P2-07 的内核 CLI 验收程序：
// 在临时库写入指定条数的消息并建立 FTS5 全文索引，逐条执行检索，
// 校验 1 万条消息下每次检索耗时均低于 100ms。
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nexmem/core/internal/store"
)

func main() {
	count := flag.Int("count", 10000, "写入的消息条数")
	limit := flag.Int("limit", 50, "单次检索返回条数上限")
	dir := flag.String("dir", "", "工作目录，默认使用临时目录")
	flag.Parse()

	elapsed, err := run(*dir, *count, *limit)
	if err != nil {
		fmt.Printf("RESULT=FAIL\nerror=%v\n", err)
		os.Exit(1)
	}
	fmt.Printf("SEARCH_TOTAL_ELAPSED_MS=%.1f\n", elapsed.Seconds()*1000)
	fmt.Println("RESULT=PASS")
}

func run(dir string, count, limit int) (time.Duration, error) {
	if dir == "" {
		var err error
		dir, err = os.MkdirTemp("", "nexmem-search-*")
		if err != nil {
			return 0, err
		}
		defer os.RemoveAll(dir)
	} else if err := os.MkdirAll(dir, 0o700); err != nil {
		return 0, err
	}

	ctx := context.Background()
	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		return 0, err
	}
	defer db.Close()
	if err := store.Migrate(ctx, db); err != nil {
		return 0, err
	}
	dao := store.NewDAO(db)

	msgs := make([]store.Message, 0, count)
	for i := 0; i < count; i++ {
		body := fmt.Sprintf("第 %d 条消息：今天天气很好，我们一起去公园散步吧。nexmem meeting notes %d", i, i)
		msgs = append(msgs, store.Message{
			MsgUUID:        fmt.Sprintf("m%06d", i),
			ConversationID: fmt.Sprintf("dm:test|peer%d", i%20),
			SenderAccount:  []byte("alice"),
			SentAt:         int64(1_700_000_000 + i),
			Direction:      store.DirectionIn,
			ContentType:    0,
			BodyEnc:        []byte(body),
			State:          store.MessageStateReceived,
			Body:           body,
		})
	}
	start := time.Now()
	if err := dao.PutMessages(ctx, msgs); err != nil {
		return 0, fmt.Errorf("批量写入消息: %w", err)
	}
	fmt.Printf("SEARCH_MESSAGES=%d\n", count)
	fmt.Printf("SEARCH_INDEX_BUILD_MS=%.1f\n", time.Since(start).Seconds()*1000)

	indexed, err := dao.CountSearchIndex(ctx)
	if err != nil {
		return 0, err
	}
	fmt.Printf("SEARCH_INDEXED=%d\n", indexed)
	if indexed != count {
		return 0, fmt.Errorf("索引条数 %d 与消息条数 %d 不一致", indexed, count)
	}

	queries := []struct {
		text string
		want bool
	}{
		{"nexmem", true},
		{"天气很好", true},
		{"公园散步", true},
		{"meeting notes", true},
		{"不存在的关键词", false},
	}
	total := time.Duration(0)
	for _, q := range queries {
		begin := time.Now()
		hits, err := dao.SearchMessages(ctx, store.MessageSearchQuery{Query: q.text, Limit: limit})
		cost := time.Since(begin)
		total += cost
		fmt.Printf("SEARCH_QUERY=%q SEARCH_HITS=%d SEARCH_ELAPSED_MS=%.1f\n",
			q.text, len(hits), cost.Seconds()*1000)
		if err != nil {
			return 0, err
		}
		if q.want && len(hits) == 0 {
			return 0, fmt.Errorf("检索 %q 无命中", q.text)
		}
		if !q.want && len(hits) != 0 {
			return 0, fmt.Errorf("检索 %q 不应命中", q.text)
		}
		if strings.TrimSpace(q.text) != "" && cost >= 100*time.Millisecond {
			return 0, fmt.Errorf("检索 %q 耗时 %.1fms，超过 100ms", q.text, cost.Seconds()*1000)
		}
	}
	return total, nil
}
