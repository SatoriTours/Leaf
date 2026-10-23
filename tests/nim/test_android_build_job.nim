import std/[os, unittest, strutils, monotimes, times, tempfiles]
import leaf/android_job
if paramCount()>0 and paramStr(1)=="--child":
  case paramStr(2)
  of "ok":echo "child passed";quit(0)
  of "fail":echo "child failed";quit(7)
  of "wait":echo "child started";stdout.flushFile();sleep(2000);quit(0)
  of "flood":stdout.write(repeat("x",2_000_000));quit(0)
  else:quit(9)

proc step(mode:string):AndroidStep =
  AndroidStep(executable:getAppFilename(),arguments: @["--child",mode],
    workingDirectory:getCurrentDir(),timeoutMilliseconds:5000)
proc finish(job:AndroidJob) =
  let until=getMonoTime()+initDuration(seconds=10)
  while not job.pollAndroid():
    doAssert getMonoTime()<until
    sleep(2)

suite "Android finite subprocess stages":
  test "one completed stage advances once and preserves bounded observations":
    var accepted=0
    var first=step("ok");first.accept=proc(output:string)=
      doAssert "child passed" in output
      inc accepted
    let job=startAndroidSteps(@[first,first])
    defer:job.close()
    finish(job)
    check job.code==0
    check accepted==2
    check job.pollAndroid()
    check accepted==2

  test "failed child never starts a later stage or commits completion":
    var accepted=0
    var later=step("ok");later.accept=proc(output:string)=inc accepted
    let job=startAndroidSteps(@[step("fail"),later])
    defer:job.close()
    finish(job)
    check job.code==7
    check accepted==0
    check "child failed" in job.output

  test "timeout and explicit cancellation stop before acceptance":
    let logs=createTempDir("leaf-android-timeout-", "")
    defer:removeDir(logs)
    var command=step("wait");command.timeoutMilliseconds=100
    let timed=startAndroidSteps(@[command],directory=logs)
    defer:timed.close()
    finish(timed)
    check timed.code!=0
    check "timed out" in timed.output
    check "child started" in readFile(logs / "logs/0.log")
    let cancelLogs=createTempDir("leaf-android-cancel-", "")
    defer:removeDir(cancelLogs)
    let cancelled=startAndroidSteps(@[step("wait")],directory=cancelLogs)
    sleep(50)
    discard cancelled.pollAndroid()
    cancelled.close()
    check cancelled.pollAndroid()
    check cancelled.code==130
    check "child started" in readFile(cancelLogs / "logs/0.log")

  test "a flooded child cannot grow the retained job log without bound":
    let job=startAndroidSteps(@[step("flood")])
    defer:job.close()
    finish(job)
    check job.code==0
    check job.output.len<=1_048_576
