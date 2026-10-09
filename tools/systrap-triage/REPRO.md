---
name: systrap-triage
description: Reproduce and diagnose gVisor systrap sandboxes that hang with stub processes spinning. Builds patched runsc variants, runs a workload under systrap with time caps, and collects stub pc and memory-layout evidence without touching the Sentry.
---

# systrap triage

This directory has three small tools for systrap hangs where a sandbox stops
making progress while one or more stub threads burn a full CPU.

`harness.sh build` makes a `runsc` from a source tree, optionally with patches
applied to a temporary copy, and builds `collect` from the same tree so both
agree on the sysmsg blob layout. `harness.sh run` starts a workload under
`--platform=systrap` N times, caps each run, and when a run is still alive at
the cap it calls `collect` on that sandbox and then kills its whole process tree
by pid. It prints one line per run. `sighandler.sh` rebuilds the sysmsg blob
with debug info so `collect` can name the source line a stub is stuck on.

## Prerequisites

Building needs Go for the go branch (`git checkout go`) or Bazel for master.
Running needs Linux, root, and ptrace allowed. In Docker that means
`--privileged`. `sighandler.sh` needs a C compiler and binutils for the host
arch and a master checkout, since the go branch has no sysmsg C sources.

## Reproduce google/gvisor#15572

From a go branch checkout, on a Linux host as root:

    ./scenarios/spinq-gap/run.sh --src /path/to/gvisor-go --out /tmp/spinq-gap

That builds A (master plus `force-gap.patch`) and B (A plus `fix.patch`) and
runs each 16 times. `force-gap.patch` is debug only: it reads
`RUNSC_REPRO_STUB_REGION` and, when set, places the per-thread sysmsg stack
region so the unpatched spinning queue falls inside region N. With the variable
unset the build behaves like master. Compare the output with
`scenarios/spinq-gap/expected.md`. To get file and line in the collector output,
first run `./sighandler.sh /path/to/gvisor-master /tmp/sh` and add
`--sighandler /tmp/sh` to `run.sh`.

Building and running can be split: run `run.sh` on any machine with Go to
build, copy the output directory to the Linux host, and rerun there with
`--out <dir> --skip-build`.

## Reading collect output

`collect <sentry pid>` first lists stub threads with their CPU over 2 seconds.
It then finds the sysmsg blob in a stub and reads the exported region addresses
from it. For every stub process it prints each region with the mapping that
contains it. A region is ALIASED when that mapping starts somewhere else, which
means another mapping was placed over it. With `-ptrace`, each busy thread is
stopped briefly three times and its pc is printed as a blob offset, the nearest
exported symbol, or function and line when `-elf` points at the debug object. An
sp line ending in "spinning_queue is inside this stack mapping" is the #15572
signature.

## Safety

Warning: ptrace sampling of a healthy stub can wedge its sandbox, so use
`-ptrace` only on an already-hung sandbox and never on production sandboxes you
care about.

`collect` never attaches to the Sentry. A core dump of the Sentry faults the
sandbox shared memory into the pod memory cgroup and has OOM-killed a Sentry in
production. Stopping stub threads of a healthy, busy sandbox wedged it in
testing. `harness.sh` passes `-ptrace` only for runs that outlived their cap,
and keeps at most one hung sandbox alive at a time.
