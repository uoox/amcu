import Foundation
import AmcuCore

let version = "0.1.0"

let helpText = """
amcu \(version) — read and drive macOS applications without taking the user's screen

USAGE
  amcu <command> [flags]

INSPECT
  apps                                  list running applications (pid, bundle id, name)
  windows      --app S                  list an application's windows with ids and frames
  snapshot     --app S                  capture the accessibility tree as indexed text
  scan         --app S                  optical fallback: recognise text and where it is
  menu         --app S                  read the menu bar without opening it
  focus        --app S                  report what currently has keyboard focus
  doctor                                check permissions and verify background delivery

ACT
  click        --app S --element N      press an element by its snapshot index
  click        --app S --at X,Y         click a point (window-relative unless --screen)
  action       --element N --action A   perform any action the element advertises
  set-value    --element N --value V    set an element's value directly, then read it back
  replace      --element N --text T     replace the selection through the accessibility API
  type         --app S --text T         type literal text into the focused element
  paste        --app S --text T         paste text via the pasteboard (input-method safe)
  key          --app S --key K          press a key, with --mod cmd,shift
  scroll       --app S --dy N           scroll, optionally at --at X,Y
  drag         --app S --from X,Y --to X,Y
  menu-item    --app S --path "A > B"   invoke a menu command, by shortcut where possible
  screenshot   --app S [--out FILE]     capture one window, occluded or not
  window       --app S --raise|--move X,Y|--resize W,H|--minimize|--restore

SELECTORS
  --app accepts a bundle id (com.apple.finder), pid:1234, or an application name.
  Bundle id and pid are stable across system languages; names are not.
  --window-id / --window-index choose among an application's windows.

DELIVERY
  --mode auto        (default) semantic actions where possible, else verified
                     background delivery; refuses to steal focus silently
  --mode background  route events to the target window without moving the cursor
  --mode foreground  post to the global event tap — moves the cursor, takes focus

COMMON FLAGS
  --json             machine-readable output on stdout, structured errors on stderr
  --session NAME     namespace for snapshot state (default: "default")
  --screen           interpret coordinates as absolute screen coordinates
  --expect-focus S   refuse to type unless the focused element matches S
  --allow-sensitive  permit acting on a password manager (refused by default)

OPTICAL FALLBACK
  Some windows draw their own interface and publish nothing useful to the
  accessibility API; `snapshot` says so when it sees one. `scan` recognises the
  text in such a window and gives each piece an index in the same space as
  accessibility elements, so `click --element N` works either way. Recognised
  text carries no role, no state and no actions, and cannot be re-verified
  before a click, so scans expire (--max-age, default 60s).
  `scan --annotate out.png` writes a numbered overlay for a model to look at.

MENUS
  Menu items and their keyboard equivalents can be read without opening any
  menu. `menu-item` prefers sending the item's shortcut, which invokes the
  command without the menu appearing on screen; --press forces the visible
  route for items that have no shortcut.

WINDOW CONTROL
  Raising, moving and resizing visibly disturb the user, so no other command
  does them implicitly — `window` exists to make that an explicit request.

TEXT INPUT
  `set-value` and `replace` write through the accessibility API and read the
  value back, so a write the application silently refused is reported as a
  failure rather than a success. Neither needs focus, the front window, or a
  compatible input method — unlike `type`, which synthesises keystrokes and
  therefore cannot be verified.

NOTES
  Element indices come from the most recent snapshot in the same session and are
  re-verified before use; if the interface changed, amcu reports a stale
  snapshot instead of clicking the wrong control.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !command.hasPrefix("--") else {
    if arguments.contains("--version") {
        print(version)
        exit(0)
    }
    print(helpText)
    exit(arguments.isEmpty ? 0 : 1)
}

do {
    let flags = try Flags(Array(arguments.dropFirst()))
    Output.json = flags.has("json")

    if flags.has("help") {
        print(helpText)
        exit(0)
    }

    switch command {
    case "apps": try Commands.apps(flags)
    case "windows": try Commands.windows(flags)
    case "snapshot": try Commands.snapshot(flags)
    case "scan": try Commands.scan(flags)
    case "menu": try Commands.menu(flags)
    case "menu-item": try Commands.menuItem(flags)
    case "focus": try Commands.focus(flags)
    case "window": try Commands.window(flags)
    case "click": try Commands.click(flags)
    case "action": try Commands.action(flags)
    case "set-value": try Commands.setValue(flags)
    case "replace": try Commands.replace(flags)
    case "type": try Commands.type(flags)
    case "paste": try Commands.paste(flags)
    case "key": try Commands.key(flags)
    case "scroll": try Commands.scroll(flags)
    case "drag": try Commands.drag(flags)
    case "screenshot": try Commands.screenshot(flags)
    case "doctor": try Commands.doctor(flags)
    case "help": print(helpText)
    case "version": print(version)
    default:
        Output.fail(AmcuError(.invalidArgument, "unknown command '\(command)'", nextSteps: ["Run `amcu help` for the command list."]))
    }
} catch {
    Output.fail(error)
}
