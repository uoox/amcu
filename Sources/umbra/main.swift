import Foundation
import UmbraCore

let version = "0.1.0"

let helpText = """
umbra \(version) — read and drive macOS applications without taking the user's screen

USAGE
  umbra <command> [flags]

INSPECT
  apps                                  list running applications (pid, bundle id, name)
  windows      --app S                  list an application's windows with ids and frames
  snapshot     --app S                  capture the accessibility tree as indexed text
  doctor                                check permissions and verify background delivery

ACT
  click        --app S --element N      press an element by its snapshot index
  click        --app S --at X,Y         click a point (window-relative unless --screen)
  action       --element N --action A   perform any action the element advertises
  set-value    --element N --value V    set an element's value directly
  type         --app S --text T         type literal text into the focused element
  paste        --app S --text T         paste text via the pasteboard (input-method safe)
  key          --app S --key K          press a key, with --mod cmd,shift
  scroll       --app S --dy N           scroll, optionally at --at X,Y
  drag         --app S --from X,Y --to X,Y
  screenshot   --app S [--out FILE]     capture one window, occluded or not

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

NOTES
  Element indices come from the most recent snapshot in the same session and are
  re-verified before use; if the interface changed, umbra reports a stale
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
    case "click": try Commands.click(flags)
    case "action": try Commands.action(flags)
    case "set-value": try Commands.setValue(flags)
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
        Output.fail(UmbraError(.invalidArgument, "unknown command '\(command)'", nextSteps: ["Run `umbra help` for the command list."]))
    }
} catch {
    Output.fail(error)
}
