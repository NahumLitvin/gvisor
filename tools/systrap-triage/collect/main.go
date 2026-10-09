// Copyright 2026 The gVisor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Command collect prints read-only evidence about a hung systrap sandbox:
// stub thread CPU, the pc of spinning stub threads, and whether the stub
// shared regions sit in their own mappings.
//
// It never touches the Sentry process itself.
package main

import (
	"bytes"
	"debug/dwarf"
	"debug/elf"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"gvisor.dev/gvisor/pkg/sentry/platform/systrap/sysmsg"
)

var (
	elfPath  = flag.String("elf", "", "optional sighandler.built-in.bin.o for pc to function and line")
	samples  = flag.Int("samples", 3, "pc samples per spinning thread")
	doPtrace = flag.Bool("ptrace", false, "sample spinning stub threads with ptrace. Warning: ptrace sampling of a healthy stub can wedge its sandbox, so use this only on an already-hung sandbox and never on production sandboxes you care about")
)

// ponytail: assumes USER_HZ=100, true on every mainstream Linux config.
const clkTck = 100

type mapping struct {
	start, end  uint64
	perms, line string
}

func main() {
	flag.Parse()
	sentry, err := strconv.Atoi(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "usage: collect [-ptrace] [-elf sighandler.built-in.bin.o] <sentry pid>")
		os.Exit(2)
	}
	fmt.Printf("Sentry pid %d is left alone. Do not gcore or ptrace it: dumping it faults the sandbox shared memory into the pod memory cgroup and can OOM-kill it.\n\n", sentry)

	procs := descendants(sentry)
	if len(procs) == 0 {
		fmt.Println("no stub processes found under the Sentry")
		os.Exit(1)
	}
	before := threadTicks(procs)
	time.Sleep(2 * time.Second)
	after := threadTicks(procs)

	var spinning []int
	fmt.Println("stub threads (cpu over 2s):")
	tids := make([]int, 0, len(after))
	for tid := range after {
		tids = append(tids, tid)
	}
	sort.Ints(tids)
	for _, tid := range tids {
		pct := float64(after[tid].ticks-before[tid].ticks) * 100 / (2 * clkTck)
		fmt.Printf("  tid %-8d state %s cpu %5.1f%%\n", tid, after[tid].state, pct)
		if pct > 50 {
			spinning = append(spinning, tid)
		}
	}

	stub := procs[0]
	maps := readMaps(stub)
	base := blobBase(stub, maps)
	if base == 0 {
		fmt.Println("\nsysmsg blob not found in stub; was the collector built from the same tree as runsc?")
		os.Exit(1)
	}
	fmt.Printf("\nsysmsg blob at %#x\n\nregions per stub process:\n", base)
	regions := []struct {
		name string
		off  int
	}{
		{"spinning_queue", sysmsg.Sighandler_blob_offset____export_spinning_queue_addr},
		{"context_queue", sysmsg.Sighandler_blob_offset____export_context_queue_addr},
		{"context_region", sysmsg.Sighandler_blob_offset____export_context_region},
	}
	// Every stub process has its own address space, so check each one.
	queueAddr := readU64(stub, base+uint64(regions[0].off))
	for _, p := range procs {
		pmaps := readMaps(p)
		for _, r := range regions {
			addr := readU64(stub, base+uint64(r.off))
			m := find(pmaps, addr)
			status := "ok"
			// Each region is mapped on its own, so a mapping that starts
			// elsewhere means another mapping was placed over it.
			if m == nil || m.start != addr {
				status = "ALIASED"
			}
			fmt.Printf("  pid %-6d %-15s %#x %-7s %s\n", p, r.name, addr, status, lineOf(m))
		}
	}

	if len(spinning) > 0 && !*doPtrace {
		fmt.Printf("\n%d busy stub threads; rerun with -ptrace to sample their pc if the sandbox is hung\n", len(spinning))
		return
	}
	for _, tid := range spinning {
		fmt.Printf("\nspinning tid %d:\n", tid)
		for i := 0; i < *samples; i++ {
			pc, sp, err := sample(tid)
			if err != nil {
				fmt.Printf("  sample %d: %v\n", i, err)
				break
			}
			where := "outside sysmsg blob"
			if pc >= base && pc-base < uint64(len(sysmsg.SighandlerBlob)) {
				where = fmt.Sprintf("off %#x %s", pc-base, symbolize(pc-base))
			}
			spMap := find(readMaps(tid), sp)
			note := ""
			if spMap != nil && queueAddr >= spMap.start && queueAddr < spMap.end {
				note = " (spinning_queue is inside this stack mapping)"
			}
			fmt.Printf("  pc %#x %s\n  sp %#x %s%s\n", pc, where, sp, lineOf(spMap), note)
			time.Sleep(300 * time.Millisecond)
		}
	}
}

func statFields(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	s := string(b)
	return strings.Fields(s[strings.LastIndexByte(s, ')')+1:])
}

func descendants(root int) []int {
	children := map[int][]int{}
	dirs, _ := filepath.Glob("/proc/[0-9]*/stat")
	for _, d := range dirs {
		f := statFields(d)
		if len(f) < 2 {
			continue
		}
		pid, _ := strconv.Atoi(strings.Split(d, "/")[2])
		ppid, _ := strconv.Atoi(f[1])
		children[ppid] = append(children[ppid], pid)
	}
	var out []int
	queue := children[root]
	for len(queue) > 0 {
		p := queue[0]
		queue = append(queue[1:], children[p]...)
		out = append(out, p)
	}
	sort.Ints(out)
	return out
}

type tstat struct {
	state string
	ticks int64
}

func threadTicks(procs []int) map[int]tstat {
	out := map[int]tstat{}
	for _, p := range procs {
		tasks, _ := filepath.Glob(fmt.Sprintf("/proc/%d/task/[0-9]*/stat", p))
		for _, t := range tasks {
			f := statFields(t)
			if len(f) < 13 {
				continue
			}
			tid, _ := strconv.Atoi(strings.Split(t, "/")[4])
			u, _ := strconv.ParseInt(f[11], 10, 64)
			s, _ := strconv.ParseInt(f[12], 10, 64)
			out[tid] = tstat{f[0], u + s}
		}
	}
	return out
}

func readMaps(pid int) []mapping {
	b, _ := os.ReadFile(fmt.Sprintf("/proc/%d/maps", pid))
	var out []mapping
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		se := strings.SplitN(f[0], "-", 2)
		s, _ := strconv.ParseUint(se[0], 16, 64)
		e, _ := strconv.ParseUint(se[1], 16, 64)
		out = append(out, mapping{s, e, f[1], l})
	}
	return out
}

func find(maps []mapping, addr uint64) *mapping {
	for i := range maps {
		if addr >= maps[i].start && addr < maps[i].end {
			return &maps[i]
		}
	}
	return nil
}

func lineOf(m *mapping) string {
	if m == nil {
		return "(unmapped)"
	}
	return m.line
}

func readMem(pid int, addr uint64, n int) []byte {
	f, err := os.Open(fmt.Sprintf("/proc/%d/mem", pid))
	if err != nil {
		return nil
	}
	defer f.Close()
	b := make([]byte, n)
	if _, err := f.ReadAt(b, int64(addr)); err != nil {
		return nil
	}
	return b
}

func readU64(pid int, addr uint64) uint64 {
	b := readMem(pid, addr, 8)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint64(b)
}

// blobBase finds where the stub copied the sysmsg blob by matching its
// first bytes, which are code and never patched at runtime.
func blobBase(pid int, maps []mapping) uint64 {
	prefix := sysmsg.SighandlerBlob[:64]
	for _, m := range maps {
		if !strings.Contains(m.perms, "x") || m.end-m.start > 1<<24 {
			continue
		}
		if i := bytes.Index(readMem(pid, m.start, int(m.end-m.start)), prefix); i >= 0 {
			return m.start + uint64(i)
		}
	}
	return 0
}

// sample stops a stub thread just long enough to read its registers.
func sample(tid int) (uint64, uint64, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	const ptraceSeize, ptraceInterrupt = 0x4206, 0x4207
	if _, _, e := syscall.Syscall6(syscall.SYS_PTRACE, ptraceSeize, uintptr(tid), 0, 0, 0, 0); e != 0 {
		return 0, 0, fmt.Errorf("seize: %v", e)
	}
	defer syscall.PtraceDetach(tid)
	if _, _, e := syscall.Syscall6(syscall.SYS_PTRACE, ptraceInterrupt, uintptr(tid), 0, 0, 0, 0); e != 0 {
		return 0, 0, fmt.Errorf("interrupt: %v", e)
	}
	var ws syscall.WaitStatus
	if _, err := syscall.Wait4(tid, &ws, syscall.WALL, nil); err != nil {
		return 0, 0, err
	}
	var r syscall.PtraceRegs
	if err := syscall.PtraceGetRegs(tid, &r); err != nil {
		return 0, 0, err
	}
	pc, sp := pcSP(&r)
	return pc, sp, nil
}

func symbolize(off uint64) string {
	if *elfPath != "" {
		if s := fromELF(off); s != "" {
			return s
		}
	}
	exports := []struct {
		name string
		off  int
	}{
		{"__export_restore_rt", sysmsg.Sighandler_blob_offset____export_restore_rt},
		{"__export_start", sysmsg.Sighandler_blob_offset____export_start},
		{"__export_sighandler", sysmsg.Sighandler_blob_offset____export_sighandler},
		{"__export_syshandler", sysmsg.Sighandler_blob_offset____export_syshandler},
	}
	best := ""
	bestOff := -1
	for _, e := range exports {
		if uint64(e.off) <= off && e.off > bestOff {
			best, bestOff = e.name, e.off
		}
	}
	return fmt.Sprintf("%s+%#x (pass -elf for function and line)", best, off-uint64(bestOff))
}

func fromELF(off uint64) string {
	f, err := elf.Open(*elfPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	fn := ""
	syms, _ := f.Symbols()
	for _, s := range syms {
		if elf.ST_TYPE(s.Info) == elf.STT_FUNC && off >= s.Value && off < s.Value+s.Size {
			fn = s.Name
		}
	}
	if d, err := f.DWARF(); err == nil {
		r := d.Reader()
		for e, _ := r.Next(); e != nil; e, _ = r.Next() {
			if e.Tag != dwarf.TagCompileUnit {
				continue
			}
			if lr, _ := d.LineReader(e); lr != nil {
				var le dwarf.LineEntry
				if lr.SeekPC(off, &le) == nil {
					return fmt.Sprintf("%s %s:%d", fn, filepath.Base(le.File.Name), le.Line)
				}
			}
			r.SkipChildren()
		}
	}
	return fn
}
