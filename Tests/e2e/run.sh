#!/bin/bash
# End-to-end verification against live AppKit windows.
#
# Opt-in (AMCU_E2E=1) because everything here needs what CI does not have: a
# logged-in window server session, Accessibility permission for this shell's
# responsible process, and Automation permission for System Events. These
# scenarios exist because they caught real bugs no unit test could — viewport
# culling against the wrong reference frame, ScreenCaptureKit aborting the
# process when no window server is reachable.
#
# bash 3.2 compatible (macOS ships nothing newer at /bin/bash).
set -u

if [ "${AMCU_E2E:-}" != "1" ]; then
    echo "skipped: end-to-end tests need a logged-in UI session with Accessibility and"
    echo "Automation permissions; set AMCU_E2E=1 to opt in."
    exit 0
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
E2E="$ROOT/Tests/e2e"
AMCU="$ROOT/.build/release/amcu"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amcu-e2e.XXXXXX")"
# A per-run session name so the suite never clobbers snapshot state a human
# (or an agent) is holding in the default session.
SESSION="e2e-$$"

PIDS=""
cleanup() {
    for pid in $PIDS; do
        kill "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

FAILURES=0
pass() { echo "  ok   $1"; }
fail() {
    echo "  FAIL $1"
    shift
    while [ $# -gt 0 ]; do
        echo "       $1"
        shift
    done
    FAILURES=$((FAILURES + 1))
}

assert_matches() { # description haystack extended-regex
    if echo "$2" | grep -Eq "$3"; then
        pass "$1"
    else
        fail "$1" "expected match: $3" "actual (first 15 lines):" "$(echo "$2" | head -15)"
    fi
}

assert_not_matches() { # description haystack extended-regex
    if echo "$2" | grep -Eq "$3"; then
        fail "$1" "expected NO match: $3" "matching lines:" "$(echo "$2" | grep -E "$3" | head -5)"
    else
        pass "$1"
    fi
}

assert_eq() { # description actual expected
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected: $3" "actual:   $2"
    fi
}

launch_probe() { # binary-name -> sets PROBE_PID, waits for its window
    "$WORK/$1" &
    PROBE_PID=$!
    PIDS="$PIDS $PROBE_PID"
    local i=0
    while [ $i -lt 50 ]; do
        if "$AMCU" windows --app "pid:$PROBE_PID" 2>/dev/null | grep -q "index="; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "probe $1 (pid $PROBE_PID) never published a window" >&2
    exit 1
}

frontmost() {
    osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'
}

echo "== building amcu and probes =="
(cd "$ROOT" && swift build -c release >/dev/null) || { echo "swift build failed" >&2; exit 1; }
for probe in TableProbe TextProbe CanvasProbe ComboProbe; do
    swiftc -O -o "$WORK/$probe" "$E2E/$probe.swift" -framework AppKit \
        || { echo "swiftc failed for $probe" >&2; exit 1; }
done

# Selection helper: finds the target app's focused element and sets
# AXSelectedTextRange, so the replace test runs against a real selection
# instead of whatever the field editor happened to leave behind.
cat > "$WORK/SelectRange.swift" <<'EOF'
import ApplicationServices
guard CommandLine.arguments.count == 4,
      let pid = pid_t(CommandLine.arguments[1]),
      let location = Int(CommandLine.arguments[2]),
      let length = Int(CommandLine.arguments[3]) else { exit(2) }
let app = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
      let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { exit(3) }
let element = value as! AXUIElement
var range = CFRange(location: location, length: length)
guard let axRange = AXValueCreate(.cfRange, &range) else { exit(4) }
exit(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success ? 0 : 5)
EOF
swiftc -O -o "$WORK/SelectRange" "$WORK/SelectRange.swift" \
    || { echo "swiftc failed for SelectRange" >&2; exit 1; }

echo "== table: viewport culling follows the scroll position =="
launch_probe TableProbe
TABLE_PID=$PROBE_PID
# The probe scrolls on its first runloop turn; give it a beat to settle.
sleep 1
TABLE_SNAP="$("$AMCU" snapshot --app "pid:$TABLE_PID" --session "$SESSION" 2>&1)"
# Rows near the scroll target must survive; ROW-0 (visible only before the
# scroll, and exactly what the old table-frame culling kept) must not.
assert_matches "culled snapshot keeps rows near ROW-150" "$TABLE_SNAP" '"ROW-1[3-5][0-9]"'
assert_not_matches "culled snapshot drops ROW-0" "$TABLE_SNAP" '"ROW-0"'
assert_matches "hidden rows are announced, not silent" "$TABLE_SNAP" 'offscreen rows'

echo "== table: --no-shaping returns every row =="
UNSHAPED="$("$AMCU" snapshot --app "pid:$TABLE_PID" --session "$SESSION-unshaped" --no-shaping 2>&1)"
DISTINCT_ROWS=$(echo "$UNSHAPED" | grep -oE '"ROW-[0-9]+"' | sort -u | wc -l | tr -d ' ')
assert_eq "--no-shaping exposes all 200 distinct rows" "$DISTINCT_ROWS" "200"

echo "== table: click by index after culling =="
# Re-snapshot into the working session so the click resolves against the
# culled tree it is meant to exercise.
TABLE_SNAP="$("$AMCU" snapshot --app "pid:$TABLE_PID" --session "$SESSION" 2>&1)"
ROW_INDEX=$(echo "$TABLE_SNAP" | awk '$2 == "Row" { print $1; exit }')
FRONT_BEFORE="$(frontmost)"
if [ -z "$ROW_INDEX" ]; then
    fail "a visible row exists to click" "no 'Row' line in snapshot" "$(echo "$TABLE_SNAP" | head -10)"
else
    if "$AMCU" click --element "$ROW_INDEX" --session "$SESSION" >/dev/null 2>&1; then
        pass "click --element $ROW_INDEX on a culled-snapshot row exits 0"
    else
        fail "click --element $ROW_INDEX on a culled-snapshot row exits 0" "exit code: $?"
    fi
fi

echo "== text field: set-value verifies, replace respects the selection =="
launch_probe TextProbe
TEXT_PID=$PROBE_PID
sleep 0.5
TEXT_SNAP="$("$AMCU" snapshot --app "pid:$TEXT_PID" --session "$SESSION" 2>&1)"
FIELD_INDEX=$(echo "$TEXT_SNAP" | awk '$2 == "TextField" { print $1; exit }')
if [ -z "$FIELD_INDEX" ]; then
    fail "text probe exposes a TextField" "no 'TextField' line in snapshot" "$(echo "$TEXT_SNAP" | head -10)"
else
    SET_OUT="$("$AMCU" set-value --element "$FIELD_INDEX" --value "hello world" --session "$SESSION" 2>&1)"
    assert_matches "set-value reads back as verified" "$SET_OUT" '\(verified\)'
    # A scenario where the app *rejects* the written value (to prove the
    # mismatch path fails loudly) is skipped here: NSTextField accepts any
    # string, and NSStepper/NSSlider clamp numerically but expose numeric
    # AXValue types this text-oriented path never writes. Constructing a
    # rejecting control would mean shipping a custom NSAccessibility
    # implementation built to lie, which tests the probe, not amcu.
    echo "  skip value-rejection scenario (no stock AppKit control refuses a string AXValue write)"

    if "$WORK/SelectRange" "$TEXT_PID" 0 5; then
        REPLACE_OUT="$("$AMCU" replace --element "$FIELD_INDEX" --text "goodbye" --session "$SESSION" 2>&1)"
        assert_matches "replace targets the selection, not the whole value" "$REPLACE_OUT" 'replaced selection'
        assert_matches "replace reads back as verified" "$REPLACE_OUT" '\(verified\)'
        AFTER_SNAP="$("$AMCU" snapshot --app "pid:$TEXT_PID" --session "$SESSION-after" 2>&1)"
        assert_matches "only the selected range was replaced" "$AFTER_SNAP" '"goodbye world"'
    else
        fail "AXSelectedTextRange could be set on the focused field" "SelectRange helper exit: $?"
    fi
fi

echo "== canvas: an accessibility-blind window says so =="
launch_probe CanvasProbe
CANVAS_SNAP="$("$AMCU" snapshot --app "pid:$PROBE_PID" --session "$SESSION-canvas" 2>&1)"
assert_matches "blind window is reported, not shown as empty" "$CANVAS_SNAP" 'no actionable accessibility elements'

echo "== combo box: subtree suppression yields to the drop-down button =="
launch_probe ComboProbe
sleep 0.5
COMBO_SNAP="$("$AMCU" snapshot --app "pid:$PROBE_PID" --session "$SESSION-combo" 2>&1)"
assert_matches "both labelled combo boxes are present" "$COMBO_SNAP" 'ComboBox.*"Flavour"'
assert_matches "both labelled combo boxes are present (idle)" "$COMBO_SNAP" 'ComboBox.*"Topping"'
# The drop-down button must appear *inside* the given combo box: find its
# ComboBox line by label, then look for a Button at deeper indentation before
# the tree pops back out. (Window chrome buttons are hidden by the probe, so
# nothing else could satisfy a bare "Button" match — the nesting check keeps
# it honest anyway.)
nested_button() { # snapshot-text combo-label -> "found" on stdout, or nothing
    echo "$1" | awk -v label="\"$2\"" '
        inside {
            i = match($0, /[0-9]/)
            if (i > 0 && i <= indent) { inside = 0 }
            else if ($2 == "Button") { print "found"; exit }
        }
        /ComboBox/ && index($0, label) { indent = match($0, /[0-9]/); inside = 1 }
    '
}
FOCUSED_BUTTON=$(nested_button "$COMBO_SNAP" "Flavour")
IDLE_BUTTON=$(nested_button "$COMBO_SNAP" "Topping")
assert_eq "focused combo's drop-down button is visible (focus chain)" "${FOCUSED_BUTTON:-missing}" "found"
# The unfocused combo is the decisive case: no focus protects it, so only the
# actionable-direct-child rule can be keeping its button in the snapshot.
assert_eq "unfocused combo's drop-down button is visible (actionable child)" "${IDLE_BUTTON:-missing}" "found"
assert_matches "focus inside the compact control survives shaping" "$COMBO_SNAP" '\(focused\)'

echo "== frontmost application was never disturbed =="
FRONT_AFTER="$(frontmost)"
assert_eq "frontmost app unchanged across all action commands" "$FRONT_AFTER" "$FRONT_BEFORE"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES assertion(s) failed"
    exit 1
fi
echo "all e2e assertions passed"
