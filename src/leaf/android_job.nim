## Finite Android build stages share the existing owned subprocess implementation.
import std/[os, strutils, monotimes, times]
import ./[process_io, core]

type
  AndroidStep* = object
    executable*, workingDirectory*:string
    arguments*:seq[string]
    timeoutMilliseconds*:int
    accept*:proc(output:string) {.closure.}
  AndroidJob* = ref object
    code*:int
    output*:string
    binary*:string
    directory*:string
    steps:seq[AndroidStep]
    next:int
    child:ManagedProcess
    deadline:MonoTime
    done:bool

proc append(job:AndroidJob,text:string) =
  job.output.add(text)
  if job.output.len>MaxProcessOutput:job.output=job.output[^MaxProcessOutput..^1]

proc saveLog(job:AndroidJob,output:string) =
  if job.directory.len>0:
    let logs=job.directory / "logs"
    createDir(logs)
    writeFile(logs / ($job.next & ".log"),output)

proc launch(job:AndroidJob) =
  let step=job.steps[job.next]
  if step.timeoutMilliseconds<=0:fail("Android stage requires a positive timeout")
  job.child=startManaged(step.executable,step.arguments,step.workingDirectory)
  job.deadline=getMonoTime()+initDuration(milliseconds=step.timeoutMilliseconds)

proc startAndroidSteps*(steps:seq[AndroidStep],binary="",directory=""):AndroidJob =
  result=AndroidJob(code: -1,steps:steps,binary:binary,directory:directory)
  if steps.len==0:fail("Android build requires at least one stage")
  result.launch()

proc close*(job:AndroidJob) =
  if job==nil or job.done:return
  if job.child!=nil:
    discard job.child.drain()
    job.child.close()
    let output=job.child.output
    job.child=nil
    job.append(output)
    try:job.saveLog(output)
    except CatchableError as error:job.append("\nUnable to save cancelled stage log: " & error.msg)
  job.code=130;job.done=true

proc pollAndroid*(job:AndroidJob):bool =
  if job.done:return true
  try:
    if not job.child.poll():
      if getMonoTime()>job.deadline:
        job.child.close()
        let output=job.child.output
        job.child=nil
        job.append(output)
        job.saveLog(output)
        job.append("\nAndroid stage timed out: " & job.steps[job.next].executable)
        job.code=1;job.done=true
      return job.done
    let code=job.child.code
    let output=job.child.output
    job.child.close();job.child=nil
    job.append(output)
    job.saveLog(output)
    if code!=0:
      job.code=code;job.done=true;return true
    let accepted=job.steps[job.next].accept
    if accepted!=nil:accepted(output)
    inc job.next
    if job.next==job.steps.len:
      job.code=0;job.done=true;return true
    job.launch()
  except CatchableError as error:
    if job.child!=nil:job.child.close();job.child=nil
    job.append("\nAndroid stage failed: " & error.msg)
    job.code=1;job.done=true
  job.done
