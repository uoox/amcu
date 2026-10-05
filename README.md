# amcu — another macOS computer use

A single dependency-free binary that lets an AI agent read and drive macOS applications and web pages **without taking over the screen**: the cursor does not move, focus does not change, windows are not raised. You keep using the Mac while the agent works.

```console
$ amcu snapshot --app com.apple.TextEdit
app: TextEdit [com.apple.TextEdit]
window: Untitled id=8471 frame=(320,180 700x520)
0 Window [StandardWindow] "Untitled" @0,0 700x520
  1 ScrollArea @0,52 700x468
    2 TextArea = "" (focused) @0,52 700x468
  3 Button "Close" @12,12 14x14

$ amcu set-value --element 2 --value "hello"
set-value ok on element 2 via ax:AXValue (verified) (settled 0.4s)
# diff vs previous snapshot: ~1 changed, +0 added, -0 removed
~     2 TextArea = "hello" (focused) @0,52 700x468
```

## Why it is different

- **Structure first, pixels last.** The accessibility tree gives roles, labels, values and actions: an order of magnitude fewer tokens than a screenshot, and element indices that survive the window moving. When a window draws its own interface and publishes nothing, `amcu scan` falls back to OCR and coordinate clicks, in the same index space.
- **Background delivery that actually lands.** Coordinate clicks, scrolls and drags are posted to the target process and routed to its window (window-id fields plus `CGEventSetWindowLocation`). The real pointer never moves. Because that path relies on a private symbol, `amcu doctor` verifies once per OS build that a routed click lands where it was aimed, and coordinate clicks are refused rather than allowed to misfire.
- **Every action reports what happened.** Actions wait for the application to stop emitting accessibility notifications, then re-capture and print only the diff (`~` changed, `+` added, `- [a..b]` removed, or `# no change`). Indices stay stable across captures. Writes are read back and a mismatch is an error, not a caveat. A background input that stole focus is reported instead of hidden.
- **Your own browser, no relay.** `amcu browser` drives tabs in your Chrome (or any Chromium) through a small extension that talks to amcu over native messaging: no debug port, no token, no separate profile, logged-in sessions intact. Pages are read as an outline with stable refs; input goes through the debugger protocol so it reaches tabs that are not even visible. Safari works too (`--browser safari`), through a container app amcu builds and a Safari Web Extension; Safari offers extensions no debugger, so input there is synthetic and console/network/dialogs are not available.
- **Refuses instead of guessing.** Disabled controls, stale indices, ambiguous app names, password managers, foreground delivery to a background app: each is a structured error with a code and concrete next steps. Never a silent no-op.

## Install

Requires macOS 14 or later. Releases ship a universal binary.

```bash
curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
amcu doctor --request     # macOS prompts for Accessibility (and Screen Recording for screenshots)
amcu doctor               # every line should read [ok]
```

Permissions belong to **whatever runs amcu** (your terminal or the agent host), not to the binary; `doctor` names that host on its `subject:` line. For web pages: `amcu browser install`, then load the unpacked extension it names in `chrome://extensions`. For Safari: `amcu browser install --browser safari`, then the three Safari settings it prints (allow unsigned extensions, enable the extension, allow it on all websites).

From source: `swift build -c release` (Command Line Tools are enough) and copy `.build/release/amcu` onto your PATH. Do not put it in a package manager's prefix.

## Use

`amcu skill --install` writes a SKILL.md into `~/.claude/skills/amcu` (or `--dir` for `.agent/skills` and other hosts) that tells agents amcu **is** the computer-use and browser-use tool on this machine and comes before any other automation path. The guide (`amcu guide`, `amcu browser guide`) ships inside the binary and is the authoritative usage contract; a CLAUDE.md line is enough: *use `amcu` for desktop apps and `amcu browser` for web pages; run `amcu guide` first.*

```bash
amcu apps --recent                          # running apps, plus recently used ones with bundle ids
amcu launch --app com.apple.Notes           # start without activating; waits for a real window
amcu snapshot --app com.apple.Notes         # indexed accessibility tree
amcu snapshot --app com.apple.Notes --query /save/   # matching elements + ancestors
amcu click --element 12                     # semantic press; prints the settled diff
amcu set-value --element 7 --value "text"   # written through AX, read back, verified
amcu type --app com.apple.Notes --text "…"  # keystrokes, land on the app's own focus
amcu key --app com.apple.Notes --key s --mod cmd
amcu menu-item --app com.apple.Notes --path "File > Export"
amcu scroll --app com.apple.Notes --dy -300
amcu screenshot --app com.apple.Notes --out shot.png
printf '%s\n' '{"cmd":"click","element":3}' '{"cmd":"type","text":"hi"}' | amcu batch --app com.apple.Notes

amcu browser tabs
amcu browser tab --new --url https://example.com
amcu browser snapshot                       # outline with [ref=e12]
amcu browser click --ref e12
amcu browser fill --ref e7 --value "query" --submit
```

`--json` on any command gives structured output on stdout and structured errors on stderr. `--session NAME` keeps concurrent agents from sharing snapshot state. `~/.config/amcu/policy.json` extends the deny/allow lists and settle timing; `amcu policy` shows what is in effect.

`amcu lab` starts a disposable Chrome with the DevTools protocol exposed, for extension development and network interception. It is not for automating pages that resist the normal path.

## Development

This project is developed by AI agents. `CLAUDE.md` is the entry point; `docs/ARCHITECTURE.md` maps every module and `docs/DESIGN.md` records the decisions. `swift run -c release amcu-tests` runs the unit suite; `AMCU_E2E=1 Tests/e2e/run.sh` runs the live AppKit scenarios.

## License

MIT. See `LICENSE`.
