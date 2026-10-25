## Default desktop launch and explicit headless automation share one runtime.
##
## With `-d:leafHeadlessOnly` the desktop backend is never imported, so a
## headless build links no graphics toolkit and cannot silently open a window.
import std/os
import ./[core, headless]

when defined(leafHeadlessOnly):
  proc run*(app: Application, args: seq[string], cleanupOwner: ptr Runtime = nil): int =
    if cleanupOwner != nil and cleanupOwner[] != nil: fail("cleanup owner slot must be empty")
    if args == @["--help"] or args == @["-h"]:
      stdout.write(helpText())
      return 0
    if "--headless" in args or "--check" in args: return runHeadless(app, args, cleanupOwner)
    stderr.writeLine("leaf: this build has no desktop backend; use --headless or --check")
    return 1
else:
  import ./[developer_options, diagnostics]
  when defined(windows):
    import ./backends/win32

  proc run*(app: Application, args: seq[string], cleanupOwner: ptr Runtime = nil): int =
    if cleanupOwner != nil and cleanupOwner[] != nil: fail("cleanup owner slot must be empty")
    if "--headless" in args or "--check" in args: return runHeadless(app, args, cleanupOwner)
    if args == @["--help"] or args == @["-h"]:
      when defined(windows):
        stdout.writeLine("Without arguments, launch the Win32 native controls window.")
      else:
        stdout.writeLine("Native GUI backend not implemented on this platform; use --headless or --check.")
      stdout.write(helpText())
      return 0
    try:
      let options = parseDeveloperOptions(args)
      if options.watching or options.remaining.len > 0:
        fail("unknown desktop option; use --headless for event commands and the CLI for --watch")
      let diagnostics = options.diagnostics()
      var preservingOwner = false
      defer:
        if preservingOwner or (cleanupOwner != nil and cleanupOwner[] != nil):
          try: diagnostics.close()
          except CatchableError: discard
        else: diagnostics.close()
      try:
        when defined(windows):
          return runNative(app, diagnostics = diagnostics, cleanupOwner = cleanupOwner)
        else:
          fail("native GUI backend not implemented on this platform; use --headless or --check")
      except CatchableError as error:
        preservingOwner = error of RuntimeCleanupError and cast[ref RuntimeCleanupError](error).cleanupRuntime != nil
        when defined(windows):
          if error of Win32RunError and cast[ref Win32RunError](error).cleanupHost != nil:
            preservingOwner = true
        raise
    except CatchableError as error:
      if error of RuntimeCleanupError and cast[ref RuntimeCleanupError](error).cleanupRuntime != nil: raise
      when defined(windows):
        if error of Win32RunError and cast[ref Win32RunError](error).cleanupHost != nil: raise
      stderr.writeLine("leaf: " & error.msg)
      return 1

proc run*(app: Application, cleanupOwner: ptr Runtime = nil): int = run(app, commandLineParams(), cleanupOwner)