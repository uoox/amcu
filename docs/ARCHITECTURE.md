# Architecture

Two targets, one binary. `AmcuCore` is the library (no CLI concerns, no printing except policy warnings); `amcu` is the CLI that parses flags, calls the core and renders results. Everything is synchronous; the few async Apple APIs (ScreenCaptureKit, `openApplication`) are bridged with a semaphore plus `CFRunLoopRunInMode` so the main run loop keeps servicing AX observers.

## Request flow (desktop verb)

```
main.swift            parse argv → Flags → dispatch(command, flags)
Commands.<verb>       Permissions.requireAccessibility → resolveTarget / SessionStore.node
                      → guard (SensitiveApps, requireEnabled, assertForegroundIsSafe)
                      → deliver (AX.perform | PointerInput | KeyboardInput | TextInput)
                      → AfterAction.run: Settle.wait → FocusGuard verdict → observe (re-capture + diff)
                      → Output.emit(result)
```

`snapshot` writes the tree to `SessionStore` (`~/Library/Caches/amcu/session-<name>.json`). Acting commands read it back, replay the node's `path` (AXChildren indices from the window) and re-verify role/subrole/identifier/label before acting.

## AmcuCore modules

| File | Purpose | Key symbols |
|---|---|---|
| `AXBridge.swift` | Thin wrappers over `AXUIElement` C API; resolves private `_AXUIElementGetWindow`. | `AX.attribute/string/bool/element/children/windows/actions/frame/perform/setValue`, `AX.windowID`, `AX.canResolveWindowID` |
| `Target.swift` | App/window resolution, app lists, launch. | `AppInfo`, `WindowInfo`, `FrameJSON`, `InstalledApp`, `Target.runningApps`, `resolveApp(selector)` (pid:/bundle id/name; ambiguity is an error), `appElement` (Chromium activation), `windows(of:)`, `selectWindow`, `recentApps` (Spotlight MDQuery), `installedApp`, `launch(selector,timeout,waitForWindow)` (activates=false, waits for a non-zero-size window) |
| `Snapshot.swift` | Tree capture and rendering. | `SnapshotLimits`, `SnapshotNode` (index, role, subrole, identifier, label, value, enabled, focused, frame window-relative, actions, depth, path, origin, identity), `Snapshot` (nodes, focusedIndex, truncation flags, shaped, maxNodes, indicesContinued), `renderLine`, `renderText(only:queryNote:)`, `SnapshotBuilder.capture(app,window,windowElement,limits,shaping,previous)`, `fromVision`, `resolve(node,windowElement)` (stale detection), `redactedValue` |
| `SnapshotDiff.swift` | Identity, stable indices, diff, query. | `SnapshotIdentity.assign(roles)` (FNV-1a of parent identity + role/subrole/identifier/label + sibling ordinal), `reuseIndices(identities,previous)` (keep matching indices, fresh ones after the previous max, restart when <40 % match), `SnapshotDiff`, `Snapshot.isComparable`, `diff(from:)` (`~`/`+`/`- [a..b]`, full tree when >60 % changed, `# no change`), `filtered(query:)` (substring or `/regex/`, per field, ancestors kept), `SnapshotNode.changeSignature` (frame excluded) |
| `TreeShaping.swift` | What the capture hides: structural containers, inner parts of compact controls, offscreen rows. | `shouldElide`, `shouldSuppressChildren`, `usesRowViewport`, `advertisesRealAction`, `maxVisibleRows` |
| `SessionStore.swift` | On-disk snapshot per session. | `save`, `load`, `loadIfPresent`, `node(index:session:)` (lookup by index value, not position) |
| `Settle.swift` | Wait until the app stops emitting AX notifications. | `Settle.wait(pid,timing)` → `SettleReport(settled,seconds,notifications)`; AXObserver on the application element; min/quiet/max from `Policy` |
| `Policy.swift` | `~/.config/amcu/policy.json`. | `Policy.current`, `parse`, `sensitiveDeny/Allow`, `immune`, `settle.min/quiet/max`, `effective` |
| `SensitiveApps.swift` | Refused-unless-asked apps and input-immune apps. | `builtinBundleIDs`, `builtinImmune`, `isSensitive`, `isImmune`, `guardAgainst` |
| `Input.swift` | Synthesized events. | `DeliveryMode` (background/foreground), `EventTag.stamp/isOurs` (magic in `eventSourceUserData`), `PointerInput.click/scroll/drag` (fields 51/52 + `CGEventSetWindowLocation` for background), `KeyboardInput.type` (unicode payload, layout independent), `press(key,modifiers)`, `TextChunker` |
| `KeyCodes.swift` | Key names → virtual key codes, modifier names → flags. | `code(for:)`, `modifier(for:)`, `knownNames` |
| `TextInput.swift` | Verified writes through AXValue. | `ActionVerification` (verified/unverified+reason), `TextInput.setValue`, `replaceSelection` → `ReplacementScope` |
| `FocusGuard.swift` | Detects a background input that activated its target. | `FocusGuard(targetPID)`, `note(settleMicroseconds:)`, `verdict` |
| `SelfCheck.swift` | Proves routed background clicks land accurately; cached per OS build. | `SelfCheck.ensure`, `probe`, `store`, `SelfCheckResult.usable/summary`, `osBuild` |
| `HitTest.swift` | AX press at a point when routing is unusable. | `AXHitTest.press(pid,at,action)` |
| `Menus.swift` | Read menu bar without opening it; find/press items. | `MenuItem`, `Menus.list`, `find(path)`, `resolve` |
| `WindowControl.swift` | Explicit window moves; focus reading. | `WindowControl.raise/setPosition/setSize/setMinimized`, `FocusInfo`, `Focus.current`, `Focus.require` |
| `Capture.swift` | ScreenCaptureKit window capture, occluded or not. | `Capture.window(id:)`, `writePNG`, `pngData` |
| `Vision.swift` | OCR fallback. | `VisionMark`, `VisionScan.recognizeText(image,windowSize,languages)`, `annotate` |
| `Redaction.swift` | Secret-bearing field detection by descriptors. | `Redaction.holdsSecret`, `placeholder` |
| `SecretStore.swift` | `--secrets .env --secret KEY` for browser fills; masks values in all output. | `load`, `value(forKey:)`, `domains`, `mask`, `maskJSON` |
| `Permissions.swift` / `Responsibility.swift` | TCC state for the host process and for amcu itself (re-exec with responsibility disclaimed). | `Permissions.effective/requireAccessibility/request/selfProbe`, `Responsibility.current`, `spawnSelfDisclaimed` |
| `ChromiumAccessibility.swift` | Ask Chromium/Electron hosts to publish their tree (`AXManualAccessibility` only). | `requiresActivation`, `looksLikeChromiumHost`, `activate` |
| `NumericBounds.swift`, `AmcuError.swift`, `Version.swift` | Input narrowing, error type with codes, version string. | `AmcuError.Code` (app_not_found, stale_snapshot, permission_denied, unsupported, …) |
| `BrowserBridge.swift` | Protocol pieces shared with the extension: framing, socket naming, ref parsing, error mapping. | `BrowserBridge.hostName`, `frame/unframe`, `socketURL`, `parseRef` (`e12`, `f42e12`), `JSONValue` |
| `NativeHost.swift` | The process Chrome spawns for the extension: relays JSON-RPC between a Unix socket (`~/Library/Caches/amcu/browser/`) and native messaging stdio. | `NativeHost.run`, `HostRuntime` |
| `BrowserClient.swift` | CLI side: discover sockets, send a request, wait for the reply. | `BrowserEndpoint`, `BrowserClient.discover/select/request` |
| `BrowserInstall.swift` | Writes native-messaging manifests for known browsers and the unpacked extension to disk. | `install`, `manifestStatuses`, `extensionOnDiskMatches` |
| `ExtensionBundle.swift` | Generated: the extension files as strings. Do not edit; run `Scripts/embed-extension.py`. | `ExtensionBundle.version/id/files` |
| `SafariBridge.swift` | Safari constants, the appex⇄relay wire (port/token from the appex Info.plist, constant-time token check), verbs refused up front, upload payloads, and `SafariRelayCore` — the socket-free queue of CLI requests, extension polls and responses (profile pinning, readiness, fast failure when nothing polls). | `SafariBridge.relayConfig/unsupportedError/isSafariSelector/uploadPayload`, `SafariRelayCore.submit/notePoll/poll/requeue/respond` |
| `SafariRelay.swift` | The relay process: Unix socket `safari-<pid>.sock` speaking the native-host protocol to the CLI, 127.0.0.1:<port> for the appex; exits after 30 idle minutes. `ensureRunning` spawns it detached from the installed app. | `SafariRelay.run/ensureRunning/runningEndpoint`, `RelaySockets` |
| `SafariExtensionHost.swift` | The appex: when the binary runs from an `.appex` it calls `NSExtensionMain` (dlsym); `AmcuSafariWebExtensionHandler` forwards each native message to the relay. | `SafariExtensionHost.isRunningAsAppex/main/forward`, `AmcuSafariWebExtensionHandler` |
| `SafariInstall.swift` | Assembles `~/Applications/amcu Safari Bridge.app` from the running binary (two copies: app = relay, appex = handler), plists, embedded extension files; signs (Developer ID > AMCU_SIGN_IDENTITY > ad-hoc), registers (lsregister, pluginkit); status + pure `diagnose` for doctor. | `install`, `uninstall`, `status`, `diagnose`, `chooseSigner`, `ownerSteps`, `appInfo/appexInfo` |
| `SafariExtensionBundle.swift` | Generated from `safari/extension/`; content script and icons come from `ExtensionBundle` (`sharedWithChrome`). | `SafariExtensionBundle.files/sharedWithChrome` |
| `Lab.swift` | Disposable Chrome with `--remote-debugging-port`, own profile. | `Lab.start/stop/status`, `findBrowser`, `State` |

## CLI modules

| File | Purpose |
|---|---|
| `main.swift` | appex detection (→ `SafariExtensionHost.main`) and the container app's no-op launch, `helpText`, native-host detection (argv[1] is `chrome-extension://…`), `dispatch(command, flags)` switch used by both the top level and `batch`. |
| `Flags.swift` | Dependency-free parser. `knownBooleans` is the list of value-less flags. Helpers: `required`, `int`, `int32`, `boundedInt`, `double`, `point`, `list`. |
| `Output.swift` | `Output.emit` (JSON or text, secrets masked), `Output.fail` (structured stderr, exit 1), `ActionResult`, `VerifiedActionResult`, `Aftermath`. |
| `AfterAction.swift` | `AfterAction.run(flags,app,guarded)`: settle → focus verdict → `observe` (re-capture the session's snapshot with the same shaping/limits, save, diff). Observation is skipped with `--no-observe` or when the session has no accessibility snapshot of that pid. |
| `Commands.swift` | Desktop verbs. Shared: `resolveTarget`, `resolveApp`, `deliveryMode` (auto never falls back to foreground), `deliverClick`, `focusGuard`, `assertForegroundIsSafe`, `snapshotWindow` (re-identify the snapshot's window), `requireEnabled`. Verbs: apps, launch, policy, windows, snapshot (`--diff`, `--query`), click, action, set-value, replace, type, focus, menu, menu-item, scan, window, key, paste, scroll, drag, screenshot, doctor. |
| `Batch.swift` | JSONL steps → `Flags` → `dispatch`. Inherits app/session/mode/window flags and json/no-observe/allow-sensitive/force/screen booleans from the batch invocation. Stops at first failure. |
| `BrowserCommands.swift` | `amcu browser` verbs, all thin: build params, `client.request(method)`, render `after`/`effect` lines. `install/doctor/uninstall --browser safari` and the hidden `safari-relay` verb route to the Safari modules; `upload` attaches file bytes for Safari. |
| `LabCommands.swift` | `amcu lab start/status/targets/cdp/stop`. |
| `Guide.swift`, `BrowserGuide.swift` | The agent-facing manuals printed by `amcu guide` / `amcu browser guide`. Keep in sync with behaviour. |
| `Skill.swift` | The SKILL.md text: positions amcu as the computer-use/browser-use tool, points to the guides. `amcu skill` prints it, `amcu skill --install [--dir D]` writes it; `skills/amcu/SKILL.md` is generated from it. |

## Extension (`extension/`)

- `background.js` (service worker): connects to the native host (`chrome.runtime.connectNative`), receives JSON-RPC requests, resolves tabs (amcu's own background window vs a user tab pinned with `tab --select`), attaches `chrome.debugger` for input/screenshot/eval/console/network, calls the content script for reading, and reports what an action caused (`settle`, `waitForNavigation`, `armObserver/reportObserver`).
- `content.js`: computes the accessibility outline in-page (roles, names, states, visibility, refs `eN`, frames `fNeN`), `measure` (click geometry), `value`, `focus`, `find`. No debugger needed for reading.
- `manifest.json` version must match `Version.swift`.

## Safari extension (`safari/extension/`)

- `background.js` (non-persistent background page): long-polls the relay with `browser.runtime.sendNativeMessage({type:"poll"})` (the appex holds each poll up to 15 s), answers with `{type:"response"}`; restarts the loop from alarms (1 min), tab events and startup. Implements the verbs with tabs/scripting/webNavigation/captureVisibleTab and the shared content script; refuses console/network/dialog/drag/resize/window.
- `content.js` is not copied: the installer writes the Chrome extension's (`extension/content.js`), whose synthetic-input ops (`synthetic-click/hover/key`, `insert-text`, `scroll-by`, `set-files`) exist for Safari.
- `manifest.json` (MV3) version must match `Version.swift`; `Scripts/embed-extension.py` refuses a mismatch.

```
CLI ─unix socket (native-host protocol)─▶ relay (app executable) ◀─TCP 127.0.0.1 + token─ appex ◀─sendNativeMessage─ background.js ─tabs.sendMessage─▶ content.js
```

## Data on disk

| Path | Content |
|---|---|
| `~/Library/Caches/amcu/session-<name>.json` | Last snapshot per session (indices, identities, paths). |
| `~/Library/Caches/amcu/selfcheck.json` | Routed-click verdict, keyed by OS build. |
| `~/Library/Caches/amcu/browser/<browser>-<pid>.sock` | Native host sockets. |
| `~/Library/Application Support/amcu/lab/` | Lab Chrome state and profiles. |
| `~/.config/amcu/policy.json` | User policy. |
| `~/Library/Application Support/amcu/extension/` | Unpacked extension written by `browser install`. |
| `~/Applications/amcu Safari Bridge.app` | Safari container app (`AMCU_SAFARI_APP` relocates it); the appex Info.plist holds the relay port and token. |
| `~/Library/Caches/amcu/browser/safari-<pid>.sock` | Safari relay socket. |
| `~/Library/Logs/amcu/safari-relay.log` | Relay stderr. |
