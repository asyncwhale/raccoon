#!/usr/bin/env bash
# Window-only screenshot helper for Raccoon (privacy: never captures the full screen).
#
# Resolves the target window's on-screen rect and captures ONLY that rect. Two strategies,
# tried in order, so it works whether or not a pyobjc/Quartz Python is installed:
#
#   1) CGWindowList via Python+Quartz (exact window, includes shadow) — used if `import
#      Quartz` succeeds. Picks the largest titled window owned by $RACCOON_OWNER and runs
#      `screencapture -l <windowID> -o`.
#   2) Accessibility bounds via AppleScript (no Quartz needed) — reads position+size of the
#      requested Raccoon window and runs `screencapture -R x,y,w,h` (rect-only, window-sized).
#
# Usage:   scripts/screenshot.sh [output.png] [window_index]
# Env:     RACCOON_OWNER  owner/app name to match (default: Raccoon)
#
# Exits non-zero (no full-screen fallback) if neither strategy can resolve the window.

set -uo pipefail

OUT="${1:-raccoon-shot.png}"
WIN_INDEX="${2:-1}"
OWNER="${RACCOON_OWNER:-Raccoon}"

# --- Strategy 1: CGWindowList (Quartz) ---------------------------------------
WINDOW_ID=""
if /usr/bin/env python3 -c "import Quartz" >/dev/null 2>&1; then
    WINDOW_ID="$(/usr/bin/env python3 - "$OWNER" <<'PY'
import sys, Quartz
owner = sys.argv[1]
opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
infos = Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []
best, best_area = None, -1
for w in infos:
    if w.get("kCGWindowOwnerName") != owner:
        continue
    b = w.get("kCGWindowBounds", {})
    width, height = b.get("Width", 0), b.get("Height", 0)
    area = width * height
    if area > best_area and width > 200 and height > 200:
        best_area, best = area, w.get("kCGWindowNumber")
print(best if best is not None else "")
PY
)"
fi

if [[ -n "${WINDOW_ID}" ]]; then
    /usr/sbin/screencapture -l "${WINDOW_ID}" -o "${OUT}"
    echo "Saved (CGWindow ${WINDOW_ID}) -> ${OUT}"
    exit 0
fi

# --- Strategy 2: Accessibility bounds via AppleScript ------------------------
BOUNDS="$(/usr/bin/osascript -e "
tell application \"System Events\" to tell process \"${OWNER}\"
  set p to position of window ${WIN_INDEX}
  set s to size of window ${WIN_INDEX}
  return ((item 1 of p) as integer) & \",\" & ((item 2 of p) as integer) & \",\" & ((item 1 of s) as integer) & \",\" & ((item 2 of s) as integer)
end tell" 2>/dev/null || true)"

if [[ -z "${BOUNDS}" ]]; then
    echo "screenshot.sh: could not resolve a ${OWNER} window (running? Screen Recording + Accessibility allowed?)" >&2
    exit 1
fi

IFS=',' read -r X Y W H <<< "${BOUNDS}"
/usr/sbin/screencapture -R"${X},${Y},${W},${H}" -o "${OUT}"
echo "Saved (AX rect ${BOUNDS}) -> ${OUT}"
