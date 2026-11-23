// Command nexmem-ffitest 在 Windows 上加载 c-shared DLL，验证 nexmem_call 往返、
// 未知方法错误码、nexmem_free 回收以及批量调用下的内存稳定性（P1-09 验收）。
//
//go:build windows

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	psapi                = syscall.NewLazyDLL("psapi.dll")
	procGetCurrentProc   = kernel32.NewProc("GetCurrentProcess")
	procGetProcessMemory = psapi.NewProc("GetProcessMemoryInfo")
)

// processMemoryCounters 对应 Windows PROCESS_MEMORY_COUNTERS。
type processMemoryCounters struct {
	CB                      uint32
	PageFaultCount          uint32
	PeakWorkingSetSize      uintptr
	WorkingSetSize          uintptr
	QuotaPeakPagedPoolUsage uintptr
	QuotaPagedPoolUsage     uintptr
	QuotaPeakNonPagedPool   uintptr
	QuotaNonPagedPool       uintptr
	PagefileUsage           uintptr
	PeakPagefileUsage       uintptr
}

func workingSetMB() (float64, error) {
	var pmc processMemoryCounters
	pmc.CB = uint32(unsafe.Sizeof(pmc))
	h, _, _ := procGetCurrentProc.Call()
	ok, _, err := procGetProcessMemory.Call(h, uintptr(unsafe.Pointer(&pmc)), unsafe.Sizeof(pmc))
	if ok == 0 {
		return 0, err
	}
	return float64(pmc.WorkingSetSize) / (1024 * 1024), nil
}

type ffi struct {
	call *syscall.Proc
	free *syscall.Proc
}

func (f ffi) invoke(req string) ([]byte, int, error) {
	reqPtr, err := syscall.BytePtrFromString(req)
	if err != nil {
		return nil, 0, err
	}
	var out unsafe.Pointer
	var outLen int32
	ret, _, _ := f.call.Call(
		uintptr(unsafe.Pointer(reqPtr)),
		uintptr(len(req)),
		uintptr(unsafe.Pointer(&out)),
		uintptr(unsafe.Pointer(&outLen)),
	)
	if ret != 0 {
		return nil, int(ret), fmt.Errorf("nexmem_call 返回 %d", ret)
	}
	if out == nil {
		return nil, int(ret), fmt.Errorf("nexmem_call 成功但未返回响应缓冲")
	}
	defer f.free.Call(uintptr(out))
	if outLen < 0 {
		return nil, int(ret), fmt.Errorf("out_len 非法: %d", outLen)
	}
	return append([]byte(nil), unsafe.Slice((*byte)(out), int(outLen))...), 0, nil
}

func main() {
	dllFlag := flag.String("dll", filepath.Join("..", "bin", "nexmem.dll"), "c-shared DLL 路径")
	calls := flag.Int("calls", 200000, "内存稳定性压测的调用次数")
	maxDeltaMB := flag.Float64("max-delta-mb", 16, "允许的工作集增长上限（MiB）")
	flag.Parse()

	fail := func(format string, args ...any) {
		fmt.Printf("FFI_ERROR="+format+"\n", args...)
		fmt.Println("RESULT=FAIL")
		os.Exit(1)
	}

	dllPath, err := filepath.Abs(*dllFlag)
	if err != nil {
		fail("解析 DLL 路径失败: %v", err)
	}
	if _, err := os.Stat(dllPath); err != nil {
		fail("DLL 不存在: %v（先执行 make ffi）", err)
	}
	dll, err := syscall.LoadDLL(dllPath)
	if err != nil {
		fail("LoadDLL 失败: %v", err)
	}
	defer dll.Release()

	callProc, err := dll.FindProc("nexmem_call")
	if err != nil {
		fail("缺少导出 nexmem_call: %v", err)
	}
	freeProc, err := dll.FindProc("nexmem_free")
	if err != nil {
		fail("缺少导出 nexmem_free: %v", err)
	}
	if _, err := dll.FindProc("nexmem_set_event_cb"); err != nil {
		fail("缺少导出 nexmem_set_event_cb: %v", err)
	}
	lib := ffi{call: callProc, free: freeProc}

	fmt.Printf("FFI_DLL=%s\n", dllPath)

	resp, _, err := lib.invoke(`{"id":1,"method":"core.info","params":{}}`)
	if err != nil {
		fail("core.info 往返失败: %v", err)
	}
	var info struct {
		ID   uint64 `json:"id"`
		OK   bool   `json:"ok"`
		Data struct {
			APIVersion  string   `json:"api_version"`
			CoreVersion string   `json:"core_version"`
			Features    []string `json:"features"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp, &info); err != nil {
		fail("core.info 响应非法: %v (%s)", err, resp)
	}
	if !info.OK || info.ID != 1 || info.Data.APIVersion == "" {
		fail("core.info 响应字段不符: %s", resp)
	}
	fmt.Printf("FFI_INFO_APIVERSION=%s\n", info.Data.APIVersion)
	fmt.Printf("FFI_INFO_COREVERSION=%s\n", info.Data.CoreVersion)
	fmt.Printf("FFI_INFO_FEATURES=%d\n", len(info.Data.Features))

	unknown, _, err := lib.invoke(`{"id":2,"method":"nope.method","params":{}}`)
	if err != nil {
		fail("未知方法请求失败: %v", err)
	}
	var unknownEnv struct {
		OK    bool `json:"ok"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(unknown, &unknownEnv); err != nil {
		fail("未知方法响应非法: %v", err)
	}
	if unknownEnv.OK || unknownEnv.Error.Code != "INVALID_ARG" {
		fail("未知方法应返回 INVALID_ARG，实际 %s", unknown)
	}
	fmt.Printf("FFI_UNKNOWN_CODE=%s\n", unknownEnv.Error.Code)

	// 空请求必须被拒绝且不泄漏。
	if _, ret, err := lib.invoke(""); err == nil || ret == 0 {
		fail("空请求应返回非 0，实际 ret=%d err=%v", ret, err)
	}
	freeProc.Call(0) // 释放 NULL 必须安全
	fmt.Println("FFI_EMPTY_REJECTED=true")

	debug.FreeOSMemory()
	before, err := workingSetMB()
	if err != nil {
		fail("读取工作集失败: %v", err)
	}
	start := time.Now()
	for i := 0; i < *calls; i++ {
		if _, _, err := lib.invoke(`{"id":3,"method":"core.info","params":{}}`); err != nil {
			fail("第 %d 次调用失败: %v", i+1, err)
		}
	}
	elapsed := time.Since(start)
	debug.FreeOSMemory()
	after, err := workingSetMB()
	if err != nil {
		fail("读取工作集失败: %v", err)
	}
	delta := after - before

	fmt.Printf("FFI_CALLS=%d\n", *calls)
	fmt.Printf("FFI_ELAPSED=%s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("FFI_WORKINGSET_BEFORE_MB=%.2f\n", before)
	fmt.Printf("FFI_WORKINGSET_AFTER_MB=%.2f\n", after)
	fmt.Printf("FFI_WORKINGSET_DELTA_MB=%.2f\n", delta)
	if delta > *maxDeltaMB {
		fail("工作集增长 %.2f MiB 超过上限 %.2f MiB，疑似响应缓冲未释放", delta, *maxDeltaMB)
	}
	fmt.Println("FFI_MEMORY_STABLE=true")
	fmt.Println("RESULT=PASS")
}
