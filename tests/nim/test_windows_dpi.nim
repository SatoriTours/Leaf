import std/unittest
when defined(windows): import std/[os, osproc]
import leaf/windows_dpi

# Catches accidental setter use in a host context and false-success reporting.
suite "Windows DPI decisions":
  test "preserves already chosen host contexts":
    for mode in ["per_monitor_v2", "system", "per_monitor", "unknown"]:
      var calls = 0
      let selected = mode
      let r = ensureDpi(DpiApi(current: proc(): string = selected,
        setPerMonitorV2: proc(): tuple[success: bool, errorCode: int] =
          inc calls
          (true, 0)))
      check calls == 0
      check r.awareness == mode
      check r.status == (if mode == "per_monitor_v2": "already_set"
        elif mode == "unknown": "failed" else: "host_context")
  test "requeries successful initialization":
    var mode = "unaware"
    let r = ensureDpi(DpiApi(current: proc(): string = mode,
      setPerMonitorV2: proc(): tuple[success: bool, errorCode: int] =
        mode = "per_monitor_v2"
        (true, 0)))
    check r.status == "initialized"
    check r.awareness == "per_monitor_v2"
  test "failed setter only succeeds if requery proves PMv2":
    for after in ["per_monitor_v2", "unaware", "unknown", "system", "per_monitor"]:
      var mode = "unaware"
      let selected = after
      let r = ensureDpi(DpiApi(current: proc(): string = mode,
        setPerMonitorV2: proc(): tuple[success: bool, errorCode: int] =
          mode = selected
          (false, 5)))
      check r.errorCode == 5
      check r.awareness == after
      check r.status == (if after == "per_monitor_v2": "already_set" else: "failed")
  test "successful setter without PMv2 confirmation fails":
    let r = ensureDpi(DpiApi(current: proc(): string = "unaware",
      setPerMonitorV2: proc(): tuple[success: bool, errorCode: int] = (true, 0)))
    check r.status == "failed"
  when not defined(windows):
    test "non Windows backend is inert":
      check initializeWindowsDpi().status == "not_applicable"
  when defined(windows):
    test "real process contexts are isolated in probe subprocesses":
      let nim = getEnv("NIM", findExe("nim"))
      let probe = getTempDir() / "leaf-dpi-probe.exe"
      let compiled = execCmdEx(quoteShell(nim) & " c --path:src --out:" & quoteShell(probe) & " tests/nim/windows_dpi_probe.nim")
      check compiled.exitCode == 0
      for mode in ["default", "per_monitor_v2", "system", "per_monitor", "headless"]:
        let child = execCmdEx(quoteShell(probe) & " " & mode)
        checkpoint child.output
        check child.exitCode == 0
