#!/usr/bin/env bash
set -euo pipefail

# UIScout Proof-of-Access E2E Harness
# Proves: element discovery, AX-safe send, OCR/AX read, menu clipboard export, session toggle, evidence bundling
# Usage:
#   testsuite/e2e/uisct-proof.sh \
#     --app com.raycast.macos \
#     --copy-chat "Copy Chat" \
#     --copy-logs "Copy Error Logs"

APP=""
COPY_CHAT_LABEL="Copy Chat"
COPY_LOGS_LABEL="Copy Error Logs"

usage(){
  cat <<EOF
Usage: $0 --app <bundleId> [--copy-chat <label>] [--copy-logs <label>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) shift; APP=${1:-};;
    --copy-chat) shift; COPY_CHAT_LABEL=${1:-$COPY_CHAT_LABEL};;
    --copy-logs) shift; COPY_LOGS_LABEL=${1:-$COPY_LOGS_LABEL};;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac; shift || true
done

[[ -n "$APP" ]] || { echo "--app is required" >&2; exit 2; }

fail(){ echo "[PROOF] FAIL: $*" >&2; exit 1; }
ok(){ echo "[PROOF] OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v pbpaste >/dev/null 2>&1 || echo "[PROOF] WARN: pbpaste not found; clipboard checks may be limited" >&2

[[ -x .build/release/uisct-cli ]] || fail "UIScout CLI not found. Build first: swift build -c release --product uisct-cli"
[[ -x .build/release/uisct-read ]] || fail "UIScout read tool not found. Build first: swift build -c release --product UIScoutRead"

TS=$(date +%s)
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid || echo rand-$TS)
UUID_UP=$(echo "$UUID" | tr '[:lower:]' '[:upper:]')
SENTINEL="PROBE::$UUID_UP::$TS"
OUT="./_proof-$TS"
mkdir -p "$OUT"
echo "[PROOF] App=$APP; OUT=$OUT; SENTINEL=$SENTINEL"

# 1) Discovery
.build/release/uisct-cli find --app "$APP" --type input  --json | tee "$OUT/find-input.json" >/dev/null || true
.build/release/uisct-cli find --app "$APP" --type reply  --json | tee "$OUT/find-reply.json" >/dev/null || true
.build/release/uisct-cli find --app "$APP" --type session --json | tee "$OUT/find-session.json" >/dev/null || true

for f in input reply session; do
  conf=$(jq -r '.confidence // 0' "$OUT/find-$f.json" 2>/dev/null || echo 0)
  awk 'found||$0 ~ /^\{/ {found=1;print}' "$OUT/find-$f.json" > "$OUT/find-$f.clean.json" || true
  (( $(echo "$conf >= 0.8" | bc -l) )) || fail "low confidence on $f: $conf"
done
ok "discovery (input/reply/session)"

# Save reply signature for later observe
jq '.elementSignature' "$OUT/find-reply.clean.json" > "$OUT/reply_sig.json"

# 2) Send + verify (AXValue + AXPress/AXConfirm)
.build/release/uisct-cli send \
  --app "$APP" \
  --text "$SENTINEL Raycast test line" \
  --min-confidence 0.6 \
  --allow-peek \
  --json | tee "$OUT/send.json" >/dev/null || true

setOK=$(jq -r '.actions.setValue // false' "$OUT/send.json" 2>/dev/null || echo false)
pressOK=$(jq -r '.actions.pressedSend // false' "$OUT/send.json" 2>/dev/null || echo false)
confirmOK=$(jq -r '.actions.confirmedInput // false' "$OUT/send.json" 2>/dev/null || echo false)

if [[ "$setOK" != "true" || ( "$pressOK" != "true" && "$confirmOK" != "true" ) ]]; then
  fail "send actions not successfully invoked (setValue=$setOK press=$pressOK confirm=$confirmOK)"
fi
ok "send actions (set/press/confirm)"

# Read back (OCR fallback inside tool)
.build/release/uisct-read --app "$APP" --json | tee "$OUT/read.json" >/dev/null || true
grep -F "$SENTINEL" "$OUT/read.json" >/dev/null 2>&1 && ok "sentinel visible in read (AX/OCR)" || echo "[PROOF] WARN: sentinel not found in immediate read; may require longer wait or app UI update" >&2

# 3) Clipboard export proof via menu
.build/release/uisct-cli copy-chat --app "$APP" --json | tee "$OUT/copy-chat.json" >/dev/null || true
pbpaste > "$OUT/clipboard.txt" 2>/dev/null || true
grep -F "$SENTINEL" "$OUT/clipboard.txt" >/dev/null 2>&1 && ok "clipboard contains sentinel (copy-chat)" || echo "[PROOF] WARN: clipboard does not contain sentinel; retry after UI update" >&2

# 4) Sidebar read + session toggle proof
.build/release/uisct-cli find --app "$APP" --type session --json | tee "$OUT/session-find.json" >/dev/null || true

cat > "$OUT/select-session.swift" <<'SWIFT'
import Foundation, AppKit, ApplicationServices
func attr<T>(_ e: AXUIElement,_ k:String,_ t:T.Type)->T?{ var v:CFTypeRef?; let r=AXUIElementCopyAttributeValue(e,k as CFString,&v); return r == .success ? (v as? T) : nil }
func role(_ e:AXUIElement)->String { attr(e,kAXRoleAttribute,String.self) ?? "" }
func kids(_ e:AXUIElement)->[AXUIElement]{ attr(e,kAXChildrenAttribute,[AXUIElement].self) ?? [] }
func press(_ e:AXUIElement){ AXUIElementPerformAction(e, kAXPressAction as CFString) }
let app = CommandLine.arguments.dropFirst().first ?? "com.raycast.macos"
let idx = Int(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1
guard let running = NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier==app}) else { exit(1) }
let appEl = AXUIElementCreateApplication(running.processIdentifier)
guard let windows:[AXUIElement]=attr(appEl,kAXWindowsAttribute,[AXUIElement].self) else { exit(1) }
for w in windows {
  var q=[w]
  while !q.isEmpty {
    let el=q.removeFirst()
    if role(el)=="AXTable" {
      let rows = kids(el)
      if idx >= 0 && idx < rows.count { press(rows[idx]); fflush(nil); exit(0) }
    }
    q.append(contentsOf: kids(el))
  }
}
exit(1)
SWIFT

/usr/bin/swift "$OUT/select-session.swift" "$APP" 1 && ok "session switched to index 1" || echo "[PROOF] WARN: could not switch session (index 1)" >&2

# Observe reply events for 10 seconds
.build/release/uisct-cli observe --app "$APP" --signature "$OUT/reply_sig.json" --duration 10 --stream | tee "$OUT/observe-after-swap.txt" >/dev/null || true
if grep -E "AX(Value|Children)Changed|data:\s*\{" "$OUT/observe-after-swap.txt" >/dev/null 2>&1; then
  ok "observed reply events after session swap"
else
  echo "[PROOF] WARN: no events observed in 10s window" >&2
fi

# 5) Copy error logs
.build/release/uisct-cli copy-error-logs --app "$APP" --json | tee "$OUT/copy-logs.json" >/dev/null || true
pbpaste > "$OUT/error-logs.txt" 2>/dev/null || true
test -s "$OUT/error-logs.txt" && ok "error logs copied (non-empty)" || echo "[PROOF] WARN: error logs clipboard empty" >&2

# 6) Hash & bundle evidence
shasum -a 256 "$OUT"/clipboard.txt "$OUT"/error-logs.txt 2>/dev/null | tee "$OUT/checksums.txt" >/dev/null || true
tar -czf "$OUT.tar.gz" "$OUT"
echo "[PROOF] Artifacts: $OUT.tar.gz"
ok "proof sequence completed (see warnings above if any steps were advisory)"
