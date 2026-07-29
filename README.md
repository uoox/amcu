# amcu — another macOS computer use

Read and drive macOS applications **without taking over the screen**.

amcu is a small, dependency-free command-line tool for computer-use agents on macOS. It reads an application's accessibility tree, and clicks, types, scrolls and drags inside a target window — while you keep using your Mac. The cursor does not move. Focus does not change. The window does not come to the front.

```console
$ amcu snapshot --app com.apple.textedit
app: TextEdit [com.apple.textedit]
window: Untitled id=8471 frame=(320,180 700x520)
coordinates: window-relative
0 Window [StandardWindow] "Untitled" @0,0 700x520 actions:Raise
  1 ScrollArea @0,52 700x468
    2 TextArea = "" (focused) @0,52 700x468
  3 Button "Close" @12,12 14x14
  ...

$ amcu click --element 3
click ok on element 3 via ax:AXPress
```

## Why

Most macOS automation tools are *foreground* automation: they activate the target application, move the real cursor, and post events to the global HID stream. While the agent works, the machine is not yours — and on a shared cursor, you and the agent fight over every click.

Doing better requires three things, and amcu does all three:

1. **Read semantically, not visually.** The accessibility tree gives roles, labels, values and available actions. It is faster than screenshots, costs an order of magnitude fewer tokens, and yields element references that survive the window moving.
2. **Act semantically where possible.** `AXPress` on a button needs no coordinates at all, and works even when the control is occluded.
3. **Route coordinate events to a window, not to the screen.** When a real positioned click is unavoidable, deliver it to the target process and window instead of the global event stream.

Point 3 is where most implementations stop, because the obvious approach appears not to work. See below.

## How window-routed clicks actually work

Posting a mouse event with `CGEvent.postToPid` looks like it should give you a background click. In practice people try it, find that **every click lands at the top-left corner of the window**, and conclude that positioned pid-routed mouse events are broken on modern macOS.

They are not. Two things must both be true:

| | window association | landing point |
|---|---|---|
| plain `postToPid` | ✗ not associated with any window | wrong |
| window id in fields 51/52 | ✓ | ✗ collapses to the window's corner |
| `CGEventSetWindowLocation` only | ✗ | wrong |
| **both together** | ✓ | ✓ **exact** |

So a correct background click needs the window id written to `kCGMouseEventWindowUnderMousePointer` (field 51) **and** `…ThatCanHandleThisEvent` (field 52), **and** the window-local point set through `CGEventSetWindowLocation`. Setting only the fields is the failure mode that produces the corner-click myth.

Measured on macOS 27.0 (26A5388g), aiming at window-local (200, 182) of a background window while another application was frontmost:

```
window id fields only   → delivered to window, landed at (0, 332)   ← the corner
CGEventSetWindowLocation only → not routed to the window at all
both                    → delivered to window, landed at (200, 150) ← exact
```

The real cursor never moved and the frontmost application never changed.

## The catch, and what amcu does about it

`CGEventSetWindowLocation` is **not public API**. It is resolved at runtime with `dlsym`, and Apple can change or remove it. Worse, its likely failure mode is quiet: clicks keep being delivered, they just stop landing where they were aimed — the kind of breakage that corrupts data before anyone notices.

So amcu does not trust the symbol's presence. On first use for a given OS build it runs a **self-check**: it opens its own throwaway window, clicks it at a deliberately asymmetric point through the full background path, and verifies where the click actually arrived. Only an exact hit counts as usable. The verdict is cached per OS build, so the cost is paid once per system update.

```console
$ amcu doctor
amcu doctor — 27.0 (26A5388g)
  [ok] accessibility: reading and acting on user interfaces is permitted
  [ok] screen_recording: window capture is permitted
  [ok] ax window ids: resolvable
  [ok] background pointer delivery: window-routed pointer events land accurately (verified on build 27.0 (26A5388g))
```

If the self-check ever fails, background coordinate clicks are refused with an explanation rather than silently misfiring, and you are pointed at the two paths that do not depend on private API: semantic element actions, and explicit `--mode foreground`.

## Install

Requires macOS 14 or later and a Swift toolchain (the Command Line Tools are enough — no Xcode needed).

```bash
git clone https://github.com/uoox/amcu
cd amcu
swift build -c release
cp .build/release/amcu /usr/local/bin/
```

Then grant permissions to whatever runs amcu (your terminal, or the agent host):

- **Accessibility** — required for everything.
- **Screen Recording** — only for `amcu screenshot`.

`amcu doctor --request` triggers the system prompts.

## Usage

```
INSPECT
  amcu apps                                  list running applications
  amcu windows    --app S                    list windows with ids and frames
  amcu snapshot   --app S                    capture the accessibility tree as indexed text
  amcu scan       --app S                    optical fallback: recognise text and where it is
  amcu menu       --app S                    read the menu bar without opening it
  amcu focus      --app S                    report what currently has keyboard focus
  amcu doctor                                check permissions, verify background delivery

ACT
  amcu click      --app S --element N        press an element by its snapshot index
  amcu click      --app S --at X,Y           click a point (window-relative unless --screen)
  amcu action     --element N --action A     perform any action the element advertises
  amcu set-value  --element N --value V      set an element's value, then read it back
  amcu replace    --element N --text T        replace the selection through the accessibility API
  amcu type       --app S --text T           type literal text
  amcu paste      --app S --text T           paste via the pasteboard (input-method safe)
  amcu key        --app S --key K --mod cmd  press a key combination
  amcu menu-item  --app S --path "A > B"     invoke a menu command
  amcu scroll     --app S --dy N             scroll
  amcu drag       --app S --from X,Y --to X,Y
  amcu screenshot --app S --out FILE         capture one window, occluded or not
  amcu window     --app S --raise|--move X,Y|--resize W,H|--minimize|--restore
```

### Menus, without opening them

An application's menu bar is readable whether or not it is frontmost, and the
items *and their keyboard equivalents* come back without pressing anything — so
looking around a menu puts nothing on screen.

```console
$ amcu menu --app com.example.app --filter export
File > Export > PDF…	[cmd+shift+e]
```

`menu-item` uses that: when an item advertises a keyboard equivalent, the
shortcut is sent to the process and the command runs with no menu appearing at
all. Only items without a shortcut fall back to pressing the menu, which may
briefly show it.

```console
$ amcu menu-item --app com.example.app --path "File > Export > PDF…"
menu-item ok on File > Export > PDF… via shortcut:cmd+shift+e
```

### When there is no accessibility tree

Some windows draw their own interface and publish nothing useful. `snapshot`
says so rather than returning a plausible-looking empty tree:

```console
$ amcu snapshot --app com.example.canvas
...
(this window exposes no actionable accessibility elements — it may render its
own interface; try `amcu scan` for an optical fallback)
```

`scan` recognises the text in the window and gives each piece an index in the
**same space** accessibility elements use, so `click --element N` works either
way. `--annotate out.png` writes a numbered overlay for a model to look at.

This is deliberately *addressable vision*, not a vision agent: amcu reports
text and where it is, and leaves interpretation to the model driving it. What
that model lacks is not the ability to read a screenshot — it is a way to turn a
point in that screenshot into an accurate click on a window nobody is looking
at, and that is the part amcu already solved.

The trade-off is stated in the output: recognised text carries no role, no
state and no actions — a disabled button and a caption look identical. It also
cannot be re-verified before a click the way an element can, so scans expire
(`--max-age`, default 60s) instead of silently going stale.

### Writes are read back

`set-value` and `replace` write through the accessibility API and read the value
back. A write the application silently refused is reported as a failure carrying
both strings, not as success:

```console
$ amcu set-value --element 7 --value "hello"
set-value ok on element 7 via ax:AXValue (verified)
```

`replace` edits `AXValue` at the selected range. It needs no focus, no front
window and no compatible input method — and unlike synthesised keystrokes, the
result can be verified at all. When the element exposes no selection range it
falls back to replacing the whole value and says which it did.

### Snapshots are shaped, and say so

An unfiltered tree is mostly scaffolding. Chrome used to fill the entire
1500-node budget and truncate — which reads to a model as "the rest of the page
does not exist". Structural containers with no label, value or behaviour are
skipped while their children are still walked, controls whose label already says
everything are not expanded, and long tables report only the rows actually on
screen. Chrome now captures in ~800 nodes without truncating.

What was hidden is counted in the output. `--no-shaping` turns all of it off.

```
(hidden: 341 structural containers, 186 offscreen rows)
```

### Reaching Chromium and Electron hierarchies

Whitelisted hosts are asked to publish their accessibility tree — only
`AXManualAccessibility`, never `AXEnhancedUserInterface`, because that second
flag makes `AXPosition` writes be ignored and would quietly break this tool's
own `window --move`.

Measured honestly: on macOS 27 it changed nothing. Chrome reported 151 nodes
before activation and 152 after; Lark, a genuine Electron app with a real
window, reported 502 both times. Recent macOS appears to enable Chromium
accessibility on its own once any assistive client is active. The flag is kept
because it is one idempotent write, it is what these hosts document, and older
systems may still need it — but it is a defensive measure that demonstrated no
benefit here, not a fix for anything observed.

### Typing goes where the target's focus is

Keystrokes land on whatever is focused *inside* the target application, which is
the quietest way for automation to go wrong. Every typing command resolves the
focus and reports it, and `--expect-focus` turns an assumption into a check:

```console
$ amcu type --app com.example.app --text "hello" --expect-focus "Search"
error [element_not_found]: focus is on TextArea "Notes", which does not match 'Search'
  next: Focus the intended field before typing.
```

Add `--json` to any command for machine-readable output on stdout and structured errors on stderr.

### Selectors

`--app` accepts a bundle id, `pid:1234`, or an application name. **Prefer bundle ids**: display names are localized, so `--app Finder` fails on a Chinese system where the same application is `访达`. `--window-id` and `--window-index` pick among an application's windows.

### Element indices are checked, not trusted

Indices come from the most recent `snapshot` in the same `--session`. Before acting, amcu re-resolves the element by its recorded path and verifies the role and label still match. If the interface changed underneath, you get a `stale_snapshot` error instead of a click on whatever moved into that position.

```console
$ amcu click --element 4 --session inbox
error [stale_snapshot]: element 4 changed label ("Archive" -> "Delete")
  next: Re-run `amcu snapshot`; the interface changed after it was captured.
```

### Delivery modes

- `--mode auto` (default) — semantic action if the element offers one, otherwise verified background delivery. **Never falls back to foreground silently**: stealing focus is a visible side effect, so it has to be asked for.
- `--mode background` — window-routed, cursor stays put.
- `--mode foreground` — global event tap. Moves the cursor and takes focus. Correct only when the target is already frontmost.

### Errors are written for agents

Every failure carries a machine-readable code and concrete next steps, including when *not* to retry:

```console
$ amcu click --app Gmail --at 100,200
error [app_not_found]: no running application matched 'Gmail'
  next: Run `amcu apps` to list running applications with their pid and bundle id.
  next: Prefer a bundle id (com.apple.finder) or pid:1234 over a display name — display names are localized and differ per system language.
  next: If the target is a website, select the browser application that shows it; selectors address desktop applications, not web pages.
  next: Do not retry the same selector unchanged.
```

## What amcu will not do

- **Values that announce themselves as secrets are withheld.** A snapshot goes
  straight to a model and usually into a transcript. Any element whose role,
  subrole, placeholder or identifier mentions a password, passcode, one-time
  code or token has its value replaced with `[redacted]`. This matters even for
  well-behaved controls: AppKit's `NSSecureTextField` does mask its characters,
  but it publishes the mask *at the original length* in private-use glyphs — so
  an unredacted snapshot leaks exactly how long the password is, and hands the
  model a run of junk it cannot read. Custom, web and Electron fields make no
  promise at all.
- **Password managers are refused by default.** Keychain Access, 1Password,
  Bitwarden, KeePassXC and the rest are declined unless `--allow-sensitive` is
  passed. This is a guard rail, not a security boundary — anything with
  Accessibility can read those windows. What it prevents is the accident: an
  agent sweeping open windows, or following an instruction it read on a web
  page, and quietly putting a vault into a transcript.

## Limitations

Stated plainly, because finding these out at runtime is worse:

- **No Dock, and no system-owned dialogs.** Save and open panels, sheets and in-app alerts *are* reachable — they appear as windows of the host application, so `--window-index` addresses them normally. What is out of reach is dialogs owned by the system itself: permission prompts, password requests and anything else drawn by SecurityAgent. macOS deliberately refuses automation there, and it should.
- **Optical fallback is text only.** `scan` finds text and where it is; it cannot tell a button from a caption, cannot see icons or unlabelled controls, and cannot report state. It is a fallback for windows that publish nothing, not a substitute for an accessibility tree.
- **Window management is opt-in.** `amcu window` moves, resizes, raises and un-minimizes — but no other command will do any of that on your behalf to make its own job easier.
- **Lazily built menus read as empty.** Applications that populate a submenu only when it opens show that submenu with no items. `menu-item --press` can still reach them by opening the menu.
- **Private API dependency.** Background *coordinate* clicks rely on `CGEventSetWindowLocation`. Semantic actions and `--mode foreground` do not. The self-check exists so you find out immediately rather than eventually.
- **macOS only**, 14.0+.

## Prior art

amcu exists because three other projects each solved part of this, and reading them was worth more than starting from scratch:

- **[stablyai/orca](https://github.com/stablyai/orca)** (MIT) — its `native/computer-use-macos` helper is the reference design for this space: AX tree as the primary channel, ScreenCaptureKit per-window capture, semantic actions first, and error messages written for the agent rather than the developer. The permission-scoped helper architecture is worth copying wherever you can.
- **[steipete/Peekaboo](https://github.com/steipete/Peekaboo)** — documents the corner-click failure and works around it with an accessibility hit-test, using only public API. If you want zero private-API exposure, that approach is the sound one, at the cost of not being able to deliver a genuine positioned click.
- **[andelf/axcli](https://github.com/andelf/axcli)** — demonstrates that the corner-click limitation *is* surmountable, via the `CGEventSetWindowLocation` route (in turn credited to [Lakr233/bgclick-rev-skill](https://github.com/Lakr233)). amcu's window-routing recipe follows this finding, and adds runtime verification of it.

## Development

```bash
swift build            # build
swift run amcu-tests  # run the test suite
```

The suite covers pure logic — coordinate conversion in both directions, snapshot
rendering and staleness contracts, session handling, menu shortcut spellings,
and optical recognition against a rendered image (which needs no Screen
Recording grant, so it runs in CI). The parts that need a real UI session are
verified with `amcu doctor` on a machine with permissions granted.

Tests are a plain executable rather than an XCTest or swift-testing target: both of those need a full Xcode install to *run*, and this tool is meant to stay verifiable on a machine with only the Command Line Tools. Tests that only some contributors can execute are tests that rot.

## License

MIT — see [LICENSE](LICENSE).
