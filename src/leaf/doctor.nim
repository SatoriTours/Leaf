## Environment inspection never initializes a display or requires a project.
import std/[os, json, monotimes, times]
import ./[build, gpui_api, process_io]

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

proc doctorReport*(): JsonNode =
  result = %*{"implementation": "nim", "nim": getEnv("NIM", findExe("nim")),
    "cc": findExe("cc"), "platform": hostOS, "architecture": hostCPU,
    "desktop_backend": "gpui", "gpui_kit": "0.7.0",
    "tools": {"nim": version(getEnv("NIM", findExe("nim")), @["--version"]),
      "cc": version(findExe("cc"), @["--version"]),
      "cargo": version(findExe("cargo", followSymlinks = false), @["--version"]),
      "rustc": version(findExe("rustc", followSymlinks = false), @["--version"])}}
  when defined(linux): result["graphical_session"] = %(getEnv("DISPLAY").len > 0 or getEnv("WAYLAND_DISPLAY").len > 0)
  else: result["graphical_session"] = newJNull()
  try: result["library"] = %libraryPath()
  except CatchableError as error: result["library_error"] = %error.msg
  try:
    let api = loadGpui()
    result["gpui"] = %*{"available": true, "abi": api.abi()}
  except CatchableError as error: result["gpui"] = %*{"available": false, "error": error.msg}
