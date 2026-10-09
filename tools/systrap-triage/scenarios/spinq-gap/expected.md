# Expected results

Measured on arm64 (go branch build, `--sighandler` blob, 16 workload threads,
`RUNSC_REPRO_STUB_REGION=1`). The page column comes from the `REPRO forced
gap` log line. Only the page decides the outcome, and it follows the random
stub start, so expect about 1 run in 8 to land on page 6.

| build | page 6 | page 7 | pages 0 to 5 |
|---|---|---|---|
| A: master + force-gap.patch | hangs, 4 stubs at 100% CPU, no "context is stuck" | runsc exits 137 within 1s | clean |
| B: A + fix.patch (google/gvisor#15573) | clean | clean | clean |

For a hung A run, `runs/<n>/collect.txt` shows the spinning queue as ALIASED
inside a `memfd:systrap-memory` stack mapping in every stub process, and the
spinning threads at `spinning_queue_remove_first sysmsg_lib.c:195` to `:197`.

Once #15573 is merged, master already has the fix, so A behaves like B. Revert
the fix (`git apply -R fix.patch` on the tree) to reproduce again.
