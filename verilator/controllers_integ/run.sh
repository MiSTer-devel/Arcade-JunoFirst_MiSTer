#!/bin/bash
# Input-path equivalence test, controllers.sv wave-2 integration (CTL-2026-10-25).
#   ./run.sh           regenerate old_in.sv / new_in.sv (gen.py cfg.py), build in a fresh $OBJ, run
#   ./run.sh break     same with one dut output bit flipped once: must report FAIL 1
# defs.txt = verilator defines for this core (NOUT, CFGN, ...); files.txt = extra source files (old submodules), one
# per line, relative to this directory. Build output: $OBJ (default ./obj; use a fresh directory per build).
set -u
cd "$(dirname "$0")" && cd "$(pwd -P)"
ulimit -v 8000000
V=verilator
OBJ=$(realpath -m "${OBJ:-obj}")
LIB=$(realpath ../../rtl/mister_custom/controllers.sv)
python3 -B -I gen.py cfg.py || exit 1
B=""; n=tb_integ
if [ "${1:-}" = "break" ]; then B="+define+BREAK"; n=tb_integ_break; fi
EXTRA=()
if [ -f files.txt ]; then while read -r f; do [ -n "$f" ] && EXTRA+=("$(realpath "$f")"); done < files.txt; fi
mkdir -p "$OBJ"
$V --cc --exe --build -O2 -j 4 -Wno-fatal -Wno-lint -Wno-style $(cat defs.txt) ${DEFS:-} $B --top-module tb_integ --prefix Vtb \
   -Mdir "$OBJ/$n" "$PWD/tb_integ.sv" "$PWD/new_in.sv" "$PWD/old_in.sv" "$LIB" "${EXTRA[@]}" "$PWD/sim_main.cpp" \
   > "$OBJ/$n.build.log" 2>&1 || { echo "BUILD FAIL (see $OBJ/$n.build.log)"; grep -m 20 -i "error" "$OBJ/$n.build.log"; exit 1; }
time "$OBJ/$n/Vtb"
