# amcu — another macOS computer use

**English** · [简体中文](README.zh-CN.md)

Read and drive macOS applications **without taking over the screen** — and, through a small browser extension, web pages inside your own browser without tokens, ports or a separate profile.

amcu is a small, dependency-free command-line tool for computer-use agents on macOS. It reads an application's accessibility tree, and clicks, types, scrolls and drags inside a target window — while you keep using your Mac. The cursor does not move. Focus does not change. The window does not come to the front. `amcu browser` does the same for tabs in Chrome (or any Chromium browser): an accessibility outline of the page with stable refs, and real input events delivered to tabs that need not even be visible.

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
  subject: this run answers for iTerm2 (pid 812, /Applications/iTerm.app)
  [ok] accessibility (iTerm2): reading and acting on user interfaces is permitted
  [ok] screen_recording (iTerm2): window capture is permitted
  [ok] accessibility (amcu itself): counts when amcu answers for itself — a launchd service or a disclaimed spawn
  [  ] screen_recording (amcu itself): not granted to the amcu binary — counts when amcu answers for itself — a launchd service or a disclaimed spawn
  [ok] ax window ids: resolvable
  [ok] background pointer delivery: window-routed pointer events land accurately (verified on build 27.0 (26A5388g))
```

`doctor` reports **two TCC subjects**, because macOS attributes a CLI tool's permission checks to its *responsible process* — the app hosting the run — not to the binary. The `(host)` rows are what this run actually gets and name exactly who to enable in System Settings; the `(amcu itself)` rows, measured by re-running amcu with responsibility disclaimed, only apply when amcu answers for itself (under a launchd service, or spawned disclaimed). Granting the amcu binary while running from a terminal changes nothing — that mismatch is the classic "I granted everything but doctor still says no".

If the self-check ever fails, coordinate clicks do not start moving your cursor: they fall back to pressing the element found at the target point through the accessibility tree — still no pointer events, still background. Only when nothing at that point is pressable are you pointed at the remaining choices: semantic element actions, or explicit `--mode foreground`. Scroll and drag have no such fallback and refuse instead.

## Quick start

Requires macOS 14 or later. Every [release](https://github.com/uoox/amcu/releases) ships a built universal (Apple silicon + Intel) binary, so nothing needs compiling.

### For a person

```bash
curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
```

The script downloads the latest release, verifies its SHA-256 against the sum published beside it, installs `~/.local/bin/amcu` (or `AMCU_INSTALL_DIR`), and stops there — the two things it cannot do for you are permission grants:

```console
$ amcu doctor --request     # macOS shows the prompts; approve them
$ amcu doctor               # every line should read [ok]
```

Permissions belong to **whatever runs amcu** — your terminal, or the agent host — not to the binary. `doctor` names that host on its `subject:` line so you grant the right thing the first time:

- **Accessibility** — required for everything.
- **Screen Recording** — only for `amcu screenshot`.

For web pages, one more step: `amcu browser install`, then load the unpacked extension it names (see [`amcu browser`](#web-pages-amcu-browser)).

Pin a version with `--version v0.6.0`, or build from `main` with `--source` (needs a Swift toolchain). `install.sh --help` lists the options.

### For an agent

Give the agent this, verbatim — it is written for a shell-capable agent (Claude Code, Codex, an SSH session, …) that cannot click a macOS permission dialog and should not pretend to:

```text
Install amcu (https://github.com/uoox/amcu), a CLI for reading and driving macOS apps
and browser tabs without taking over the screen:

1. curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
   (installs ~/.local/bin/amcu; if ~/.local/bin is not on PATH, use the full path below)
2. amcu doctor --request --json
   This triggers macOS permission prompts that only I can approve. If "accessibility"
   is not granted, stop and tell me to approve Accessibility (and Screen Recording, if
   screenshots are wanted) for the application that runs you, in
   System Settings > Privacy & Security. Then re-run `amcu doctor --json` until "ok" is true.
   Do not try to grant the permission yourself, and do not retry in a loop.
3. Add this line to the project's CLAUDE.md (or your equivalent instructions file):
   To read or operate a macOS desktop application, use `amcu`; for web pages,
   `amcu browser`. Run `amcu guide` before the first use in a session.
4. Run `amcu guide`, then confirm with `amcu apps` that you can see running applications.
```

Everything past step 2 is unattended. `amcu doctor --json` reports `"ok": true` only when both permissions are granted and background pointer delivery has been verified on this OS build, so an agent has one field to check instead of prose to interpret. `--json` on any command gives structured output on stdout and structured errors — with a code and next steps — on stderr.

### Other ways to install

**Download by hand.** Grab `amcu-<version>-macos-universal.tar.gz` from the [releases page](https://github.com/uoox/amcu/releases), check it against the `.sha256` beside it, and put `amcu` somewhere on your PATH. A tarball fetched through a browser carries the quarantine attribute, so also run `xattr -d com.apple.quarantine ~/.local/bin/amcu`.

**Build from source.** Needs a Swift toolchain (the Command Line Tools are enough — no Xcode needed):

```bash
git clone https://github.com/uoox/amcu
cd amcu
swift build -c release
install -m 755 .build/release/amcu ~/.local/bin/amcu   # or anywhere on your PATH
```

Wherever it comes from, do not install it into a package manager's prefix (`/opt/homebrew/bin`, `/usr/local/bin` on Intel): those directories belong to the manager, and a hand-built binary sitting in one is something `brew doctor` will complain about and a future cleanup may remove. `install.sh` refuses those directories for the same reason.

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
  amcu guide                                 operating instructions for an agent driving this

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

WEB PAGES
  amcu browser install                       one-time: register the native host, write the extension
  amcu browser tabs | tab --new --url U | tab --select ID | navigate --url U
  amcu browser window [--show|--hide|--close]   amcu's own background window, where tab --new opens
  amcu browser snapshot                      the page as an outline with [ref=e12] on every control
  amcu browser snapshot --diff               only the lines added/removed since the last snapshot
  amcu browser find --text T                 search the last snapshot (substring or /regex/)
  amcu browser click --ref e12 | fill --ref e7 --value V | type --ref e7 --text T --submit
  amcu browser click --target e12 --element "Submit button"   --target = --ref; --element is checked first
  amcu lab start | targets | cdp --method Runtime.evaluate --params '{…}' | stop
                                             a throwaway Chrome with the DevTools protocol, for extension work
  amcu browser select-option | key | scroll | drag | hover | upload | dialog
  amcu browser screenshot | eval --js EXPR | console | network | wait --text T | --url-matches RE
  amcu browser fill --ref e7 --secrets .env --secret DB_PASSWORD   type by key, masked in output
```

### Web pages: `amcu browser`

The desktop path can already read a browser window's accessibility tree, but a web page deserves better than what the window publishes: the whole document rather than the visible part, refs that survive a re-render, real input events on tabs that are not in front, navigation, evaluation, console and network. Playwright's MCP server does all of that through its "extension mode" — and needs a relay process, a token pasted into the extension, and a connection that has to be re-established every time either side restarts. That is what kept breaking, so amcu carries the same capability with none of the moving parts:

- **The extension talks to amcu through Chrome's native messaging.** `amcu browser install` writes a manifest that names this binary as the host for the `amcu bridge` extension. The browser starts the host itself when the extension loads and enforces which extension id may connect. There is no listening port for a web page to probe, and no token, because the operating system already knows who is talking to whom.
- **`amcu browser …` reaches that host over a Unix socket** in `~/Library/Caches/amcu/browser/`, one per running browser. If the extension is reloaded, the browser starts a new host and the next command finds it. If the browser quits, the socket goes away and the CLI says so instead of hanging.
- **Reading is a content script; acting is the debugger protocol.** The snapshot is computed in the page (roles, accessible names, states, visibility, refs) and needs no debugger. Clicks, keys, drags, screenshots, evaluation, console and network go through `chrome.debugger`, so input events are indistinguishable from a user's — including for tabs that are not visible. The one visible side effect is the browser's "amcu bridge started debugging this browser" infobar while a tab stays attached; `amcu browser detach` removes it.
- **Every action reports what it did.** `click`, `type` and `key` come back with what visibly followed: navigation, an opened dialog, how many DOM changes were observed, what appeared (a menu, a dialog), where focus went, a tab the action opened — or `no DOM change observed` when nothing did. When a click on the session's current tab opens a new tab, that tab becomes current and the result says so, instead of the click looking like a no-op while the interesting page sits elsewhere. `snapshot --diff` prints only the lines added and removed since the last snapshot, and refs new since then carry `[new]`; often the report alone answers "did it work?" without re-reading the page. The association is temporal, not causal — a busy page's own updates are counted too, and the report says when the page had not yet gone quiet.
- **The outline states facts a screenshot would hide.** Inputs carry their live validation constraints (`[maxlength=5] [pattern=…] [accept=…]`), elements whose only interactivity is a script or framework click handler are included and marked `[clickable]` — `jsaction`, `ng-click` and inline handlers always; `addEventListener` handlers too once the debugger is attached to the tab, listed through the debugger protocol rather than guessed from `cursor: pointer` — a control another element sits over is marked `[covered]` (a click there would be refused; the marker predicts it), a container with its own scrollbar is marked `[scrollable: 120px above, 900px below]` so content hidden inside it is not mistaken for absent, text a human cannot see is marked `[unseen=opacity|font-size|contrast]` (a classic prompt-injection channel — the flag is a fact, the judgment stays with the caller), frames from another origin are marked `[cross-origin]`, and the footer says how much page sits above and below the viewport. `[new]` and `[covered]` describe the moment rather than the element, so `find` and `--diff` ignore them and a dialog opening does not rewrite every line beneath it. Before any pointer event the target must hold still for two animation frames, so a click never lands where an animating element used to be.
- **Secrets stay out of transcripts, and out of the wrong page.** `--secrets .env` (or `$AMCU_SECRETS`) loads dotenv keys: `fill --ref e7 --secret DB_PASSWORD` types by reference, and the loaded values are masked as `[secret:KEY]` in all output — snapshots and echoes reliably; console and network only until a page re-encodes the value, and the docs say so rather than promising a boundary. A `DB_PASSWORD__DOMAINS=accounts.example.com,*.example.org` line in the same file (still valid dotenv) pins where that key may be typed: a tab — or a frame — on any other host gets a `secret_scope` refusal, which is the one mistake masking cannot undo.

Setup, once:

```console
$ amcu browser install
registered native host for chrome: ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/cc.uoox.amcu.json
wrote extension 0.5.0 (id cgpbockoghamineoofoonidkickapbok) to ~/Library/Application Support/amcu/extension

next: in the browser open chrome://extensions, turn on Developer mode (top right), click "Load unpacked"
      and choose:  ~/Library/Application Support/amcu/extension
then: amcu browser doctor
```

The extension is loaded unpacked from that folder; a fixed key in its manifest gives it the same id everywhere, which is what the native messaging manifest allows. Upgrading amcu means running `amcu browser install` again — it rewrites the folder and, when a browser is connected, asks the running extension to reload itself. Chrome, Chrome Beta/Dev/Canary, Chromium, Edge, Brave, Vivaldi, Arc and Opera all read the same kind of manifest, and `install` writes one for each that is present.

Then it is the familiar shape:

```console
$ amcu browser tabs
id=727784600	win=727784597:2	GitHub - uoox/amcu: another macOS computer use	https://github.com/uoox/amcu  (active)
$ amcu browser snapshot
tab 727784600 "GitHub - uoox/amcu: another macOS computer use" https://github.com/uoox/amcu  [chrome]
- link "Skip to content" [ref=e1]:
  - /url: https://github.com/uoox/amcu#start-of-content
- banner:
  - heading "Navigation Menu" [ref=e2] [level=2]
  - link "Homepage" [ref=e3]:
    - /url: https://github.com/
  - navigation "Global":
    - list:
      - listitem:
        - button "Platform" [ref=e4]
...
  - button "Search or jump to, type / to search" [ref=e10]
...
$ amcu browser click --ref e10
click ok on e10 (button "Search or jump to, type / to search" [ref=e10]) at 827,36 via cdp
$ amcu browser snapshot --interactive | grep combobox
- combobox "Search or jump to" [ref=e170] [active] [expanded]
$ amcu browser fill --ref e170 --value "background click"
fill ok on e170 (combobox "Search or jump to" [ref=e170]) via cdp:insertText (verified)
$ amcu browser key --key Enter
key ok: Enter to tab 727784600 "GitHub - uoox/amcu: another macOS computer use" https://github.com/uoox/amcu
→ navigated to https://github.com/search?q=background+click&type=repositories
```

Refs are checked the way element indices are: before an action, the element is re-resolved and its role and accessible name compared with what the snapshot recorded, so a page that changed underneath you yields `stale_snapshot` instead of a click on whatever moved there. Frames are part of the address — `f42e12` is element 12 of frame 42, and the snapshot prints each frame as its own section, with the iframe it sits in and coordinates translated on the way to a click. Each `--session` has its own current tab, so concurrent agents do not steal each other's.

`tab --new` opens in a window of amcu's own: a separate, never-focused browser window created on first use, whose first tab is a pinned page saying what it is. Your focus, your active tab and your window order are untouched; the agent's tabs are out of your tab strip, so you cannot close them by accident; and because a tab there can be made active *within* that unfocused window, it keeps rendering and screenshots work with the window parked behind everything else (screenshots restore it from minimised by themselves, unfocused). `amcu browser window` reports it, `--show` focuses it when you want to watch the agent work, `--hide` minimises it, `--close` ends it. `tab --new --user-window` is the explicit exception that opens in your window. And a command that would *change* a page acts on the tab you are looking at only when told to explicitly — with no pinned tab and no `--tab`, acting commands refuse rather than navigate away what you are reading.

What `amcu browser` will not do, stated plainly: it cannot script `chrome://` pages, the Web Store or `file://` URLs unless the extension is granted file access; a screenshot needs the tab to render, which amcu's own window guarantees invisibly but a background tab in *your* window may not (the error says what to do, and `snapshot` needs no pixels); `eval` cannot reach a cross-origin frame's script context, though clicking and typing inside one works; and a click on a covered element is refused with the cover named, because a click that lands on a cookie banner is exactly the kind of "success" this tool refuses to report. `--force` falls back to a JavaScript click when you know better.

`amcu browser guide` carries the operating conventions for an agent, and `amcu browser doctor` diagnoses the setup end to end.

### Driving it from an agent

`amcu guide` prints the operating conventions — the normal sequence, why bundle
ids beat display names, when indices go stale, which text path can be verified,
what is refused. It lives in the binary rather than in this README or a skill
file because those drift: a flag changes and the prose keeps teaching last
quarter's usage to a model with no way to know it is wrong.

For Claude Code, that makes the whole integration one line in `CLAUDE.md`:

```markdown
To read or operate a macOS desktop application, use `amcu`; for web pages,
`amcu browser`. Run `amcu guide` before the first use in a session.
```

No wrapper, no MCP server, nothing to keep in sync. An MCP server is only worth
building for clients that have no shell — and then as four or five grouped
tools, not one per command.

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

Chromium hosts are asked to publish their accessibility tree — only
`AXManualAccessibility`, never `AXEnhancedUserInterface`, because that second
flag makes `AXPosition` writes be ignored and would quietly break this tool's
own `window --move`. Which applications count is decided two ways: a
whitelist of known bundle ids, and a look inside the application bundle for
the engine itself (`Electron Framework.framework`, Chromium Embedded
Framework, a browser's own framework), so an Electron app nobody listed is
treated the same as Slack or VS Code. Native applications are never touched.

Measured honestly: on macOS 27 it changed nothing. Chrome reported 151 nodes
before activation and 152 after; Lark, a genuine Electron app with a real
window, reported 502 both times. Recent macOS appears to enable Chromium
accessibility on its own once any assistive client is active. The flag is kept
because it is one idempotent write, it is what these hosts document, and older
systems may still need it — but it is a defensive measure that demonstrated no
benefit here, not a fix for anything observed.

### Background input that took focus anyway is reported

Background delivery posts events to the target process without touching the
user's focus. AppKit does not always cooperate: a mouse-down reaching a window
that is not active can activate that application, as a real click would. amcu
reads the frontmost application before and after every background click,
scroll, drag, keystroke and paste (through the accessibility API, which does
not depend on this process's run loop) and, when a background target became
frontmost, the result carries `warning: the target became the frontmost
application`. Nothing is put back — restoring focus would be a second
disturbance — but the result never pretends the promise held when it did not.
`click --element N` presses through the accessibility API and cannot activate
anything, which is one more reason it is the preferred path.

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

- `--mode auto` (default) — semantic action if the element offers one, otherwise verified background delivery; if this system's routed delivery failed verification, clicks fall back to an accessibility press at the target point (cursor still untouched). **Never falls back to foreground silently**: stealing focus is a visible side effect, so it has to be asked for.
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
- **Private API dependency.** Background *coordinate* clicks rely on `CGEventSetWindowLocation`. Semantic actions, the accessibility-press fallback and `--mode foreground` do not. The self-check exists so you find out immediately rather than eventually — and when it fails, clicks degrade to the accessibility press, not to your cursor.
- **The browser extension is loaded unpacked.** Chrome requires Developer mode for that, and shows an infobar while amcu holds a tab's debugger. Publishing to the Web Store would remove the first; the second is how Chrome tells the user an extension is driving the page, and it stays.
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

The browser extension lives in `extension/` and is embedded into the binary by `Scripts/embed-extension.py` (which regenerates `Sources/AmcuCore/ExtensionBundle.swift`); the test suite fails if the two drift apart, so run the script after touching anything under `extension/`.

### Releasing

Every release carries a built binary; the workflow in `.github/workflows/release.yml` makes it so:

1. Bump `Sources/AmcuCore/Version.swift` and `extension/manifest.json` to the same number, and commit.
2. Tag and push: `git tag v0.6.0 && git push origin main v0.6.0` — or create the release in the GitHub UI with a new tag.
3. The workflow checks out the tag, runs the suite, builds a universal arm64+x86_64 binary with `Scripts/package.sh`, and uploads `amcu-<version>-macos-universal.tar.gz` plus its `.sha256` to the release — creating the release with generated notes if it does not exist yet, and leaving hand-written notes alone if it does. Edit the notes afterwards if you prefer them written by hand.

`Scripts/package.sh v0.6.0` reproduces the artifact locally, and refuses if the tag and the version the binary reports disagree — a release never ships a binary that says the wrong number. `Scripts/install.sh` downloads exactly those asset names, so they are part of the contract.

### End-to-end tests

```bash
AMCU_E2E=1 Tests/e2e/run.sh
AMCU_E2E=1 AMCU_E2E_CHROME="/path/to/Chromium" Tests/e2e/browser/run.sh
```

This compiles a handful of tiny AppKit probe windows (a scrolled 200-row
table, a focused text field, a self-drawn canvas that hides itself from the
accessibility API, a pair of combo boxes) and drives the real `amcu` binary
against them: viewport culling, `--no-shaping`, click-by-index, verified
`set-value`/`replace` with a live selection, blind-window detection, and a
check that no action command ever changes the frontmost application.

It is opt-in via `AMCU_E2E=1` — without it the script exits 0 with a note —
because it needs everything CI lacks: a logged-in window server session,
Accessibility permission for the invoking terminal, and Automation permission
for System Events. These scenarios earn their keep by catching bugs the unit
suite structurally cannot (culling against the wrong reference frame,
ScreenCaptureKit aborting the process outside a UI session), and faking those
conditions in CI would test the fake.

The browser script starts a Chromium (Chrome for Testing or a Chromium build —
branded Chrome no longer honours `--load-extension`) on a throwaway profile with
the extension loaded and the native messaging manifest placed where that profile
reads it, serves a small test site, and drives it: trusted clicks, verified
fills, selects, dialogs, iframes, covered and off-screen elements, stale refs,
upload, screenshot, console. It never touches your own browsers.

## License

MIT — see [LICENSE](LICENSE).
