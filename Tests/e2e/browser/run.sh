#!/bin/bash
# End-to-end test of the browser bridge against a real Chromium.
#
# Opt-in, because it needs what CI lacks: a logged-in session and a Chromium
# build that still honours --load-extension (Chrome for Testing or Chromium;
# branded Chrome dropped the flag in 137). Point AMCU_E2E_CHROME at the binary:
#
#   AMCU_E2E=1 AMCU_E2E_CHROME="/path/to/Google Chrome for Testing" Tests/e2e/browser/run.sh
#
# The script builds amcu, serves the test site from a local port, starts the
# browser on a throwaway profile with the extension loaded and the native
# messaging manifest placed where that profile reads it, and then drives the
# page through `amcu browser` — snapshot, trusted click, verified fill, select,
# dialogs, frames, upload, stale-ref detection, screenshot, console. It leaves
# the user's own browsers alone.
set -uo pipefail

if [ "${AMCU_E2E:-}" != "1" ]; then
  echo "browser e2e: skipped (set AMCU_E2E=1 and AMCU_E2E_CHROME=/path/to/chromium to run)"
  exit 0
fi
if [ -z "${AMCU_E2E_CHROME:-}" ] || [ ! -x "$AMCU_E2E_CHROME" ]; then
  echo "browser e2e: AMCU_E2E_CHROME must point at a Chromium / Chrome for Testing binary" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
swift build -c release >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }
AMCU="$ROOT/.build/release/amcu"

WORK="$(mktemp -d /tmp/amcu-browser-e2e.XXXXXX)"
PROFILE="$WORK/profile"
EXT="$WORK/extension"
mkdir -p "$PROFILE/NativeMessagingHosts"
PORT=$((20000 + RANDOM % 20000))
BASE="http://127.0.0.1:$PORT"

cleanup() {
  [ -n "${BROWSER_PID:-}" ] && kill "$BROWSER_PID" 2>/dev/null
  [ -n "${SERVER_PID:-}" ] && { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

(cd "$ROOT/Tests/e2e/browser/site" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!

"$AMCU" browser install --manifest-dir "$PROFILE/NativeMessagingHosts" --extension-dir "$EXT" >/dev/null || { echo "install failed" >&2; exit 1; }

"$AMCU_E2E_CHROME" --user-data-dir="$PROFILE" --load-extension="$EXT" --no-first-run --no-default-browser-check \
  --disable-features=ExtensionDisableUnsupportedDeveloper,TranslateUI --window-size=1000,800 --window-position=40,40 \
  "$BASE/index.html" >/dev/null 2>&1 &
BROWSER_PID=$!

# The extension connects within a few seconds; pick the host that belongs to
# the browser we just started (its socket names the browser and pid).
ENDPOINT=""
for _ in $(seq 1 40); do
  ENDPOINT="$("$AMCU" browser doctor --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for e in d.get("connected", []):
    if e["browser"] in ("chrome-for-testing", "chromium", "chrome-canary", "chrome-dev", "chrome-beta"):
        print("%s:%s" % (e["browser"], e["pid"]))
        break
' 2>/dev/null)"
  [ -n "$ENDPOINT" ] && break
  sleep 0.5
done
if [ -z "$ENDPOINT" ]; then
  echo "FAIL: the extension never connected (is $AMCU_E2E_CHROME a build that honours --load-extension?)" >&2
  exit 1
fi
export AMCU_BROWSER="$ENDPOINT"
echo "connected: $ENDPOINT"

PASS=0; FAILS=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { # description, command output, expected substring
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1 — expected '$3' in: $(echo "$2" | head -c 300)"; fi
}
ref_of() { # snapshot text, line pattern -> ref
  echo "$1" | grep -F "$2" | head -1 | sed -n 's/.*\[ref=\([fe0-9]*\)\].*/\1/p'
}

TAB=$("$AMCU" browser tabs --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([t["id"] for t in d["result"]["tabs"] if "index.html" in t["url"]][0])')
"$AMCU" browser tab --select "$TAB" >/dev/null
"$AMCU" browser wait --load --timeout 20 >/dev/null

echo "snapshot"
SNAP="$("$AMCU" browser snapshot)"
check "lists the form controls" "$SNAP" 'button "Submit"'
check "redacts password values" "$SNAP" '[redacted]'
check "hides aria-hidden text" "$(echo "$SNAP" | grep -c 'aria hidden text')" "0"
check "stitches the child frame in" "$SNAP" 'button "Frame button" [ref=f'
check "marks disabled controls" "$SNAP" 'button "Disabled" [ref=e'
[[ "$SNAP" == *'"Disabled" [ref='*'[disabled]'* ]] && ok "disabled attribute" || fail "disabled attribute"

echo "trusted click"
DIV=$(ref_of "$SNAP" 'Click me (div)')
OUT="$("$AMCU" browser click --ref "$DIV")"; check "clicks a pointer-cursor div" "$OUT" "click ok on $DIV"
LOG="$("$AMCU" browser snapshot --selector '#log')"
check "the page saw the click" "$LOG" 'div clicked'
check "the click was trusted" "$(echo "$LOG" | grep -c UNTRUSTED)" "0"

echo "rich contenteditable"
RICH=$(ref_of "$SNAP" 'textbox "first para"')
[ -z "$RICH" ] && RICH=$(echo "$SNAP" | grep -A2 'rich-editor' | grep -o 'ref=e[0-9]*' | head -1 | cut -d= -f2)
RICH=$(echo "$SNAP" | grep 'first para' | sed -n 's/.*\[ref=\([fe0-9]*\)\].*/\1/p' | head -1)
if [ -n "$RICH" ]; then
  OUT="$("$AMCU" browser fill --ref "$RICH" --value 'plain replacement' 2>&1)"
  # Either it verifies as plain text, or it honestly reports a mismatch — never a false "verified" after wiping.
  PARAS="$("$AMCU" browser eval --js "return document.querySelectorAll('#rich-editor p').length + '/' + document.getElementById('rich-editor').textContent")"
  if [[ "$OUT" == *"(verified)"* ]]; then ok "rich fill that verifies really set the value"; else
    [[ "$OUT" == *"value_mismatch"* ]] && ok "rich fill reports mismatch instead of a false success" || fail "rich fill: $OUT"
  fi
  [[ "$PARAS" == *"plain replacement"* ]] && ok "rich editor holds the new text" || fail "rich editor text: $PARAS"
fi

echo "verified fill / type / select"
NAME=$(ref_of "$SNAP" 'textbox "Name"')
check "fill verifies" "$("$AMCU" browser fill --ref "$NAME" --value 'Ada Lovelace')" '(verified)'
check "eval reads it back" "$("$AMCU" browser eval --js "document.getElementById('name').value")" 'Ada Lovelace'
NOTES=$(ref_of "$SNAP" 'textbox "Notes"')
check "type appends" "$("$AMCU" browser type --ref "$NOTES" --text 'hello')" 'value now "hello"'
COUNTRY=$(ref_of "$SNAP" 'combobox "Country"')
check "select-option by label" "$("$AMCU" browser select-option --ref "$COUNTRY" --value 'United States')" 'now "United States"'
check "select-option refuses unknown" "$("$AMCU" browser select-option --ref "$COUNTRY" --value 'Mars' 2>&1)" 'no option matches'
EMAIL=$(ref_of "$SNAP" 'textbox "Email"')
"$AMCU" browser fill --ref "$EMAIL" --value 'a@b.co' >/dev/null
check "type --submit presses Enter" "$("$AMCU" browser type --ref "$NAME" --text '!' --submit)" 'then Enter'
check "the form submitted" "$("$AMCU" browser snapshot --selector '#log')" 'submitted Ada Lovelace!'

echo "dialogs"
ALERT=$(ref_of "$SNAP" 'button "Alert"')
check "a click that opens a dialog returns" "$("$AMCU" browser click --ref "$ALERT" --timeout 10)" 'alert dialog opened'
check "commands refuse while it is open" "$("$AMCU" browser snapshot --selector '#log' 2>&1)" 'dialog_open'
check "dialog --accept" "$("$AMCU" browser dialog --accept)" 'accepted alert'
PROMPT=$(ref_of "$SNAP" 'button "Prompt"')
"$AMCU" browser click --ref "$PROMPT" >/dev/null
check "dialog --accept --text" "$("$AMCU" browser dialog --accept --text Grace)" 'accepted prompt'
check "the prompt value arrived" "$("$AMCU" browser snapshot --selector '#log')" 'prompt=Grace'

echo "frames"
FIN=$(ref_of "$SNAP" 'textbox "frame input"')
FBTN=$(ref_of "$SNAP" 'button "Frame button"')
check "fill inside an iframe" "$("$AMCU" browser fill --ref "$FIN" --value 'in frame')" '(verified)'
check "click inside an iframe" "$("$AMCU" browser click --ref "$FBTN")" "click ok on $FBTN"
check "the frame saw the click" "$("$AMCU" browser snapshot)" 'frame button clicked'
DEEP=$(ref_of "$SNAP" 'button "Deep button"')
DEEPFRAME="${DEEP%e*}"; DEEPFRAME="${DEEPFRAME#f}"
check "a doubly-nested frame is stitched in" "$DEEP" "e"
"$AMCU" browser eval --frame "$DEEPFRAME" --js "document.getElementById('dout').textContent=''; return 1" >/dev/null 2>&1
check "click in a doubly-nested iframe lands right" "$("$AMCU" browser click --ref "$DEEP")" "click ok on $DEEP"
check "the deep frame saw the click" "$("$AMCU" browser eval --frame "$DEEPFRAME" --js "return document.getElementById('dout').textContent")" 'deep clicked'
# A frame click while the main page is scrolled must still land (viewport, not document, coords).
FRAMEID="${FBTN%e*}"; FRAMEID="${FRAMEID#f}"
"$AMCU" browser eval --frame "$FRAMEID" --js "document.getElementById('fout').textContent=''; return 1" >/dev/null 2>&1
"$AMCU" browser scroll --dy -600 >/dev/null
check "a frame click lands with the page scrolled" "$("$AMCU" browser eval --frame "$FRAMEID" --js "document.getElementById('fb').scrollIntoView({block:'center'}); return 1"; "$AMCU" browser click --ref "$FBTN"; "$AMCU" browser eval --frame "$FRAMEID" --js "return document.getElementById('fout').textContent")" 'frame button clicked'

echo "obscured and offscreen"
BOTTOM=$(ref_of "$SNAP" 'button "Bottom button"')
check "scrolls an offscreen element into view" "$("$AMCU" browser click --ref "$BOTTOM")" "click ok on $BOTTOM"
COVER=$(ref_of "$SNAP" 'button "Show overlay"')
"$AMCU" browser click --ref "$COVER" >/dev/null
H1=$(ref_of "$SNAP" 'heading "amcu test page"')
check "refuses a covered element" "$("$AMCU" browser click --ref "$H1" 2>&1)" 'element_obscured'
check "--force falls back to a JS click" "$("$AMCU" browser click --ref "$H1" --force)" 'js:click'

echo "markers and constraints"
SNAP2="$("$AMCU" browser snapshot)"
check "handler-only div gets a ref and [clickable]" "$(echo "$SNAP2" | grep 'JsAction target')" '[clickable]'
JSA=$(ref_of "$SNAP2" 'JsAction target')
"$AMCU" browser click --ref "$JSA" >/dev/null
check "the jsaction div's listener fired" "$("$AMCU" browser snapshot --selector '#log')" 'jsaction clicked'
check "live validation constraints are shown" "$(echo "$SNAP2" | grep 'textbox "Zip"')" 'maxlength=5'
check "opacity-hidden text is flagged" "$(echo "$SNAP2" | grep 'ghost opacity text')" '[unseen=opacity]'
check "near-zero fonts are flagged" "$(echo "$SNAP2" | grep 'tiny font text')" '[unseen=font-size]'
check "colour-on-colour text is flagged" "$(echo "$SNAP2" | grep 'camouflage text')" '[unseen=contrast]'
check "the footer names the snapshot number" "$SNAP2" '(snapshot #'
check "the footer reports scroll context" "$SNAP2" 'the viewport'
# The debugger is attached by now (clicks above), so the listener scan runs.
check "an addEventListener-only div gets a ref and [clickable]" "$(echo "$SNAP2" | grep 'Listener-only target')" '[clickable]'
LSN=$(ref_of "$SNAP2" 'Listener-only target')
"$AMCU" browser click --ref "$LSN" >/dev/null
check "the listener-only div's handler fired" "$("$AMCU" browser snapshot --selector '#log')" 'listener-only clicked'
check "a scroll container is marked with its hidden extent" "$(echo "$SNAP2" | grep -m1 'scrollable:')" 'px below'
SCR=$(echo "$SNAP2" | grep -m1 'scrollable:' | sed -n 's/.*\[ref=\([fe0-9]*\)\].*/\1/p')
"$AMCU" browser scroll --ref "$SCR" --dy -40 >/dev/null
check "scrolling the container moves its extent" "$("$AMCU" browser snapshot | grep -m1 'scrollable:')" 'px above'
# The overlay from the "obscured" section still covers the top of the page.
check "an element under the overlay is marked [covered]" "$(echo "$SNAP2" | grep 'heading "amcu test page"')" '[covered]'
check "find ignores the display-only [covered] marker" "$("$AMCU" browser find --text 'amcu test page' --role heading | grep -c covered)" "0"

echo "new tabs"
NEWTAB=$(ref_of "$SNAP2" 'button "Open new tab"')
OUT="$("$AMCU" browser click --ref "$NEWTAB")"
check "a click that opened a tab reports it" "$OUT" '→ opened tab'
check "the new tab became current for the session" "$OUT" 'now current for this session'
check "the session now reads the new tab" "$("$AMCU" browser tabs | grep current)" 'second.html'
"$AMCU" browser tab --close >/dev/null
"$AMCU" browser tab --select "$TAB" >/dev/null

echo "action effects and diff"
APPEAR=$(ref_of "$SNAP2" 'button "Appear"')
NOOP=$(ref_of "$SNAP2" 'button "Noop"')
"$AMCU" browser snapshot >/dev/null   # diff base
OUT="$("$AMCU" browser click --ref "$APPEAR")"
check "a click reports what appeared" "$OUT" 'appeared: dialog "Popup dialog"'
DIFFOUT="$("$AMCU" browser snapshot --diff)"
check "snapshot --diff shows only the new lines" "$DIFFOUT" '+ - dialog "Popup dialog"'
check "the diff names its base" "$DIFFOUT" 'since snapshot #'
"$AMCU" browser click --ref "$APPEAR" >/dev/null
check "new-since-last refs carry [new]" "$("$AMCU" browser snapshot | grep 'dialog "Popup dialog"' | tail -1)" '[new]'
check "a no-op click says so" "$("$AMCU" browser click --ref "$NOOP")" 'no DOM change observed'

echo "find, --within, wait, secrets"
FOUND="$("$AMCU" browser find --text 'Popup dialog')"
check "find matches the stored snapshot" "$FOUND" 'dialog "Popup dialog"'
check "find reports its generation" "$FOUND" 'in snapshot #'
check "find --role filters" "$("$AMCU" browser find --text 'Submit' --role button)" 'button "Submit"'
check "find takes /regex/" "$("$AMCU" browser find --text '/popup DIALOG/i')" 'dialog "Popup dialog"'
WSNAP="$("$AMCU" browser snapshot --within "$COUNTRY")"
check "--within scopes to the subtree" "$WSNAP" 'option "United States"'
[[ "$WSNAP" != *"Footer text"* ]] && ok "--within excludes the rest of the page" || fail "--within leaked the whole page"
check "wait --url-matches takes a regex" "$("$AMCU" browser wait --url-matches 'index\.html$' --timeout 5)" 'wait ok (url-matches'
SEC="$WORK/sec.env"
printf 'TESTKEY=supersecretvalue99\n' > "$SEC"
check "fill --secret fills from the file" "$("$AMCU" browser fill --ref "$NAME" --secrets "$SEC" --secret TESTKEY)" '(verified)'
check "the page really holds the secret" "$("$AMCU" browser eval --js "document.getElementById('name').value")" 'supersecretvalue99'
check "loaded secrets are masked in output" "$("$AMCU" browser eval --secrets "$SEC" --js "document.getElementById('name').value")" '[secret:TESTKEY]'
SCOPED="$WORK/scoped.env"
printf 'HERE=allowedhere1234\nHERE__DOMAINS=127.0.0.1\nELSEWHERE=refusedvalue5678\nELSEWHERE__DOMAINS=accounts.example.com,*.example.org\n' > "$SCOPED"
check "a secret scoped to this host fills" "$("$AMCU" browser fill --ref "$NAME" --secrets "$SCOPED" --secret HERE)" '(verified)'
check "a secret scoped elsewhere is refused" "$("$AMCU" browser fill --ref "$NAME" --secrets "$SCOPED" --secret ELSEWHERE 2>&1)" 'secret_scope'
check "the refused secret never reached the page" "$("$AMCU" browser eval --js "document.getElementById('name').value")" 'allowedhere1234'
check "a frame field is checked against the frame's host too" "$("$AMCU" browser fill --ref "$FIN" --secrets "$SCOPED" --secret HERE)" '(verified)'

echo "stale refs"
"$AMCU" browser eval --js "document.getElementById('confirm-btn').textContent = 'Changed'; return 1" >/dev/null
CONFIRM=$(ref_of "$SNAP" 'button "Confirm"')
check "a renamed element is stale" "$("$AMCU" browser click --ref "$CONFIRM" 2>&1)" 'stale_snapshot'

echo "upload, screenshot, console, tabs"
FILE=$(ref_of "$SNAP" 'button "Choose file"')
echo hi > "$WORK/up.txt"
check "upload" "$("$AMCU" browser upload --ref "$FILE" --file "$WORK/up.txt")" 'upload ok'
check "the page received the file" "$("$AMCU" browser snapshot --selector '#log')" 'files: up.txt'
check "screenshot writes a file" "$("$AMCU" browser screenshot --out "$WORK/shot.png")" 'wrote'
[ -s "$WORK/shot.png" ] && ok "screenshot is non-empty" || fail "screenshot is empty"
check "console replays earlier messages" "$("$AMCU" browser console)" 'early warning'
check "tab --new opens in amcu's background window" "$("$AMCU" browser tab --new --url "$BASE/second.html")" "background window"
check "wait --text sees late content" "$("$AMCU" browser wait --text 'late content' --timeout 10)" 'wait ok'
check "tab --close" "$("$AMCU" browser tab --close)" 'closed tab'
check "detach" "$("$AMCU" browser detach --tab "$TAB")" 'detached from tab'

echo
echo "$PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
