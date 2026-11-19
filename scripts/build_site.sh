#!/usr/bin/env bash
# Assembles the published site from the three branches:
#   /   from main (the live app)      /t  from beta (the hands-on beta)      /s  from sim (the simulation)
# Usage: scripts/build_site.sh <main checkout> <beta checkout> <sim checkout> <output folder>
set -euo pipefail
MAIN="$1"; BETA="$2"; SIM="$3"; OUT="$4"
rm -rf "$OUT"; mkdir -p "$OUT"
# the live app and its shared files, exactly as they are on main (no build folders, scripts or database files)
( cd "$MAIN" && tar cf - --exclude=.git --exclude=.gitignore --exclude=.github --exclude=./t --exclude=./s --exclude=./scripts --exclude=./supabase --exclude=README.md . ) | ( cd "$OUT" && tar xf - )
LT_BETA_SRC="$BETA" LT_SIM_SRC="$SIM" LT_OUT="$OUT" python3 "$MAIN/scripts/make_beta.py"
# the live page must be main's file byte for byte, and the sim page must never point at the live database
cmp "$MAIN/index.html" "$OUT/index.html"
if grep -q "gbzximehndzlsbojoqgj" "$OUT/s/index.html"; then echo "sim page points at the live project" >&2; exit 1; fi
if ! grep -q "window.LT_BETA = true" "$OUT/t/index.html"; then echo "beta page is missing its switch" >&2; exit 1; fi
if grep -q "window.LT_BETA = true" "$OUT/index.html"; then echo "live page has the beta switch on" >&2; exit 1; fi
( cd "$MAIN" && git rev-parse --short HEAD ) > "$OUT/.built-from" 2>/dev/null || true
echo "site assembled in $OUT"
