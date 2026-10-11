## Default desktop launch and explicit headless automation share one runtime.
##
## With `-d:leafHeadlessOnly` the desktop backend is never imported, so a
## headless build links no graphics toolkit and cannot silently open a window.
import std/os
import ./[core, headless]

when defined(leafHeadlessOnly):
  proc run*(app: Application, args: seq[string]): int =
    if args == @["--help"] or args == @["-h"]:
      stdout.write(helpText())
      return 0
    if "--headless" in args or "--check" in args: return runHeadless(app, args)
    stderr.writeLine("leaf: this build has no desktop backend; use --headless or --check")
    return 1
else:
  import ./[developer_options, diagnostics]
  when defined(leafNativeWin32):
    import ./backends/win32
  else:
    import ./desktop

  proc run*(app: Application, args: seq[string]): int =
    if "--headless" in args or "--check" in args: return runHeadless(app, args)
    if args == @["--help"] or args == @["-h"]:
      when defined(leafNativeWin32):
        stdout.writeLine("Without arguments, launch the Win32 native controls window.")
      else:
        stdout.writeLine("Without arguments, launch the native GPUI + GPUI Kit desktop window.")
      stdout.write(helpText())
      return 0
    try:
      let options = parseDeveloperOptions(args)
      if options.watching or options.remaining.len > 0:
        fail("unknown desktop option; use --headless for event commands and the CLI for --watch")
      let diagnostics = options.diagnostics()
      defer: diagnostics.close()
      when defined(leafNativeWin32):
        return runNative(app, diagnostics = diagnostics)
      else:
        return runDesktop(app, diagnostics = diagnostics)
    except CatchableError as error:
      stderr.writeLine("leaf: " & error.msg)
      return 1

proc run*(app: Application): int = run(app, commandLineParams())