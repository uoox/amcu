# Ideas for `amcu browser`, harvested from the open-source browser-use field

*Survey date 2026-08-16. Purpose: decide, one by one, what (if anything) to fold into amcu.
amcu is a **mechanism** — deterministic verbs driven by an external LLM — not an agent. The filter
throughout: does the idea make the mechanism better (representation, targeting, reliability,
feedback, safety), or does it try to put a brain inside amcu (wrong layer)?*

## What amcu already has (the baseline the field is measured against)

Aria-style page snapshot as an indented outline with stable refs (`e12`, `f42e12` across iframes);
refs re-verified by role+name before every action (stale detection); trusted CDP input on background
tabs; obscured-click refusal via `elementFromPoint` at center, descending shadow roots, naming the
cover; verified writes (read-back); navigation only reported when it actually happened; dialog
awareness; browser-trusted cross-iframe click geometry; `cursor:pointer`-with-parent-dedup +
`[onclick]` + focusable + editable interactivity test; `checkVisibility` pruning; open shadow-root +
slot walking; `disabled`/`aria-disabled`/`fieldset[disabled]` handling; `scrollIntoViewIfNeeded`;
console/network capture; screenshot; element-aware eval; upload; per-session tab; native-messaging
transport (no token, no port); install/doctor + extension self-reload.

**Two framing findings from the survey:**

1. **The field converged on exactly amcu's representation.** BrowserGym benchmarks validate "AX-tree
   outline + stable IDs, vision as fallback" as the standard config; Stagehand v3's snapshot is
   nearly isomorphic to amcu's. amcu is not behind on its core.
2. **amcu's deliberate text-first, no-pixel-interpretation stance is *empirically* the right call,
   not merely defensible.** SeeAct measured, on the same tasks, textual-choice grounding **39.1%** vs
   set-of-marks/image annotation **20.3%** (SoM failed by 54% label hallucination + 46% adjacent-mark
   confusion); the OpenAI Operator system card documents its own OCR failures on API keys / crypto
   addresses / DNA; Comet was injected via screenshot-OCR'd hidden text. Vision is a *supplement* for
   narrow regimes, never the primary channel — which is exactly amcu's design.

So amcu's real gaps are concentrated in the **feedback loop**, a few **unexposed CDP capabilities**,
**handler-driven clickables the AX tree misses**, **stability gating**, and **observation-layer
safety** — not in the snapshot format.

---

## Decision table

Verdict legend: **★ adopt** (high value, low cost, squarely amcu's identity) · **~ maybe** (real
value, higher cost or a policy question) · **✗ skip** (wrong layer). Cost is relative to amcu's
existing extension+CDP architecture.

### A. Snapshot representation — coverage & token cost

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Snapshot diff / `*new` markers** — after an action append `changed: +N/−M`, mark new-since-last refs with `*`; optional `snapshot --diff` returns only changed lines | browser-use `*[12]*`; Stagehand `diffCombinedTrees` | Attacks the #1 token cost: re-reading near-identical snapshots after every action. amcu already keeps the previous tree for ref verification | Small | **★** |
| **Framework click handlers** — treat Google `jsaction` (click rule: `eventType==="click" && namespace!=="none" && action!=="_"`) and AngularJS `ng-click` (9 spellings, gated on a page `.ng-scope`) as interactive | Vimium `link_hints.js` exact rules | amcu only checks `[onclick]`; recovers refs on Google properties + Angular apps where the handler is framework-dispatched and amcu sees nothing today | Small | **★** |
| **Wider handler attrs + ARIA roles** — add `[onmousedown/up/over]`; add roles `switch/option/listbox/scrollbar/slider/spinbutton/treeitem/combobox` | Tridactyl `HINTTAGS` union | Trivial table extension; amcu's set is narrower than the hint-extension union | Small | **★** |
| **CDP `isClickable` + confidence tiers** — merge Chrome's own `DOMSnapshot.isClickable` rare-boolean; tag each ref `definite`/`guessed` | browser-use `enhanced_snapshot.py` (via CDP — *not* the devtools-only `getEventListeners`) | One `DOMSnapshot.captureSnapshot` on the session amcu already holds; catches handler-driven `<div>`s and gives the model a cheap trust signal | Medium | **★** |
| **Validation-constraint attributes** — surface `maxlength / pattern / min / max / step / accept / inputmode / multiple` on inputs | browser-use allowlist ("help agents avoid brute force") | Near-zero tokens; agent fills correctly first try → fewer verify-fail loops (pairs with amcu's write-verification) | Small | **★** |
| **Scroll / viewport context** — header `~N px above/below — scroll to see more`; flag independently-scrollable containers; emit refs for `<area>` of `<img usemap>` | browser-use scroll annotations; Notte pixels-above/below; Vimium "Scroll."/`getClientRectsForAreas` | Kills "why is the button missing" confusion and blind scrolling; surfaces actionable regions with no other handle; geometry amcu already trusts | Small | **★** |
| **Scoped subtree snapshot** — `snapshot --within e12` | Stagehand `focusLocator` | Re-snapshot one modal/widget of a huge page instead of all of it | Small | **★** |
| **Main-world `addEventListener` detection** — a `world:"MAIN"` document_start script wraps `EventTarget.addEventListener`, recording click/mouse* registrants into a capped, liveness-pruned read-only Set; mark these refs lower-confidence | Tridactyl `hijackPageListenerFunctions` (Vimium abandoned the DOM-stamping variant, #2997) | The only way to catch the residual `<div>`-with-a-live-JS-handler — the largest interactive class amcu still misses. Perf-sensitive on listener-heavy pages → cap + prune + confidence flag | Medium–Large | **~** |
| **Nested-clickable resolution policy** — when ancestor+descendant both interactive, pick one deterministically (confirmed child > guessed ancestor, but real `<a href>` > children); annotate confidence | Vimium / Surfingkeys / Tridactyl policies | Generalizes amcu's existing cursor:pointer parent-dedup to role/handler nesting; fewer double-refs | Medium | **~** |
| **Mode-parameterized snapshot** — `--mode text\|inputs\|full` | Agent-E DOM-distillation modes | Match observation cost to task (reading vs form-filling) | Small | **~** |
| **Occlusion-aware flagging** — flag (don't delete) refs fully covered per CDP paint order; add per-ref visibility ratio | browser-use `PaintOrderRemover`; BrowserGym visibility ratio | amcu refuses covered *clicks*; flagging at snapshot time saves ever targeting them | Medium | **~** |

### B. Feedback loop — the biggest genuine gap

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Action-effect report** — every action returns `{navigated? / N DOM mutations / what popup/menu appeared / focus moved / dialog / nothing happened}` | Agent-E (MutationObserver verification), BrowserGym last-action-error field, Skyvern incremental scrape | **Uniquely valuable for amcu:** the caller is blind between calls, so "did it work?" today needs a full re-snapshot. This answers it inline | Small–Med | **★** |
| **"What appeared" via MutationObserver** — after a click, report the elements a portal/menu appended to `<body>` | Skyvern `IncrementalScrapePage` (priority-sorts overlay roots so truncation never drops them) | Complements diff (a tree-diff can miss where a portal landed); the mechanism-level answer to custom dropdowns | Medium | **★** |

### C. New action verbs / CDP capabilities amcu can expose

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **`find`** — search current snapshot by text/regex/role, return matching refs + a few lines of context | Playwright MCP `browser_find`; Claude-in-Chrome `find` | Cheaper than dumping the whole snapshot when you only need one element; pure host computation | Small | **★** |
| **Reader mode `read`** — page → markdown / readability main-content, optional `--within e12` | Steel `/pages`, browser-use `markdown_extractor`, Notte, Claude-in-Chrome `get_page_text` | The no-LLM version of everyone's `extract`; agents *read* far more than they act, today they'd `eval innerText` (noisy) | Small–Med | **★** |
| **Set-of-marks screenshot (composited *outside* the page), reusing existing refs as labels** — `screenshot --marks`: draw typed boxes (`$e12` button, `@e13` link, `#e14` textbox — tarsier sigils) whose labels **are amcu's refs**; return image + text sidecar keyed by the same refs | tarsier `tag_utils` (one ID space across pixels/OCR/DOM); Index Pillow overlay; WebVoyager/VisualWebArena mark→index | Fits amcu's philosophy: **no new ID space, amcu still doesn't interpret pixels.** But SeeAct proves marks are a *supplement*, so **gate to the regimes where vision wins**: dense grids of near-identical elements, calendar/seat pickers, unlabeled icon buttons, canvas with no a11y tree. Draw outside the page (Skyvern's in-page overlay risks changing layout) | Medium | **~** |
| **Semantic dropdown verbs** — `options e12` / `select e12 "Ohio"` for native `<select>` **and** ARIA combobox/listbox | browser-use `_handle_aria_combobox_options` | Collapses the fragile click-wait-snapshot-click dance on the highest-frequency composite widget | Medium | **~** |
| **Download awareness** — report `click triggered download: invoice.pdf (2.3 MB, complete, /path)`; a `downloads` query verb | browser-use downloads watchdog; Claude-in-Chrome | A click that starts a download currently looks like a no-op; the MV3 extension gets `chrome.downloads` events for free (no debugger needed) | Small–Med | **~** |
| **Network body capture** — `net get <id> --part req/resp-headers/body`, paginate + URL/type filter, offload big bodies to files | chrome-devtools-mcp `get_network_request`; Playwright MCP | amcu already captures metadata; bodies are `Network.getResponseBody` on the session it holds; files are trivial for a local host | Small–Med | **~** |
| **Coordinate-click fallback** — `click --at x,y`, mouse down/up/wheel; deterministic screenshot downscale with published scale factor | Playwright `--caps=vision`; Anthropic/OpenAI CUA | Unlocks canvas/Flutter/cross-origin frames for a vision-capable caller; gate so ref-based stays default | Small | **~** |
| **Emulation** — network/CPU throttle, device/viewport/DPR, `colorScheme` dark/light, geolocation; auto-restore on session end | chrome-devtools-mcp `emulate` | Single CDP calls on the existing session; `colorScheme`+viewport alone cover most "check my responsive/dark build" asks | Small | **~** |
| **`batch`** — run N steps in one round-trip, stop on first staleness with step index + fresh snapshot; classify verbs read-only vs state-changing | Claude-in-Chrome `browser_batch`; Playwright/chrome-devtools `fill_form` | Native-messaging round-trips are cheap but LLM turns aren't; suits amcu's verify-each-step discipline; pure-read batches auto-approvable | Medium | **~** |
| **PDF export** — `Page.printToPDF` | Playwright `--caps=pdf` | One CDP call — **verify headed support through chrome.debugger first** (was headless-only historically; `Page.captureSnapshot` MHTML is the fallback) | Small + spike | **~** |
| **Request mocking / offline** — `Fetch.enable` stub/block/rewrite; `Network.emulateNetworkConditions offline` | Playwright `--caps=network` | Routes persist in amcu's long-lived host across short CLI calls (a fit for its process model); killer use = frontend devs testing error paths against their real logged-in session | Medium | **~** |
| **Cookie / storage tools + storage-state save/restore** | Playwright `--caps=storage` (17 tools) | Auth debugging — **but on a real profile this is a credential-exfiltration primitive; gate behind an explicit opt-in cap** | Small + policy | **~** |
| **WebMCP bridge** — `webmcp list/call` over the tab's `document.modelContext` tools | chrome-devtools-mcp `list_webmcp_tools`; W3C origin trial Chrome 149–156 | Content-script access makes it nearly free; strategically differentiating. **But supply is thin and the API is still moving — ship as a thin experimental verb, not a pillar** | Medium | **~** |
| **User-picked-element handoff** — extension context-menu "send to amcu" stamps a ref on the element the human points at | browser-tools `getSelectedElement`; Claude-in-Chrome | Natural for amcu's extension; **impossible for any port-launch/CDP tool to copy** | Small–Med | **~** |

### D. Reliability / actionability gating (Playwright's precise mechanisms)

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Two-rAF stability gate** — before dispatching input, require the target's `getBoundingClientRect()` exactly equal across 2 consecutive `requestAnimationFrame` ticks; else retry | Playwright `_checkElementIsStable` (`stableRafCount=1`) | Cheap in-page check; kills "clicked while still animating/laying out" flakes that amcu's single pre-click `elementFromPoint` cannot catch | Small | **~ (lean adopt)** |
| **Real-event hit-target interceptor** — a capture-phase `window` listener re-validates the hit target on the *actual trusted event* and cancels the whole event burst on mismatch, naming the intercepting overlay | Playwright `setupHitTargetInterceptor`/`expectHitTarget` | Upgrades amcu's *pre-dispatch* obscured check to *during-dispatch*; amcu already delivers trusted CDP input (the exact precondition — only `isTrusted` events are checked) and already names covers | Medium | **~** |
| **Bounded retry + scroll-alignment cycling** — retry click/type at `[0,20,100,100,500]`ms to a deadline, re-checking visible/stable/enabled, cycling `scrollIntoView` end→center→start | Playwright `_retryAction` | The alignment cycling specifically defeats `position:sticky` headers over the target; amcu does one attempt today | Medium | **~** |
| **`--wait-for` element/URL** — poll for "a ref matching role+name is visible/hidden" or a URL, at `[100,250,500,1000]`ms; expose `load`/`domcontentloaded`/`commit` but **not** `networkidle` as default | Playwright web-first assertions + `waitFor` (they deprecate networkidle) | Deterministic "act once this appears" instead of fixed sleeps; reuses amcu's role+name machinery. (Caveat Playwright itself flags: no check for hydration/listener-attachment exists) | Medium | **~** |
| **Element fingerprint** — content-addressed handle (cleaned attrs+structure hash) that survives reload/session; accept `click h:3fa2…` | Skyvern `hash_element` gated replay; browser-use triple-hash | Enables scripted/recorded flows with amcu's verify-or-refuse as the failure mode | Medium | **~** |

### E. Recording / replay

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Record → JSON macro → deterministic replay (agent as self-healer)** — `amcu record` observes real clicks/inputs → command script keyed by role+name+fingerprint → `amcu replay` runs it with existing verification, stops with a precise divergence report | workflow-use, Automa element-picker, Stagehand observe/replay, BrowserOS timeline | Every dependency (trusted input, verification, fingerprints) already exists or is above; the *healing loop stays in the caller* — the correct half of self-healing for a mechanism tool | Large | **~** |
| **Per-step diagnostics trail** — persist screenshot + outline + action + result per step | Skyvern, BrowserOS scrubbable timeline | Cheap trust/debug artifact (amcu already screenshots) | Small–Med | **~** |

### F. Safety & secrets (observation-layer, no LLM — label facts the attacker can't fake)

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Secrets redaction** — `--secrets .env`: type by key reference; mask those values in snapshots, console, network, and echoes of typed text | Playwright MCP `--secrets`; browser-use `sensitive_data` (+ domain allowlist) | amcu drives the **real logged-in browser**, so a password in an LLM transcript is a bigger risk than for any sandboxed tool; a host-side filter is cheap | Small | **★** |
| **Cross-origin provenance + hidden-to-human flags** — tag each snapshot subtree with its frame origin; flag/strip content invisible to a human (color≈background, `font-size≈0`, `opacity:0`, off-screen, clipped, hidden form fields), leaving a placeholder | UW SOP attack, Brave "unseeable", Anthropic hidden-field channel, BrowseSafe (~84% of hidden channels detectable from structure); Microsoft spotlighting (ASR >50%→<2%) | **Zero-false-positive facts the attacker can't fake**, from data amcu already has (frame refs). Note amcu's `checkVisibility` does **not** catch color-on-color / `opacity:0` / tiny fonts — so this genuinely adds coverage — and *every* demonstrated browser-agent injection relied on hidden text. This is amcu's prompt-injection floor | Medium | **~ (lean adopt)** |
| **Sensitive-target flags + origin allow-list + `--confirm`** — flag refs whose *target* is sensitive (password / `autocomplete=one-time-code` / `cc-*` fields, cross-origin form POST, uploads, Buy/Pay/Delete/Publish); optional per-session origin allow/deny-list + `--confirm` gate on flagged targets | The universal product three-tier taxonomy — Google machine-readable `safety_decision` categories, Anthropic always-confirm list + site permissions, Microsoft deterministic blocking | Classifies the *target*, not intent — no LLM; blast-radius control + a speed-bump on irreversible actions, mirroring every shipped product, without amcu judging malice | Small–Med | **~** |

### G. Anti-detection (only if you target bot-defended sites)

**Context:** amcu is already immune to ~90% of what stealth frameworks fight, because those tools
exist to *fake* the real, logged-in profile amcu simply drives. `navigator.webdriver` is false; no
ChromeDriver/`cdc_`/`__pwInitScripts` artifacts; real UA/WebGL/canvas/fonts/timezone; real cookies;
CDP input is genuinely `isTrusted`. Its only residual tells: (1) the `Runtime.enable` leak —
**already defused by a May-2025 V8 change**, low risk; (2) behavioral input dynamics.

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Humanized input pacing + coordinate jitter** — bezier mouse move with overshoot before click; per-key dwell 40–120 ms / gaps 60–200 ms from a jittered distribution; click a random point inside the target bbox, not its center | ghost-cursor / HumanCursor; nodriver | The one detection vector that still applies to amcu; gate behind `--human`/`--stealth` | Low–Med | **~** |
| **Optional isolated-world eval** — run `Runtime.evaluate` against a `Page.createIsolatedWorld` context so `Runtime.enable` is never resident on the main world | patchright, rebrowser-patches | Defense-in-depth / future-proofs against a V8 regression; keep main-world eval where amcu needs page globals | Medium | **~** |

### H. Architecture

| Idea | Who / how | Value to amcu | Cost | Verdict |
|---|---|---|---|---|
| **Multiplexed sessions over one debugger attachment + conflict reporting** — one `chrome.debugger` attach per tab, refcount domain enables, fan events to N logical CLI sessions; on attach-fail/`onDetach` report *who* holds it (DevTools open, `replaced_with_devtools`) and offer `--take-over`; auto-reattach when DevTools closes | Playwright extension relay, playwriter.dev multiplex the same way; chrome-devtools-mcp #1763 shows the failure when clients don't coordinate | amcu's native host is *already* the single long-lived broker — this turns the architecture into a genuine advantage over port-9222 tools | Medium | **~** |

---

## Explicitly SKIP (wrong layer for a no-LLM mechanism, or actively harmful)

- **NL `act`/`extract`/`observe`, planner-navigator-validator splits, semantic action-space tagging**
  (Stagehand, nanobrowser, Skyvern, Notte) — planning belongs in amcu's *caller*. Browserbase
  *archived* its `act/observe/extract` MCP server in July 2026; the field's own verdict is that the
  NL layer belongs in the agent, not the driver. ✗
- **Vision-LLM grounding / coordinate-only agents** (UI-TARS, CUA loop) — amcu hands text + geometry
  to the caller's vision; that's the boundary. (The *fallback* coordinate-click, C, is the residue;
  and SeeAct's 39.1% vs 20.3% is why marks stay supplementary.) ✗
- **Full set-of-marks / SAM segmentation, tarsier OCR "ASCII-art" text mode** — make amcu a vision
  system and/or duplicate its aria snapshot. ✗
- **Fingerprint spoofing** (camoufox, patchright), `--disable-blink-features=AutomationControlled`,
  launch-flag surgery — amcu's real profile is its biggest anti-detection asset; fake fingerprints
  *introduce* inconsistencies and make it **more** detectable. ✗
- **Vaults / personas / 2FA / CAPTCHA / proxies / stealth infra** (Skyvern, Notte, Steel) —
  account/infra layer; amcu's real-profile premise makes most unnecessary. ✗
- **Monitor/classifier injection models, CaMeL** — need an LLM/whole agent architecture; the
  deterministic labeling in F is the non-LLM fit. ✗
- **Lighthouse / heap-snapshot / full perf-trace suites** — huge surface. *Possible later:* a minimal
  `trace start/stop` → Core-Web-Vitals summary using chrome-devtools-mcp's good "pre-digest a trace
  into named insights" pattern. Not now. ✗ (for now)
- **WebDriver BiDi adoption** — no benefit inside Chromium today; only relevant for a future Firefox
  story. ✗

---

## If I had to pick a first slice

Cheapest changes that most improve amcu as a *mechanism*, all pure content-script/host work, all in
amcu's identity:

1. **Action-effect report** (B) — removes the blind-caller re-snapshot tax; biggest single UX win.
2. **Snapshot diff / `*new`** (A) — biggest single token win.
3. **Handler-driven clickables** (A) — `jsaction`/`ng-click`/`onmouse*`/wider roles + CDP
   `isClickable`; closes the one real correctness gap, cheaply, before the heavier main-world route.
4. **Validation attributes + scroll context** (A) — trivial, high signal-per-token.
5. **`find` + scoped `--within`** (C/A) — cheap token controls.
6. **Two-rAF stability gate** (D) — one cheap check, removes the main flaky-misclick cause.
7. **`--secrets` redaction + hidden-text/cross-origin flags** (F) — the safety floor amcu's
   real-profile premise arguably *requires*, and its deterministic prompt-injection defense.

Everything below that is a genuine "maybe" to rank.

---

## Projects surveyed (primary sources)

**Agent frameworks:** browser-use (109k★), Stagehand/Browserbase (24k★), Skyvern (23k★), Agent-E
(Emergence), nanobrowser (13.6k★), Notte, BrowserGym (ServiceNow, +2412.05467), Index (Laminar,
archived), UI-TARS (ByteDance), workflow-use, Automa, LaVague (dormant), fuji-web (dormant).
**MCP / protocol:** Playwright MCP (Microsoft, 36k★), chrome-devtools-mcp (Google, 49k★), BrowserMCP,
browser-tools-mcp (AgentDesk), executeautomation/mcp-playwright, mobile-mcp, steel-browser, Browserbase
MCP (archived), Puppeteer MCP (archived), WebMCP/MCP-B (W3C origin trial), Claude-in-Chrome (amcu's
native-messaging twin), WebDriver BiDi.
**Hints / vision / reliability / safety / stealth:** Vimium, Tridactyl, Surfingkeys, Vimari; tarsier,
SeeAct (2401.01614), WebVoyager (2401.13919), Set-of-Mark (2310.11441), VisualWebArena (2401.13649);
OpenAI Operator/Atlas system card, Anthropic Claude for Chrome, Google Gemini Computer Use, Edge
Copilot; Playwright actionability (injectedScript.ts / dom.ts); Brave Comet + "unseeable", UW SOP,
Microsoft spotlighting (2403.14720); rebrowser-patches, nodriver/zendriver, patchright, camoufox,
SeleniumBase UC, ghost-cursor.

---

## Joint review verdict (2026-08-17: Fable 5 advisor × gpt-5.6-sol, two rounds w/ cross-examination)

Both reviewers independently critiqued the tables above, then each defended its most contrarian
calls against the other. Converged conclusions:

**Corrections to this doc (accepted):**
- "Zero-false-positive hidden-to-human facts" is **wrong** — sr-only labels, live regions, drag
  handles use the same CSS techniques. And "every demonstrated injection relied on hidden text" is
  overstated; visible-content injections are documented.
- Network/console secret redaction can never be reliable (encodings/fragmentation defeat matching)
  — ship only as documented best-effort; snapshot/echo masking is the reliable part.
- `chrome.downloads` events carry no tabId — download awareness is session-scoped reporting, not
  per-click causation.
- `Page.createIsolatedWorld` does not scope `Runtime.enable` (session-global); moot post the V8 fix.
- `DOMSnapshot.isClickable` is not cheap at scale, not a complete listener registry, and marks
  delegated ancestors, not the model-useful descendant. Sequence it AFTER the first batch, measured.
- `[onmouseover]` is not a click signal — drop it from the handler-attr widening.
- Validation constraints must read live IDL properties, not just serialized attributes.

**Agreed revised first batch:**
1. **Change-tracking layer** (merged: action-effect report + snapshot diff/`*new` + "what
   appeared") — ONE retained-state mechanism keyed by an explicit snapshot **generation id**;
   generation-to-generation diff is authoritative, MutationObserver records enrich only; report
   temporal association, not causation; `settled: false` for never-quiescent pages. No
   `--if-generation` action gating (node-identity ref checks already cover the ABA case).
2. **Conservative handler-driven clickables** — `jsaction` (click rules), gated `ng-click`,
   `onmousedown/up`, wider ARIA roles. No onmouseover, no isClickable yet.
3. **Validation attributes** (live IDL) — in the same single documented snapshot-format revision as
   1's markers. Scroll-context header: minimal top-document version only (nested-scroller geometry
   deferred).
4. **`find` + `snapshot --within`** — search a named generation, not the live tree; expired
   `--within` ref is a refusal, not silent widening.
5. **`--wait-for`, narrowed** — URL/lifecycle (+ later download/new-target) first; element
   role+name waits reuse the existing verification matcher as a follow-up. Extends the existing
   `wait` verb. Removes agent-side sleep/poll races (correctness, not convenience).
6. **Two-rAF stability gate** — pre-dispatch only; never retry after a trusted event was delivered.
7. **`--secrets`** (type-by-key + snapshot/echo masking; net/console labeled best-effort) +
   **frame-origin provenance** + **facts-only visibility anomalies** (opacity:0, font-size≈0,
   color≈background, hidden inputs — emitted only when anomalous; no "suspicious" label,
   judgment stays in the caller).

**Deliberately after the batch:** `read` (hand-rolled heuristic first — prefer article/main,
density filter — Readability vendoring is a separate evidence-driven decision), CDP `isClickable`
measurement (its numbers decide whether main-world addEventListener wrapping is ever needed),
download awareness (session-scoped), element role+name waits, sensitive-target structural flags.

**Format discipline:** every snapshot text change (markers, attrs, flags, scroll header) lands as
one documented format revision, not dribbled across releases — LLM callers parse this text.

---

## Second batch (2026-09-03): browser-use org re-survey, desktop harnesses included

*Sources: browser-use `main` (Python agent + browser-harness pivot), macOS-use, macos-harness,
windows-harness, workflow-use, desktop, profile-use. Filter unchanged: does it make the mechanism
better without adding a concept? amcu's concept count stays at five — snapshot, ref, act, verify,
report — so everything below lands inside existing verbs.*

**Shipped in 0.8.1:**

- **`--target` as a synonym for `--ref`, and `--element "…"` as a pre-action check.** The names are
  Playwright MCP's (`target` + `element`), because that is the vocabulary most models were trained
  on; a model that reaches for them hits first time instead of after an error round-trip. `--element`
  never selects — it is the caller's belief about what the ref is, compared against the live element's
  role and name through the content script's `describe` op before the verb runs, refusal code
  `element_mismatch`. Lenient by design: role words (button, input, 按钮, 输入框 …) are optional, the
  remaining words need only appear in the element's description. No MCP server: the CLI plus a
  one-paragraph skill stays cheaper per session than any tool schema, and every host here has a shell.

**Shipped in 0.8.0:**

- **`addEventListener` click handlers → `[clickable]`** (browser-use `has_js_click_listener`). Done
  through `DOMDebugger.getEventListeners` over the document subtree (one protocol call, ~1 ms) plus
  a `DOM.getDocument` walk to turn backendNodeIds into DOM-order positions, only while the tab is
  already attached — a snapshot never attaches on its own, so reading stays infobar-free. Positions
  travel with a tag|id|class signature and are re-matched in the content script; a mismatch is
  dropped. Measured on the way: browser-use's route (the command-line API `getEventListeners` via
  `Runtime.evaluate includeCommandLineAPI`) returns *nothing* inside a chrome.debugger session while
  a raw CDP session on the same tab lists everything — so the protocol method is not a preference,
  it is the only one that works from an extension. Delegated handlers (React at the root) are not
  on the element and are not found — stated, not hidden. Refs that exist only because of the first
  scan are not marked `[new]`. This supersedes the "main-world addEventListener wrapping" maybe above.
- **`[covered]`** (browser-use `PaintOrderRemover`, but flag-not-delete as decided above, and via the
  same `elementFromPoint` hit test the click uses rather than CDP paint order — no debugger needed).
  Display-only marker like `[new]`: `find`/`--diff` ignore it.
- **`[scrollable: N px above, M px below]`** on independently scrollable containers, which get a ref
  so `scroll --ref` works (the "nested-scroller geometry" deferred in batch one).
- **Opened-tab report + follow** (browser-use `_detect_new_tab_opened`). `click`/`key`/`type --submit`
  report a tab the action opened; when acting on the session's current tab, the new tab becomes
  current. Matched by `openerTabId`, never by timing alone.
- **`KEY__DOMAINS` secret scope** (browser-use domain-scoped `sensitive_data`). Enforced in the
  extension against the tab host *and* the target frame's host; refusal code `secret_scope`.
- **Desktop focus guard** (macos-harness `_guard_focus`). Frontmost app read via the system-wide AX
  element before/after every background pointer/keyboard delivery; a background target that became
  frontmost is reported as a warning. Nothing is restored — that would be a second disturbance.
- **Chromium host detection from the bundle** (`Contents/Frameworks` contains Electron/CEF/browser
  frameworks) alongside the bundle-id whitelist. macos-harness's alternative — set
  `AXEnhancedUserInterface` on every app — is rejected for the `AXPosition` breakage documented in
  `ChromiumAccessibility.swift`.
- **Guide: how each input kind actually reaches the app** (macos-harness issue #6/#7 truth table:
  PID-posted mouse events are dropped by AppKit unless window-routed; keyboard always lands; AXPress
  cannot activate). amcu's window-routed path already covers the mouse case; the guide now says so
  and names the activation side effect.

**Looked at, not adopted (and why):**

- `AXUIElementsForSearchPredicate` for a desktop `find` — real value for Electron/virtualised
  trees, but a new verb; deferred until a desktop `find` exists for other reasons.
- Text-input "ladder" with automatic fallback (windows-harness). Would make `set-value` do three
  things; amcu keeps `set-value`/`replace`/`type` as separate verbs and instead lets the error
  message name the next verb.
- Action-proof screenshots and normalised 0..1000 coordinates (windows-harness). Both equip the
  coordinate path; amcu's centre of gravity is refs.
- `allowed_domains` navigation policy, agent loop, planner, judge, `--profile` copying, heredoc
  "agent writes Python" execution model, CDP-port launch mode. Wrong layer or contrary to "the
  user's own browser".
- browser-use's `backendNodeId` indices. Large, reload-unstable; amcu's `e12` + role/name
  re-verification already prevents the Save-vs-Quit class of handle aliasing that macos-harness
  #11 reports.
- React controlled-input clearing: already covered — `fill` types through trusted `insertText`
  over a selected value, and `set-value` uses the native setter + input/change events.
- `<select>` options inline: already in the snapshot.
