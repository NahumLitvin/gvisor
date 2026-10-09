#!/bin/bash

# Copyright 2026 The gVisor Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# harness.sh builds runsc (optionally patched) plus the collector, then runs a
# workload under systrap N times and reports which runs hung. See REPRO.md.
#
#   harness.sh build --src DIR --out DIR [--mode go|bazel] [--patch FILE]... [--sighandler DIR]
#   harness.sh run --out DIR --workload BIN [--args "..."] [--runs N] [--cap SECS] [--env K=V]...

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "harness: $*" >&2; exit 1; }

build() {
  local src="" out="" mode=go sh="" patches=()
  while [ $# -gt 0 ]; do
    case $1 in
      --src) src=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --patch) patches+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
      --sighandler) sh=$(cd "$2" && pwd); shift 2 ;;
      *) die "unknown build flag $1" ;;
    esac
  done
  [ -n "$src" ] && [ -n "$out" ] || die "build needs --src and --out"
  mkdir -p "$out"; out=$(cd "$out" && pwd)
  local tree; tree=$(mktemp -d "${TMPDIR:-/tmp}/systrap-triage.XXXXXX")
  git -C "$src" archive HEAD | tar -x -C "$tree"
  for p in ${patches[@]+"${patches[@]}"}; do (cd "$tree" && git apply "$p") || die "patch $p does not apply"; done
  mkdir -p "$tree/tools/systrap-triage"
  cp -R "$here/collect" "$tree/tools/systrap-triage/"
  case $mode in
    go)
      # The go branch has no Bazel-built prewarmer, so stand in for it with an
      # exec of the Sentry fd, which is all the prewarmer does at the end.
      mkdir -p "$tree/tools/systrap-triage/prewarmer" "$out/gvisor-bin"
      cat > "$tree/tools/systrap-triage/prewarmer/main.go" <<'GO'
package main

import (
	"os"
	"syscall"
)

func main() {
	syscall.Exec("/proc/self/fd/3", os.Args, os.Environ())
	os.Exit(127)
}
GO
      if [ -n "$sh" ]; then
        # Embed a blob built by sighandler.sh and keep its ELF for collect.
        local arch; arch=${GOARCH:-$(go env GOARCH)}
        cp "$sh/sighandler.built-in.$arch.bin" "$sh/sighandler_$arch.go" "$tree/pkg/sentry/platform/systrap/sysmsg/"
        cp "$sh/sighandler.built-in.bin.o" "$out/"
      fi
      (cd "$tree" && export GOOS=linux CGO_ENABLED=0 &&
        go build -o "$out/runsc" ./runsc &&
        go build -o "$out/collect" ./tools/systrap-triage/collect &&
        go build -o "$out/gvisor-bin/gvisor-sentry-prewarmer" ./tools/systrap-triage/prewarmer)
      ;;
    bazel)
      (cd "$tree" &&
        make copy TARGETS=runsc DESTINATION="$out" &&
        make copy TARGETS=//tools/systrap-triage/collect DESTINATION="$out" &&
        make copy TARGETS=//pkg/sentry/platform/systrap/sysmsg:sighandler_object DESTINATION="$out")
      ;;
    *) die "unknown mode $mode" ;;
  esac
  rm -rf "$tree"
  echo "built into $out"
}

# descendants prints every pid under $1, found by parent pid, not by name.
descendants() {
  local kids
  kids=$(awk -v p="$1" '{ sub(/.*\) /, ""); split($0, f, " "); if (f[2] == p) print FILENAME }' /proc/[0-9]*/stat 2>/dev/null | cut -d/ -f3)
  for k in $kids; do echo "$k"; descendants "$k"; done
}

run() {
  local out="" workload="" args="" runs=10 cap=60 envs=()
  while [ $# -gt 0 ]; do
    case $1 in
      --out) out=$2; shift 2 ;;
      --workload) workload=$2; shift 2 ;;
      --args) args=$2; shift 2 ;;
      --runs) runs=$2; shift 2 ;;
      --cap) cap=$2; shift 2 ;;
      --env) envs+=("$2"); shift 2 ;;
      *) die "unknown run flag $1" ;;
    esac
  done
  [ "$(id -u)" = 0 ] || die "run needs root"
  [ -x "$out/runsc" ] && [ -x "$workload" ] || die "run needs --out with a built runsc and an executable --workload"
  local elf=""; [ -f "$out/sighandler.built-in.bin.o" ] && elf="-elf=$out/sighandler.built-in.bin.o"
  printf '%-4s %-4s %-5s %-5s %-8s %s\n' run rc secs hung spinning "key log line"
  for i in $(seq 1 "$runs"); do
    local dir="$out/runs/$i"; rm -rf "$dir"; mkdir -p "$dir"
    local t0; t0=$(date +%s)
    env ${envs[@]+"${envs[@]}"} "$out/runsc" --platform=systrap --network=none --ignore-cgroups --debug --debug-log="$dir/" \
      --sidecar-usage-policy=LEGACY_DEPRECATED_SLOW_EMBEDDED_FALLBACK \
      do "$workload" $args > "$dir/out" 2>&1 &
    local rpid=$! rc="" hung=no spin=0
    while kill -0 "$rpid" 2>/dev/null && [ $(( $(date +%s) - t0 )) -lt "$cap" ]; do sleep 1; done
    local pids; pids=$(descendants "$rpid")
    if kill -0 "$rpid" 2>/dev/null; then
      local sentry=""
      for p in $pids; do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "boot.*$dir\|$dir.*boot" && sentry=$p && break; done
      if [ -n "$sentry" ]; then
        "$out/collect" -ptrace $elf "$sentry" > "$dir/collect.txt" 2>&1 || true
        spin=$(grep -c '^spinning tid' "$dir/collect.txt" || true)
      fi
      [ "$spin" -gt 0 ] && hung=yes
      # Kill by pid so that renamed stub processes are not missed.
      kill -9 $pids "$rpid" 2>/dev/null || true
      wait "$rpid" 2>/dev/null || true
      rc=killed
    else
      wait "$rpid" && rc=0 || rc=$?
    fi
    local key; key=$(cat "$dir"/*boot* 2>/dev/null | grep -o -m1 'context is stuck.*' || cat "$dir"/*boot* 2>/dev/null | grep -o -m1 'REPRO forced gap.*' || true)
    printf '%-4s %-4s %-5s %-5s %-8s %s\n' "$i" "$rc" "$(( $(date +%s) - t0 ))" "$hung" "$spin" "$key"
  done
}

cmd=${1:-}; shift || true
case $cmd in
  build) build "$@" ;;
  run) run "$@" ;;
  *) sed -n '20,21p' "$0"; exit 2 ;;
esac
