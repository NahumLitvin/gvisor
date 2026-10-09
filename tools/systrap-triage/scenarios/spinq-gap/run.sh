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

# run.sh reproduces google/gvisor#15572: build A (force-gap.patch) and
# B (force-gap.patch + fix.patch) from one source tree, then run the
# workload on both with the spinning queue forced into a sysmsg stack.
#
#   run.sh --src DIR [--mode go|bazel] [--out DIR] [--runs N] [--cap SECS] [--region N] [--sighandler DIR] [--skip-build]
#
# Building works anywhere Go (or Bazel) does. Running needs Linux and root.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
harness=$here/../../harness.sh
src="" mode=go out=/tmp/spinq-gap runs=16 cap=30 region=1 skip=0 extra=()
while [ $# -gt 0 ]; do
  case $1 in
    --src) src=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --cap) cap=$2; shift 2 ;;
    --region) region=$2; shift 2 ;;
    --sighandler) extra=(--sighandler "$2"); shift 2 ;;
    --skip-build) skip=1; shift ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ $skip = 0 ]; then
  [ -n "$src" ] || { echo "need --src" >&2; exit 2; }
  "$harness" build --src "$src" --mode "$mode" --out "$out/A" --patch "$here/force-gap.patch" ${extra[@]+"${extra[@]}"}
  "$harness" build --src "$src" --mode "$mode" --out "$out/B" --patch "$here/force-gap.patch" --patch "$here/fix.patch" ${extra[@]+"${extra[@]}"}
  (cd "$here/workload" && GOOS=linux CGO_ENABLED=0 go build -o "$out/workload" main.go)
fi
if [ "$(uname)" != Linux ] || [ "$(id -u)" != 0 ]; then
  echo "built into $out; copy it to a Linux host and rerun as root with --out $out --skip-build"
  exit 0
fi
for v in A B; do
  echo "== $v"
  "$harness" run --out "$out/$v" --workload "$out/workload" --args 5s --runs "$runs" --cap "$cap" \
    --env RUNSC_REPRO_STUB_REGION="$region"
done
