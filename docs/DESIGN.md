# Design decisions

Each entry is a decision that is not obvious from the code, with the reason. Change the decision only with a reason at least as good, and record it here.

## Stateless CLI, not a daemon

A one-shot process per command, state on disk (`SessionStore`). Reasons: TCC grants attach to the host that runs amcu (terminal, agent host), so a rebuilt binary loses nothing; an agent can call it from any shell; nothing survives a crash to be in a wrong state. Cost: no AXObserver across calls, so settle detection and index reuse are done inside each command (`Settle`, `previous` snapshot). An MCP server wrapping the same `Commands` layer is the planned way to get a long-lived process without giving up the CLI (see Backlog).

## Background delivery: fields 51/52 plus `CGEventSetWindowLocation`

Measured on macOS 27: window-id fields alone deliver to the window but land at its corner; `CGEventSetWindowLocation` alone is not routed at all; both together land exactly. The symbol is private, so `SelfCheck` clicks amcu's own throwaway window at an asymmetric point and caches the verdict per OS build. `--mode auto` uses routing only when the verdict is usable, otherwise falls back to an AX press at the point (`AXHitTest`); scroll/drag refuse. Foreground is never chosen automatically.

## Indices are stable identities (since 0.9.0)

Identity = FNV-1a over parent identity + role|subrole|identifier|label + ordinal among same-key siblings. Value, state, frame are excluded so an edited field is "changed", not "removed + added". Matching identities keep their index; new nodes take fresh indices after the previous maximum; a removed index is never reused in a session (an agent holding an old number gets `stale_snapshot`, never a different element). Numbering restarts when fewer than 40 % of nodes match (different window, rebuilt UI), and the diff then prints the full tree. Acting still resolves by `path` (AXChildren indices) and re-verifies role/subrole/identifier/label; identity is only for numbering and diffs.

## Observe after act

Every acting command settles (`Settle.wait`: at least `min`, until `quiet` seconds without AX notifications, at most `max`, plus `AXElementBusy`), then re-captures the session's snapshot and prints the diff. Wisp/Sky do the same and it is the single largest token saving: the agent otherwise re-reads the whole tree after each click. Observation only happens when the session already holds an accessibility snapshot of the same pid (a bare `type` into an unsnapshotted app has nothing to diff). `--no-observe` skips the re-capture; settling still runs because the focus verdict and any read-back depend on it. Paste restores the pasteboard after settling, which replaced a fixed 120 ms sleep.

## Snapshots are shaped

Structural containers with no label/value/action are skipped (children still walked, paths preserved), labelled compact controls are not expanded unless a direct child is actionable, tables report only rows on screen (`AXVisibleRows`, else intersection with the nearest `AXScrollArea`). Everything hidden is counted in the footer; `--no-shaping` is the escape hatch. `--query` filters after capture so all indices remain valid.

## Refuse rather than guess

Ambiguous app names, disabled controls, stale indices, foreground delivery to a non-frontmost app, password managers, out-of-range numbers: all errors with `nextSteps`. The alternative (do something plausible) produces the silent misclick class of bug that costs more than any refusal.

## Text before pixels

Accessibility tree first; `scan` (Vision OCR) only when the window is accessibility-blind, and its marks expire after 60 s because they cannot be re-verified. `docs/browser-use-ideas.md` records the evidence (SeeAct: text grounding 39 % vs set-of-marks 20 %).

## Browser: extension + native messaging, not CDP port, not AX

The user's own Chrome with logged-in sessions, no restart, no debug port for pages to probe, no token: the OS pins which extension id may talk to the host binary. Reading is a content script (no debugger attached, no infobar); acting goes through `chrome.debugger` so events are trusted and reach background tabs. `amcu lab` covers what an extension cannot (other extensions, chrome:// pages, network interception) with a throwaway profile. Driving Chrome through macOS AX remains possible (`snapshot --app com.google.Chrome`) as the no-setup path.

## Safari: a relay, long polling, and synthetic input (since 0.10.0)

Safari loads only Safari Web Extensions packaged in a signed app, routes `sendNativeMessage` to that app's sandboxed `.appex` one message at a time (`beginRequest`), and gives extensions no `chrome.debugger`. Decisions:

- **The bundle is assembled from the amcu binary, not compiled.** App executable and appex executable are both copies of amcu; the copy that finds itself inside an `.appex` calls `NSExtensionMain` (resolved with `dlsym`, the entry point Xcode links appexes against) and the principal class `AmcuSafariWebExtensionHandler` lives in AmcuCore. Plists and extension files are generated, `codesign` signs. So `amcu browser install --browser safari` works from the release tarball without Xcode, and the bridge is always the same version as the CLI that installed it. The converter's Xcode project was not committed: it would need Xcode to build and would drift from the binary.
- **Loopback TCP with a per-install token between appex and relay.** The appex is sandboxed. A Unix socket in a shared app-group container needs an app group, which ad-hoc and self-signed builds cannot claim; reaching into the appex's own container from the CLI triggers macOS's "access data from other apps" consent prompt. `com.apple.security.network.client` lets the sandboxed appex connect to 127.0.0.1 (measured: works, no prompt; loopback is exempt from Local Network privacy). The port and a 24-byte token are written into the appex Info.plist at install; the relay answers nothing to a connection without the token (a web page's fetch to the port gets an empty reply). The CLI side stays a 0600 Unix socket.
- **The relay is the container app's executable, started on demand.** The CLI spawns it (setsid, detached) when `--browser safari` finds no relay; it exits after 30 idle minutes. No LaunchAgent: that would add a "Background Items" notification and a permanent process for an opt-in feature. Its socket speaks the native-host protocol, so `BrowserClient` and every browser verb work unchanged; `hello` adds `ready` (the extension polled within 45 s), and default browser selection skips an unready relay.
- **Long polling, not a push channel.** The extension sends `poll`; the relay holds it up to 15 s (below any plausible Safari native-message timeout) and answers with a queued request or `idle`. With the relay down the appex answers at once and the extension retries every ≤3 s. A request while nothing polls fails in 8 s with `bridge_unavailable` and doctor's next steps instead of hanging for the full timeout. Safari profiles each run the extension; the relay pins the first profile that polls so tab ids stay coherent.
- **Synthetic input, labelled.** Clicks are the pointer/mouse event sequence at the measured point (covered targets still refused), keys are keydown/keypress/keyup plus the reproducible default actions, text goes through `document.execCommand('insertText')` (the browser's editing path; frameworks see real input events) with a value-setter fallback. Every result carries `synthetic` and the CLI prints it. Pretending these were trusted would be the silent no-op class of bug on pages that check `isTrusted`.
- **No amcu window in Safari.** `windows.create` cannot open an unfocused window in Safari, so a new window would raise Safari over whatever the user is doing. Tabs open unselected in the user's front window instead (`tabs.create({active:false})`); the cost is a visible tab in their strip and no screenshots of it until selected (`captureVisibleTab` sees only the selected tab).
- **Refuse what cannot be honest.** console, network, dialog, drag, resize and window management fail with `unsupported` and a next step (Chrome, `amcu lab`, or desktop amcu on the Safari window), in the relay before any round trip and again in the extension.
- **Signing.** Developer ID if present (Safari then needs no "Allow unsigned extensions"), else `AMCU_SIGN_IDENTITY` if it names an identity in the keychain (a stable designated requirement across reinstalls), else ad-hoc. Doctor cannot read the "Allow unsigned extensions" switch; it infers it from the extension not polling and lists the three owner steps.

## Policy file over compiled lists

`~/.config/amcu/policy.json` extends the sensitive-app deny/allow lists, the input-immune list, and settle timing. The built-in lists stay as the floor; users with unlisted vault apps should not need a rebuild.

## Event tagging

All synthesized events carry `0x414D4355` in `eventSourceUserData`. Nothing consumes it yet; it exists so a future intervention monitor or the self-check can distinguish amcu's input from the user's without heuristics.

## Deliberately not adopted

- **Animated agent cursor / banner / Esc-to-stop**: contradicts "do not disturb the user" and needs a daemon.
- **Auto-attached screenshots when the tree is empty**: `scan` gives text with positions instead; pictures are opt-in.
- **`AXEnhancedUserInterface` on Chromium hosts**: makes `AXPosition` writes be ignored, breaking `window --move`; only `AXManualAccessibility` is set.
- **Auto-launching from `--app`**: launching is visible; it is the explicit `launch` verb (which still does not activate).

## Backlog

- **MCP server** (`amcu mcp`): stdio JSON-RPC over the same `dispatch`; one process per agent session keeps the AXObserver subscribed, the previous snapshot in memory, and removes process start-up per call. Tool descriptions should be one line each and point to a `guide` tool; the diff output is what keeps per-call tokens low, not the transport.
- **Synthetic activation experiment**: post an AppKit-defined `applicationActivated` event to the target pid before background mouse-down (what wisp does) and measure with the e2e ButtonProbe whether AppKit stops making the target frontmost. Also cross-check wisp's claim that field 51 alone routes accurately without `CGEventSetWindowLocation`.
- **`amcu key` chord syntax** (`cmd+shift+t`) as an alternative to `--key t --mod cmd,shift`.
- Browser backlog with verdicts: `docs/browser-use-ideas.md`.
- **Safari wake-up push**: `SFSafariApplication.dispatchMessage` from the container app could wake a sleeping background page instead of waiting for its one-minute alarm; untested whether Safari delivers it to an unloaded page.
