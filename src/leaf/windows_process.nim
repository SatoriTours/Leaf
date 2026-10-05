## Windows subprocess ownership: assign a suspended child before it can fork.
when defined(windows):
  import std/[os, winlean, strtabs, algorithm, strutils]
  type
    JobBasic {.importc: "JOBOBJECT_BASIC_LIMIT_INFORMATION", header: "<windows.h>", bycopy.} = object
      LimitFlags: uint32
    JobLimits {.importc: "JOBOBJECT_EXTENDED_LIMIT_INFORMATION", header: "<windows.h>", bycopy.} = object
      BasicLimitInformation: JobBasic
    WindowsProcess* = ref object
      handle, job: Handle
      outputHandle*: Handle
      pid*: int
  proc createJob(attributes, name: pointer): Handle {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
  proc setJobInfo(job: Handle, kind: cint, info: pointer, size: uint32): WINBOOL {.stdcall, dynlib: "kernel32", importc: "SetInformationJobObject".}
  proc assignJob(job, process: Handle): WINBOOL {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}

  proc release(handle: var Handle) =
    if handle != 0:
      discard closeHandle(handle)
      handle = 0

  proc peekExit*(p: WindowsProcess): int =
    if waitForSingleObject(p.handle, 0) == WAIT_TIMEOUT: return -1
    var code: int32
    if getExitCodeProcess(p.handle, code) == 0: raiseOSError(osLastError())
    int(code)

  proc close*(p: WindowsProcess) =
    if p == nil: return
    # KILL_ON_JOB_CLOSE covers descendants even when the original leader exited.
    p.job.release()
    if p.handle != 0:
      if waitForSingleObject(p.handle, 3000) == WAIT_TIMEOUT:
        discard terminateProcess(p.handle, 1)
        discard waitForSingleObject(p.handle, 3000)
      p.handle.release()
    p.outputHandle.release()

  proc startWindows*(exe: string, args: seq[string], directory: string,
                     env: StringTableRef, parentStreams: bool): WindowsProcess =
    result = WindowsProcess()
    var inputRead, inputWrite, outputWrite: Handle
    var info: PROCESS_INFORMATION
    var startup: STARTUPINFO
    startup.cb = int32(sizeof(startup))
    startup.dwFlags = STARTF_USESTDHANDLES
    try:
      result.job = createJob(nil, nil)
      if result.job == 0: raiseOSError(osLastError())
      var limits: JobLimits
      # The SDK header provides the full ABI layout, including reserved fields.
      zeroMem(addr limits, sizeof(limits))
      limits.BasicLimitInformation.LimitFlags = 0x2000
      if setJobInfo(result.job, 9, addr limits, uint32(sizeof(limits))) == 0: raiseOSError(osLastError())
      if parentStreams:
        startup.hStdInput = getStdHandle(STD_INPUT_HANDLE)
        startup.hStdOutput = getStdHandle(STD_OUTPUT_HANDLE)
        startup.hStdError = getStdHandle(STD_ERROR_HANDLE)
      else:
        var attributes = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 1)
        if createPipe(inputRead, inputWrite, attributes, 0) == 0: raiseOSError(osLastError())
        if createPipe(result.outputHandle, outputWrite, attributes, 0) == 0: raiseOSError(osLastError())
        if setHandleInformation(inputWrite, HANDLE_FLAG_INHERIT, 0) == 0 or
            setHandleInformation(result.outputHandle, HANDLE_FLAG_INHERIT, 0) == 0: raiseOSError(osLastError())
        startup.hStdInput = inputRead
        startup.hStdOutput = outputWrite
        startup.hStdError = outputWrite
      var line = quoteShellWindows(exe)
      for arg in args: line.add(" " & quoteShellWindows(arg))
      let commandLine = newWideCString(line)
      let workingDirectory = newWideCString(directory)
      let application = newWideCString(exe)
      var environment: string
      if env != nil:
        var keys: seq[string]
        for key in env.keys: keys.add(key)
        keys.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))
        for key in keys: environment.add(key & "=" & env[key] & '\0')
        environment.add('\0')
      let environmentBlock = if env == nil: newWideCString(cstring(nil)) else: newWideCString(environment)
      let flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT or CREATE_NO_WINDOW or 4 # CREATE_SUSPENDED
      if createProcessW(application, commandLine, nil, nil, 1, flags,
          environmentBlock, workingDirectory, startup, info) == 0: raiseOSError(osLastError())
      result.handle = info.hProcess
      result.pid = int(info.dwProcessId)
      if assignJob(result.job, info.hProcess) == 0: raiseOSError(osLastError())
      if resumeThread(info.hThread) == -1: raiseOSError(osLastError())
    except:
      if info.hProcess != 0: discard terminateProcess(info.hProcess, 1)
      result.close()
      raise
    finally:
      inputRead.release()
      inputWrite.release()
      outputWrite.release()
      info.hThread.release()
