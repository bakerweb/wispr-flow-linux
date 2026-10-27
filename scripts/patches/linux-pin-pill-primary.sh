#!/usr/bin/env bash
#===============================================================================
# linux-pin-pill-primary.sh -- park the status pill on the primary display on
# Linux instead of chasing the cursor, in the Wispr Flow main bundle
# (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ----------------------
# Every 400 ms the main process's `monitorMove` interval moves the pill window
# to `screen.getDisplayNearestPoint(screen.getCursorScreenPoint())`. Under
# XWayland (WISPR_USE_X11=1, the backend that keeps the pill above other
# windows on KDE) the cursor point only updates while the pointer is over an
# X11 surface, so on a multi-monitor desk the pill sticks to whichever display
# last saw the pointer cross an XWayland window, usually where the Hub opened.
# The primary display is stable and is what the user configured.
#
# THE PATCH
# ---------
# Anchored on the developer log string that opens the interval's critical
# section (1.6.1209):
#
#   ...skipping monitorMove interval");await <mx>.acquire();
#   const{getCursorScreenPoint:<c>,getDisplayNearestPoint:<d>}=<el>.screen,
#   <n>=<d>(<c>())
#
# The `<n>=` initializer becomes a Linux-gated ternary:
#
#   <n>=/*WISPR_LINUX_PIN_PILL_PRIMARY*/"linux"===process.platform&&
#     !process.env.WISPR_PILL_FOLLOW_CURSOR?<el>.screen.getPrimaryDisplay():
#     <d>(<c>())
#
# All identifiers are captured, not hardcoded. The sibling contextMenuMove
# interval has the same destructure but a different log string, so it is left
# alone. Set WISPR_PILL_FOLLOW_CURSOR=1 to get upstream's behaviour back.
#
# Usage: linux-pin-pill-primary.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_PIN_PILL_PRIMARY" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

anchor = re.compile(
	r'(?P<head>skipping monitorMove interval"\);await [\w$]+\.acquire\(\);'
	r'const\{getCursorScreenPoint:(?P<c>[\w$]+),'
	r'getDisplayNearestPoint:(?P<d>[\w$]+)\}=(?P<el>[\w$]+)\.screen,'
	r'(?P<n>[\w$]+)=)(?P=d)\((?P=c)\(\)\)'
)
matches = list(anchor.finditer(src))
EXPECTED = 1
if len(matches) != EXPECTED:
	sys.exit(
		f"ERROR: expected exactly {EXPECTED} monitorMove display lookup(s), "
		f"found {len(matches)}. Bundle layout may have changed; re-audit the "
		f"'skipping monitorMove interval' site before patching."
	)

def pin(m):
	el, c, d = m.group("el"), m.group("c"), m.group("d")
	return (
		m.group("head")
		+ "/*" + marker + '*/"linux"===process.platform'
		+ "&&!process.env.WISPR_PILL_FOLLOW_CURSOR"
		+ "?" + el + ".screen.getPrimaryDisplay():"
		+ d + "(" + c + "())"
	)

patched, n = anchor.subn(pin, src, count=EXPECTED)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(patched)
print(f"Patched: status pill pinned to the primary display on Linux at {n} "
      f"site(s).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker

patch_finish "status pill pinned to the primary display on Linux in $BUNDLE"
