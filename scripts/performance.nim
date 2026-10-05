## Compile the supervisor independently; it builds selected Release harnesses.
import std/[os, json]
import leaf/performance_runner

proc main(): int =
  try:
    let parsed = parsePerformanceArgs(commandLineParams())
    if parsed.help:
      stdout.write(PerformanceHelp)
      return 0
    let report = runPerformance(parsed.config)
    stdout.writeLine("Performance report: " & report["run_directory"].getStr)
  except CatchableError as error:
    stderr.writeLine("performance: " & error.msg)
    result = performanceFailureCode(error)

when isMainModule: performanceExit(main())
