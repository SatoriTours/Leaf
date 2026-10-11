import std/[json,os]
import ../src/leaf/performance_report
when isMainModule:
  try:
    if paramCount()==0:raise newException(ValueError,"provide reports for static 100/1000/5000")
    let combined=parseFile(paramStr(1))
    for i in 2..paramCount():
      let next=parseFile(paramStr(i))
      if next["metadata"]!=combined["metadata"]:raise newException(ValueError,"benchmark metadata differs")
      for c in next["cases"]:combined["cases"].add(c)
    let errors=verifyComponentReport(combined)
    for error in errors:stderr.writeLine(error)
    if errors.len>0:quit(1)
    echo "Component structural counters passed"
  except CatchableError as error:stderr.writeLine(error.msg);quit(1)
