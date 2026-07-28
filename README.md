# umbra

Read and drive macOS applications **without taking over the screen**.

umbra is a small, dependency-free command-line tool for computer-use agents on macOS. It reads an application's accessibility tree, and clicks, types, scrolls and drags inside a target window — while you keep using your Mac. The cursor does not move. Focus does not change. The window does not come to the front.

```console
$ umbra snapshot --app com.apple.textedit
app: TextEdit [com.apple.textedit]
window: Untitled id=8471 frame=(320,180 700x520)
coordinates: window-relative
0 Window [StandardWindow] "Untitled" @0,0 700x520 actions:Raise
  1 ScrollArea @0,52 700x468
    2 TextArea = "" (focused) @0,52 700x468
  3 Button "Close" @12,12 14x14
  ...

$ umbra click --element 3
click ok on element 3 via ax:AXPress
```

## Why

Most macOS automation tools are *foreground* automation: they activate the target application, move the real cursor, and post events to the global HID stream. While the agent works, the machine is not yours — and on a shared cursor, you and the agent fight over every click.

Doing better requires three things, and umbra does all three:

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

## The catch, and what umbra does about it

`CGEventSetWindowLocation` is **not public API**. It is resolved at runtime with `dlsym`, and Apple can change or remove it. Worse, its likely failure mode is quiet: clicks keep being delivered, they just stop landing where they were aimed — the kind of breakage that corrupts data before anyone notices.

So umbra does not trust the symbol's presence. On first use for a given OS build it runs a **self-check**: it opens its own throwaway window, clicks it at a deliberately asymmetric point through the full background path, and verifies where the click actually arrived. Only an exact hit counts as usable. The verdict is cached per OS build, so the cost is paid once per system update.

```console
$ umbra doctor
umbra doctor — 27.0 (26A5388g)
  [ok] accessibility: reading and acting on user interfaces is permitted
  [ok] screen_recording: window capture is permitted
  [ok] ax window ids: resolvable
  [ok] background pointer delivery: window-routed pointer events land accurately (verified on build 27.0 (26A5388g))
```

If the self-check ever fails, background coordinate clicks are refused with an explanation rather than silently misfiring, and you are pointed at the two paths that do not depend on private API: semantic element actions, and explicit `--mode foreground`.

## Install

Requires macOS 14 or later and a Swift toolchain (the Command Line Tools are enough — no Xcode needed).

```bash
git clone https://github.com/uoox/umbra
cd umbra
swift build -c release
cp .build/release/umbra /usr/local/bin/
```

Then grant permissions to whatever runs umbra (your terminal, or the agent host):

- **Accessibility** — required for everything.
- **Screen Recording** — only for `umbra screenshot`.

`umbra doctor --request` triggers the system prompts.

## Usage

```
INSPECT
  umbra apps                                  list running applications
  umbra windows    --app S                    list windows with ids and frames
  umbra snapshot   --app S                    capture the accessibility tree as indexed text
  umbra doctor                                check permissions, verify background delivery

ACT
  umbra click      --app S --element N        press an element by its snapshot index
  umbra click      --app S --at X,Y           click a point (window-relative unless --screen)
  umbra action     --element N --action A     perform any action the element advertises
  umbra set-value  --element N --value V      set an element's value directly
  umbra type       --app S --text T           type literal text
  umbra paste      --app S --text T           paste via the pasteboard (input-method safe)
  umbra key        --app S --key K --mod cmd  press a key combination
  umbra scroll     --app S --dy N             scroll
  umbra drag       --app S --from X,Y --to X,Y
  umbra screenshot --app S --out FILE         capture one window, occluded or not
```

Add `--json` to any command for machine-readable output on stdout and structured errors on stderr.

### Selectors

`--app` accepts a bundle id, `pid:1234`, or an application name. **Prefer bundle ids**: display names are localized, so `--app Finder` fails on a Chinese system where the same application is `访达`. `--window-id` and `--window-index` pick among an application's windows.

### Element indices are checked, not trusted

Indices come from the most recent `snapshot` in the same `--session`. Before acting, umbra re-resolves the element by its recorded path and verifies the role and label still match. If the interface changed underneath, you get a `stale_snapshot` error instead of a click on whatever moved into that position.

```console
$ umbra click --element 4 --session inbox
error [stale_snapshot]: element 4 changed label ("Archive" -> "Delete")
  next: Re-run `umbra snapshot`; the interface changed after it was captured.
```

### Delivery modes

- `--mode auto` (default) — semantic action if the element offers one, otherwise verified background delivery. **Never falls back to foreground silently**: stealing focus is a visible side effect, so it has to be asked for.
- `--mode background` — window-routed, cursor stays put.
- `--mode foreground` — global event tap. Moves the cursor and takes focus. Correct only when the target is already frontmost.

### Errors are written for agents

Every failure carries a machine-readable code and concrete next steps, including when *not* to retry:

```console
$ umbra click --app Gmail --at 100,200
error [app_not_found]: no running application matched 'Gmail'
  next: Run `umbra apps` to list running applications with their pid and bundle id.
  next: Prefer a bundle id (com.apple.finder) or pid:1234 over a display name — display names are localized and differ per system language.
  next: If the target is a website, select the browser application that shows it; selectors address desktop applications, not web pages.
  next: Do not retry the same selector unchanged.
```

## Limitations

Stated plainly, because finding these out at runtime is worse:

- **No menu bar, Dock, or system dialogs.** umbra addresses application windows. Menu-driven flows need `--mode foreground` plus keyboard shortcuts, or another tool.
- **No OCR or vision fallback.** Applications that render their own UI without publishing an accessibility tree — canvas-based editors, some games, a few Electron configurations — are effectively invisible. Screenshots are available, but nothing interprets them for you.
- **No window management.** umbra will not move, resize, focus or un-minimize windows. It reports `minimized` and offscreen state; acting on it is your call.
- **Background typing follows the target's own focus.** Keystrokes go to whatever is focused *inside* the target application. Set focus first (via `set-value`, a semantic click, or `action --action AXFocus`) rather than assuming.
- **Private API dependency.** Background *coordinate* clicks rely on `CGEventSetWindowLocation`. Semantic actions and `--mode foreground` do not. The self-check exists so you find out immediately rather than eventually.
- **macOS only**, 14.0+.

## Prior art

umbra exists because three other projects each solved part of this, and reading them was worth more than starting from scratch:

- **[stablyai/orca](https://github.com/stablyai/orca)** (MIT) — its `native/computer-use-macos` helper is the reference design for this space: AX tree as the primary channel, ScreenCaptureKit per-window capture, semantic actions first, and error messages written for the agent rather than the developer. The permission-scoped helper architecture is worth copying wherever you can.
- **[steipete/Peekaboo](https://github.com/steipete/Peekaboo)** — documents the corner-click failure and works around it with an accessibility hit-test, using only public API. If you want zero private-API exposure, that approach is the sound one, at the cost of not being able to deliver a genuine positioned click.
- **[andelf/axcli](https://github.com/andelf/axcli)** — demonstrates that the corner-click limitation *is* surmountable, via the `CGEventSetWindowLocation` route (in turn credited to [Lakr233/bgclick-rev-skill](https://github.com/Lakr233)). umbra's window-routing recipe follows this finding, and adds runtime verification of it.

## Development

```bash
swift build            # build
swift run umbra-tests  # run the test suite
```

Tests are a plain executable rather than an XCTest or swift-testing target: both of those need a full Xcode install to *run*, and this tool is meant to stay verifiable on a machine with only the Command Line Tools. Tests that only some contributors can execute are tests that rot.

## License

MIT — see [LICENSE](LICENSE).
