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

// Command workload keeps 16 locked OS threads busy with syscalls and short
// sleeps, so systrap stubs keep entering the spinning queue.
package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
)

func main() {
	d := 30 * time.Second
	if len(os.Args) > 1 {
		d, _ = time.ParseDuration(os.Args[1])
	}
	runtime.GOMAXPROCS(16)
	end := time.Now().Add(d)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			runtime.LockOSThread()
			for n := 0; time.Now().Before(end); n++ {
				syscall.Getpid()
				if n%100 == 0 {
					time.Sleep(time.Millisecond * time.Duration(i%5))
				}
			}
		}(i)
	}
	wg.Wait()
	fmt.Println("DONE")
}
