## Environment inspection never initializes a display or requires a project.
import std/[os, json, monotimes, times, options]
import ./android_tools
import ./[build, gpui_api, process_io, sdk, targets]

proc version(exe: string, args: seq[string]): JsonNode =
  if exe.len == 0 or not fileExists(exe): return newJNull()
  try:
    beginInterruptHandling()
    defer: endInterruptHandling()
    let process = startManaged(exe, args, getCurrentDir())
    defer: process.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not process.poll():
      if wasInterrupted(): raise newException(ProcessInterruptedError, "doctor interrupted")
      if getMonoTime() > deadline: return %"version command timed out"
      sleep(10)
    result = %process.output.diagnosticText()
  except ProcessInterruptedError: raise
  except CatchableError as error: result = %error.msg

proc doctorReport*(selection: Option[BuildSelection] = none(BuildSelection)): JsonNode =
  var nim: string
  try: nim = compiler()
  except CatchableError: discard
  let selected = selection.get(resolveBuild(backendGpui))
  if selected.target == "android":
    result=androidDoctorReport()
    result["nim"] = %nim
    result["nim_version"] = version(nim,@["--version"])
    if nim.len==0:result["host_available"] = %false
    return
  if selected.backend == backendNative or selected.headlessOnly:
    let bundled = sdkGcc()
    let gcc = if bundled.len > 0: bundled else: findExe("gcc")
    let windres = if gcc.len > 0: gcc.parentDir / "windres".addFileExt(ExeExt) else: ""
    result = %*{"implementation": "nim", "nim": nim, "cc": gcc,
      "platform": hostTarget(), "target": selected.target, "architecture": hostCPU,
      "desktop_backend": (if selected.headlessOnly: "headless" else: "native"),
      "tools": {"nim": version(nim, @["--version"]), "cc": version(gcc, @["--version"]),
        "windres": version(windres, @["--version"])}}
    try:
      selected.validateHost()
      result["host_available"] = %true
    except CatchableError as error:
      result["host_available"] = %false
      result["host_error"] = %error.msg
    return
  let bundledCc = sdkGcc()
  let cc = if bundledCc.len > 0: bundledCc else: findExe("cc")
  result = %*{"implementation": "nim", "nim": nim,
    "cc": cc, "platform": hostOS, "architecture": hostCPU,
    "desktop_backend": "gpui", "gpui_kit": "0.7.0",
    "tools": {"nim": version(nim, @["--version"]),
      "cc": version(cc, @["--version"]),
      "cargo": version(findExe("cargo", followSymlinks = false), @["--version"]),
      "rustc": version(findExe("rustc", followSymlinks = false), @["--version"])}}
  when defined(linux): result["graphical_session"] = %(getEnv("DISPLAY").len > 0 or getEnv("WAYLAND_DISPLAY").len > 0)
  else: result["graphical_session"] = newJNull()
  try: result["library"] = %libraryPath()
  except CatchableError as error: result["library_error"] = %error.msg
  try:
    let api = loadGpui()
    result["gpui"] = %*{"available": true, "abi": 2}
  except CatchableError as error: result["gpui"] = %*{"available": false, "error": error.msg}
