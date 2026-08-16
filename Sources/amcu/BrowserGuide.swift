import AmcuCore

/// Operating instructions for an agent driving web pages through `amcu
/// browser`. Ships in the binary for the same reason the main guide does.
let browserGuideText = """
amcu \(AmcuVersion.string) — browser guide for agents

WHAT THIS IS FOR
  Reading and driving web pages inside the user's own browser — their profile,
  their logins, their open tabs — while they keep using the machine. Nothing is
  launched, no debugging port is opened, no token is configured: the browser
  starts the amcu host itself when the amcu bridge extension is loaded.
  Tabs are read and acted on in the background; the user's active tab, window
  and cursor are left alone unless a flag says otherwise.

FIRST CONTACT
  `amcu browser doctor` tells you whether a browser is connected. If not, the
  user has a one-time setup: `amcu browser install`, then Load unpacked in
  chrome://extensions. Say so and stop; you cannot do that part for them.

THE NORMAL SEQUENCE
  1. `amcu browser tabs` — see what is open. Every tab has an id.
  2. `amcu browser tab --select ID` (or `tab --new --url …`) — pin the tab
     this session works on. Without a pinned tab, commands use the browser's
     active tab, which the user may change under you.
  3. `amcu browser snapshot` — the page as an indented outline: role, name,
     state, and a ref like [ref=e12] on everything you can act on.
  4. Act by ref: `click --ref e12`, `fill --ref e7 --value "…"`,
     `type --ref e7 --text "…" --submit`, `select-option --ref e9 --value X`.
  5. Re-snapshot after anything that changes the page. A ref names an element,
     and the element's role and name are re-checked before every action: if
     they changed you get stale_snapshot, not a click on whatever moved there.

REFS AND FRAMES
  e12 lives in the main document. f42e12 lives in frame 42 (an iframe); the
  snapshot prints child frames as their own sections with the iframe they sit
  in. Keep the f-prefix — it is part of the address.
  Refs are stable while the element and its name stay the same, so a ref from
  an earlier snapshot still works after a partial re-render; the result says
  "(ref from an earlier snapshot)" when that happened.

READING
  The snapshot lists what is visible: hidden elements, empty wrappers and
  script are gone; long text is capped and says so. `--interactive` keeps only
  controls; `--selector CSS` scopes to a subtree; `--max-nodes` raises the
  budget when the footer says it truncated. Password-like fields show
  [redacted].
  `eval --js EXPR` runs JavaScript in the page and returns JSON. Pass a function
  and `--ref` to receive the element. Use it for data the outline does not
  carry (attribute values, computed text, full innerText).
  `screenshot` needs the tab to render: a background tab in a hidden window may
  produce nothing, and the error says how to make it visible. Prefer snapshot;
  it needs no pixels.
  `console` and `network` show what the page logged and requested. Both attach
  the debugger; console messages logged before that are replayed when the
  browser still has them, network requests are recorded from then on.

ACTING
  Clicks, keys and drags are real input events delivered through the debugger
  protocol: pages cannot tell them from a user, and they work on tabs that are
  not visible. The first such action attaches the debugger to the tab, and the
  browser shows an infobar for as long as it stays attached. `detach` removes
  it; the next action attaches again. This is the one visible side effect.
  A click is refused when another element covers the target — usually a
  dialog, cookie banner or menu. Deal with the cover first; `--force` falls
  back to a JavaScript click, which some pages ignore.
  `fill` replaces a field's value and reads it back; a mismatch is an error
  carrying both strings. `type` appends keystrokes at the caret; `--slowly`
  types key by key for autocompletes; `--submit` presses Enter afterwards.
  `select-option` sets a <select> by value or visible label. Custom dropdowns
  are not selects: click the combobox, re-snapshot, click the option.
  After click, key, and type --submit the result reports whether the page
  navigated, and flags a dialog the action opened.

TABS AND VISIBILITY
  `tab --new` opens in the background; `--activate` shows it (a visible change
  in the user's window). `tab --select ID --activate` likewise. `navigate`,
  `back`, `forward`, `reload` wait for the load to finish; `--no-wait` and
  `wait --load` split that.
  Concurrent agents: use `--session NAME`; each session has its own current
  tab. Several browsers or profiles: `--browser chrome|edge|…`.

WHEN THINGS STOP RESPONDING
  A blocked page usually means an alert/confirm/prompt is open:
  `dialog --accept` (or `--dismiss`). If the extension was reloaded, the first
  command after that reconnects by itself. `amcu browser doctor` diagnoses
  the rest.

`amcu browser help` lists every verb and flag. `amcu guide` covers desktop
applications; a page's browser window can also be driven that way when the
extension is not available.
"""
