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
