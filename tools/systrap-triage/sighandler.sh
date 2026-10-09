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

# sighandler.sh rebuilds the systrap sysmsg blob with debug info, for go
# branch builds where the Bazel-built object is not available. It uses the
# flags from pkg/sentry/platform/systrap/sysmsg/build.bzl plus -g, which adds
# DWARF without changing code generation.
#
#   sighandler.sh <gvisor source tree with sysmsg C sources> <out dir>
#
# Needs Linux with cc, ld, objcopy and nm for the host arch. The output goes
# to `harness.sh build --sighandler <out dir>`.

set -euo pipefail
src=$(cd "$1/pkg/sentry/platform/systrap/sysmsg" && pwd)
mkdir -p "$2"; out=$(cd "$2" && pwd)
case $(uname -m) in
  x86_64) arch=amd64 opt=-O2 ;;
  aarch64) arch=arm64 opt="-O1 -mno-outline-atomics" ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
cc=${CC:-cc}
flags="-DPAGE_SIZE=$(getconf PAGESIZE) -fpie $opt -fno-builtin -ffreestanding -mgeneral-regs-only -g -fdebug-prefix-map=$src=. -Wa,--noexecstack -fno-asynchronous-unwind-tables -fno-stack-protector"
cd "$out"
objs=()
for f in sigrestorer_$arch.S sighandler_$arch.c syshandler_$arch.S sysmsg_lib.c; do
  $cc $flags -I"$src" -c "$src/$f" -o "${f%.*}.o"
  objcopy --strip-debug "${f%.*}.o" "${f%.*}.nodebug.o"
  objs+=("${f%.*}")
done
# The blob comes from stripped objects, so its code matches a -g0 build.
ld -pie -z noexecstack -T "$src/pie.lds.S" "${objs[@]/%/.nodebug.o}" -o blob.o
objcopy -O binary blob.o sighandler.built-in.$arch.bin
bash "$src/gen_offsets_go.sh" sighandler Sighandler blob.o nm > sighandler_$arch.go
# pie.lds.S folds .debug* into the blob section; drop that line so the debug
# ELF keeps DWARF as real sections at the same code addresses.
grep -v '\*(\.debug\*)' "$src/pie.lds.S" > debug.lds
ld -pie -z noexecstack -T debug.lds "${objs[@]/%/.o}" -o sighandler.built-in.bin.o
cmp <(nm blob.o | grep -v ' [Nn] ' | sort) <(nm sighandler.built-in.bin.o | grep -v ' [Nn] ' | sort) || { echo "debug ELF symbols differ from the blob" >&2; exit 1; }
echo "built $out/sighandler.built-in.$arch.bin, $out/sighandler_$arch.go and $out/sighandler.built-in.bin.o"
