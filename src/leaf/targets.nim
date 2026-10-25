## Native-only build selection; unsupported GUI targets never fall back.
import ./core
type
  BackendChoice* = enum backendNative
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
  of "native": backendNative
  else: fail("backend must be native; other backends have been removed")
proc resolveBuild*(configured: BackendChoice, target = "", backend = "",
                   headlessOnly = false): BuildSelection =
  result = BuildSelection(target: (if target.len == 0: hostTarget() else: target),
    backend: (if backend.len == 0: configured else: parseBackend(backend)),
    headlessOnly: headlessOnly)
  if result.target notin ["windows", "linux", "macos", "android"]: fail("unsupported build target: " & result.target)
  if result.target == "android":
    if headlessOnly: fail("Android does not support headless execution")
    if backend.len > 0 and result.backend != backendNative: fail("Android requires the native backend")
    result.backend = backendNative
proc validateHost*(selection: BuildSelection) =
  if selection.target == "android":
    if selection.backend != backendNative or selection.headlessOnly: fail("invalid Android build selection")
    return
  if selection.target != hostTarget(): fail("cross compilation is not configured; build on target " & selection.target)
  if not selection.headlessOnly:
    if selection.target != "windows":
      fail("native GUI backend not implemented for " & selection.target & "; use --headless or --check")
    when not (defined(windows) and defined(amd64)):
      fail("native Windows GUI requires a Windows x64 build host")
