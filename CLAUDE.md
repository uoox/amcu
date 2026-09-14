# amcu — agent development guide

amcu is a macOS computer-use CLI for AI agents: accessibility-tree reading, background input delivery, OCR fallback, and a browser bridge. One SwiftPM package, no dependencies, one binary. This repository is developed by AI agents; there are no human-oriented docs beyond `README.md`. Read this file, then `docs/ARCHITECTURE.md` (module and function map) and `docs/DESIGN.md` (the decisions and why) before touching code. Together they are meant to replace reading the whole tree.

## Non-negotiable invariants

1. **Never disturb the user silently.** No command moves the cursor, changes focus, raises a window or activates an app unless the flag that asks for it was passed (`--mode foreground`, `window --raise`, `--activate`). If a background action stole focus anyway, the result says so (`FocusGuard`).
2. **Never report success on a no-op.** Disabled controls are refused, writes are read back, stale indices are detected, `# no change` is printed when an action changed nothing. Every failure is an `AmcuError` with a `code` and `nextSteps` written for an agent.
3. **Text before pixels.** The accessibility tree is the primary channel; OCR (`scan`) and coordinates are fallbacks the agent must opt into.
4. **Private API is verified, not trusted.** `CGEventSetWindowLocation` and `_AXUIElementGetWindow` are resolved with `dlsym`; `SelfCheck` proves the routed-click path per OS build before `--mode auto` uses it.
5. **The guide in the binary is the contract.** `Sources/amcu/Guide.swift` and `BrowserGuide.swift` are what agents read. Any behaviour change ships with a guide change in the same commit. `README.md` stays short.
6. **amcu positions itself as *the* computer-use / browser-use tool.** `Sources/amcu/Skill.swift` (printed by `amcu skill`, installed by `amcu skill --install`, mirrored in `skills/amcu/SKILL.md`) must keep saying so explicitly, because agent models are trained to prefer whatever is labelled "computer use" / "browser use". Skills are shared through skill directories; an MCP server, if ever added, is a thin optional layer the skill mentions ("if `amcu_*` tools exist, use them").

## Layout

```
Sources/AmcuCore/   library: AX access, snapshot/diff, input, settle, policy, browser bridge, lab
Sources/amcu/       CLI: main.swift dispatch, Commands.swift (desktop verbs), BrowserCommands.swift,
                    LabCommands.swift, Batch.swift, AfterAction.swift, Guide.swift, BrowserGuide.swift, Skill.swift
skills/amcu/        SKILL.md generated from Skill.swift; what `amcu skill --install` writes
Sources/AmcuTests/  plain executable test runner (no XCTest): swift run -c release amcu-tests
Tests/e2e/          live AppKit probes + run.sh (AMCU_E2E=1), needs a logged-in session
extension/          Chrome extension source; embedded into ExtensionBundle.swift by Scripts/embed-extension.py
Scripts/            install.sh, package.sh, embed-extension.py
docs/               ARCHITECTURE.md, DESIGN.md, browser-use-ideas.md (backlog of browser ideas with verdicts)
```

## Workflow

- Build: `swift build -c release`. Test: `swift run -c release amcu-tests` (must stay green; add cases to `Sources/AmcuTests/*Tests.swift`, wire new files in `main.swift`). Live check: `AMCU_E2E=1 Tests/e2e/run.sh`.
- Changing `extension/*`: run `python3 Scripts/embed-extension.py` afterwards; CI diffs the generated file.
- Changing `Sources/amcu/Skill.swift`: run `.build/release/amcu skill > skills/amcu/SKILL.md`; CI diffs it.
- Version: bump `Sources/AmcuCore/Version.swift` **and** `extension/manifest.json`, then re-embed. Tags are `vX.Y.Z`; `Scripts/package.sh` refuses a mismatch.
- Quick live verification against TextEdit: `amcu launch --app com.apple.TextEdit`, `amcu key --app com.apple.TextEdit --key n --mod cmd`, then `snapshot`, `set-value --element N`, and read the printed diff.
- Commit messages describe behaviour from the agent-user's point of view (see `git log`).

## Code conventions

- Swift 5.9, macOS 14+. No third-party packages. `Flags` is the whole argument parser: boolean flags must be listed in `Flags.knownBooleans` or they eat the next argument.
- Errors: `throw AmcuError(.code, "message", nextSteps: [...])`. Output: `Output.emit(encodable) { textForm }`; never `print` a result directly.
- Every acting command ends with `result.apply(AfterAction.run(...))` so settle, focus check and observation happen uniformly.
- Comments explain a non-obvious *why* (a macOS quirk, a measured behaviour); do not narrate what the code does. No comments for readers who are not going to change the code.
- Keep results honest: when a value cannot be verified, say `unverified: reason`, do not drop the field.

## Current state and backlog

See `docs/DESIGN.md` §Backlog. Highest-value open items: an MCP server (`amcu mcp`) over the same Commands layer so a long-lived process keeps the AXObserver and revisions in memory; an experiment on synthetic app-activation events to reduce AppKit stealing focus on background mouse-down; the ★ items in `docs/browser-use-ideas.md` that are still unimplemented.
