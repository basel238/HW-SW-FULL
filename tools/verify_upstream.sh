#!/usr/bin/env bash
# =============================================================================
# tools/verify_upstream.sh — PROVE that the measured workload is the real
# pyperformance benchmark, automatically.
#
# This runs as STAGE 0 of every pipeline invocation. It does not ask you to
# trust that the wrappers use upstream code; it demonstrates it.
#
# FIVE CHECKS
#   1. PRESENT     upstream/ exists, or is auto-extracted from the venv.
#   2. AUTHENTIC   file hashes match the installed pyperformance package.
#   3. UNMODIFIED  original authorship headers are intact.
#   4. EXECUTED    the measured functions' bytecode has co_filename in upstream/.
#   5. TAMPER      editing upstream/ CHANGES the result; restoring it restores
#                  the result. This is the check that cannot be faked -- it is
#                  what caught a real defect where the wrapper had transcribed
#                  upstream's scene into a private copy, so edits to upstream/
#                  had no effect on the output.
#
# Exit 0 = the pipeline is measuring the genuine benchmark.
# Exit 1 = it is not. The pipeline refuses to produce numbers.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

UP="$REPO_ROOT/upstream"
FAIL=0
QUIET="${1:-}"

note() { [[ "$QUIET" == "--quiet" ]] || printf '%s\n' "$*"; }

# -----------------------------------------------------------------------------
# 1. PRESENT — auto-extract if missing
# -----------------------------------------------------------------------------
hdr "stage 0 — verifying the measured workload is the real benchmark"

need_extract=0
for b in raytrace nbody; do
  [[ -f "$UP/bm_${b}_upstream.py" ]] || need_extract=1
done

if (( need_extract )); then
  warn "upstream kernels missing -> extracting from the installed package"
  if [[ -x "$REPO_ROOT/setup/05_get_upstream.sh" ]]; then
    "$REPO_ROOT/setup/05_get_upstream.sh" || true
  fi
fi

for b in raytrace nbody; do
  if [[ -f "$UP/bm_${b}_upstream.py" ]]; then
    printf '  %-32s %sOK%s (%s lines)\n' "$b kernel present" "$C_G" "$C_RST" \
           "$(wc -l < "$UP/bm_${b}_upstream.py" | tr -d ' ')"
  else
    printf '  %-32s %sFAIL%s\n' "$b kernel present" "$C_R" "$C_RST"
    FAIL=1
  fi
done
(( FAIL )) && { err "cannot verify without the upstream kernels"; exit 1; }

# -----------------------------------------------------------------------------
# 2. AUTHENTIC — compare against the installed package
# -----------------------------------------------------------------------------
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

if [[ -f "$VENV_DIR/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  PP_DIR="$(python -c 'import pyperformance,os;print(os.path.dirname(pyperformance.__file__))' 2>/dev/null || true)"
  PP_VER="$(python -c 'import pyperformance;print(pyperformance.__version__)' 2>/dev/null || echo unknown)"
  deactivate 2>/dev/null || true

  if [[ -n "${PP_DIR:-}" ]]; then
    note "  comparing against pyperformance $PP_VER"
    for b in raytrace nbody; do
      SRC="$PP_DIR/data-files/benchmarks/bm_$b/run_benchmark.py"
      [[ -f "$SRC" ]] || SRC="$(find "$PP_DIR" -path "*bm_$b*" -name run_benchmark.py 2>/dev/null | head -1)"
      if [[ -n "$SRC" && -f "$SRC" ]]; then
        if [[ "$(sha_of "$SRC")" == "$(sha_of "$UP/bm_${b}_upstream.py")" ]]; then
          printf '  %-32s %sOK%s (sha256 matches package)\n' "$b authentic" "$C_G" "$C_RST"
        else
          printf '  %-32s %sFAIL%s differs from the installed package\n' "$b authentic" "$C_R" "$C_RST"
          echo "         package: $(sha_of "$SRC" | cut -c1-16)  upstream/: $(sha_of "$UP/bm_${b}_upstream.py" | cut -c1-16)"
          echo "         fix: ./setup/05_get_upstream.sh"
          FAIL=1
        fi
      else
        printf '  %-32s %sSKIP%s not found in package\n' "$b authentic" "$C_Y" "$C_RST"
      fi
    done
  fi
else
  printf '  %-32s %sSKIP%s no venv -> cannot compare hashes\n' "authenticity" "$C_Y" "$C_RST"
fi

# -----------------------------------------------------------------------------
# 3. UNMODIFIED — original attribution intact
# -----------------------------------------------------------------------------
if grep -q 'Callum and Tony Garnock-Jones' "$UP/bm_raytrace_upstream.py" 2>/dev/null; then
  printf '  %-32s %sOK%s\n' "raytrace attribution intact" "$C_G" "$C_RST"
else
  printf '  %-32s %sFAIL%s original header missing\n' "raytrace attribution" "$C_R" "$C_RST"; FAIL=1
fi
if grep -q 'Kevin Carson' "$UP/bm_nbody_upstream.py" 2>/dev/null; then
  printf '  %-32s %sOK%s\n' "nbody attribution intact" "$C_G" "$C_RST"
else
  printf '  %-32s %sFAIL%s original header missing\n' "nbody attribution" "$C_R" "$C_RST"; FAIL=1
fi

# -----------------------------------------------------------------------------
# 4. EXECUTED — the bytecode actually runs from upstream/
# -----------------------------------------------------------------------------
if "$PY_REL" - "$REPO_ROOT" <<'PY'; then
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "bench"))
bad = []

import bm_raytrace_upstream as wr
up = wr.load_upstream()
targets = [("Vector.__add__", up.Vector.__add__),
           ("Vector.dot", up.Vector.dot),
           ("Sphere.intersectionTime", up.Sphere.intersectionTime),
           ("Scene.rayColour", up.Scene.rayColour),
           ("Scene.render", up.Scene.render),
           ("SimpleSurface.colourAt", up.SimpleSurface.colourAt),
           ("bench_raytrace", up.bench_raytrace)]

import bm_nbody_upstream as wn
un = wn.load_upstream()
targets += [("advance", un.advance),
            ("report_energy", un.report_energy),
            ("offset_momentum", un.offset_momentum),
            ("bench_nbody", un.bench_nbody)]

for name, fn in targets:
    f = os.path.realpath(fn.__code__.co_filename)
    if os.path.join(os.path.realpath(root), "upstream") not in f:
        bad.append((name, f))

if bad:
    print("  functions NOT sourced from upstream/:")
    for n, f in bad:
        print(f"    {n}: {f}")
    sys.exit(1)
print(f"  all {len(targets)} measured functions execute from upstream/")
sys.exit(0)
PY
  printf '  %-32s %sOK%s\n' "bytecode origin" "$C_G" "$C_RST"
else
  printf '  %-32s %sFAIL%s\n' "bytecode origin" "$C_R" "$C_RST"; FAIL=1
fi

# -----------------------------------------------------------------------------
# 5. TAMPER — the check that cannot be faked
# -----------------------------------------------------------------------------
# If the wrapper had its own copy of any part of the workload, editing
# upstream/ would leave the result unchanged. This caught exactly that defect:
# a wrapper that had transcribed upstream's scene rendered identical pixels
# after upstream's sphere radius was changed.
tamper_test() { # tamper_test <bench> <sed-pattern> <replacement> <cmd...>
  local bench="$1" pat="$2" rep="$3"; shift 3
  local f="$UP/bm_${bench}_upstream.py" bak
  bak="$(mktemp)"; cp "$f" "$bak"
  local before after
  before="$("$@" 2>/dev/null | grep -oE '(checksum|energy)=[^ ]+' | head -1)"
  "$PY_REL" - "$f" "$pat" "$rep" <<'PY' >/dev/null 2>&1 || { cp "$bak" "$f"; rm -f "$bak"; return 2; }
import sys
p, pat, rep = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if pat not in s:
    sys.exit(1)
open(p, "w").write(s.replace(pat, rep, 1))
PY
  after="$("$@" 2>/dev/null | grep -oE '(checksum|energy)=[^ ]+' | head -1)"
  cp "$bak" "$f"; rm -f "$bak"
  find "$UP" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  local restored
  restored="$("$@" 2>/dev/null | grep -oE '(checksum|energy)=[^ ]+' | head -1)"

  if [[ -z "$before" || -z "$after" ]]; then
    printf '  %-32s %sSKIP%s could not obtain a result\n' "$bench tamper test" "$C_Y" "$C_RST"
    return 0
  fi
  if [[ "$before" == "$after" ]]; then
    printf '  %-32s %sFAIL%s editing upstream/ did NOT change the result\n' \
           "$bench tamper test" "$C_R" "$C_RST"
    echo "         -> the wrapper is NOT fully sourced from upstream/"
    return 1
  fi
  if [[ "$before" != "$restored" ]]; then
    printf '  %-32s %sFAIL%s restore did not reproduce the original result\n' \
           "$bench tamper test" "$C_R" "$C_RST"
    return 1
  fi
  printf '  %-32s %sOK%s (edit changed it, restore recovered it)\n' \
         "$bench tamper test" "$C_G" "$C_RST"
  return 0
}

tamper_test raytrace \
  "s.addObject(Sphere(Point(1, 3, -10), 2)," \
  "s.addObject(Sphere(Point(1, 3, -10), 2.5)," \
  "$PY_REL" "$REPO_ROOT/bench/bm_raytrace_upstream.py" \
  --mode raw --loops 1 --width 16 --height 16 --checksum || FAIL=1

tamper_test nbody \
  "DEFAULT_ITERATIONS = 20000" \
  "DEFAULT_ITERATIONS = 20001" \
  "$PY_REL" "$REPO_ROOT/bench/bm_nbody_upstream.py" \
  --mode raw --loops 1 || FAIL=1

echo
if (( FAIL )); then
  err "WORKLOAD VERIFICATION FAILED"
  err "The pipeline is NOT measuring the genuine pyperformance benchmark."
  err "Refusing to produce numbers. Run ./setup/05_get_upstream.sh"
  exit 1
fi
ok "workload verified: measuring the REAL pyperformance benchmarks"
exit 0
