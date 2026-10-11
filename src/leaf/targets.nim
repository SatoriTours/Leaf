## Shared build selection; selecting native never falls through to GPUI.
import ./core
type
  BackendChoice* = enum backendGpui, backendNative
  BuildSelection* = object
    target*: string
    backend*: BackendChoice
    headlessOnly*: bool
proc hostTarget*(): string =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: "unsupported"
proc parseBackend*(value: string): BackendChoice =
  case value
  of "gpui": backendGpui
  of "native": backendNative
  else: fail("backend must be gpui or native")
proc resolveBuild*(configured: BackendChoice, target = "", backend = "",
                   headlessOnly = false): BuildSelection =
  result = BuildSelection(target: (if target.len == 0: hostTarget() else: target),
    backend: (if backend.len == 0: configured else: parseBackend(backend)),
    headlessOnly: headlessOnly)
  if result.target notin ["windows", "linux", "macos"]: fail("unsupported build target: " & result.target)
proc validateHost*(selection: BuildSelection) =
  if selection.target != hostTarget(): fail("cross compilation is not configured; build on target " & selection.target)
  if not selection.headlessOnly and selection.backend == backendNative:
    when not (defined(windows) and defined(amd64)):
      fail("native windows require a Windows x64 build host")
