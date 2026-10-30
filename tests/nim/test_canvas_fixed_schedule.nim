import std/unittest
import ../../benchmarks/canvas_fixed_schedule

suite "fixed Canvas diagnostic schedule":
  test "elapsed time cannot change the phase sequence or frame budget":
    let plan = fixedSchedule(warmupFrames=2, sampleFrames=4, cycleFrames=4)
    check plan.phase(0) == 0.0
    check plan.phase(1) == 0.25
    check plan.phase(3) == 0.75
    check plan.phase(4) == 0.0
    check plan.warmingUp(1)
    check not plan.warmingUp(2)
    check not plan.complete(3)
    check plan.complete(4)
    expect ValueError: discard plan.phase(-1)

  test "priming and warmup never suppress the first sampled draw":
    for warmup in [0,1,4,5,60]:
      let plan=fixedSchedule(warmupFrames=warmup,sampleFrames=8,cycleFrames=4)
      var previous=plan.initialPhase
      for index in 0..<warmup:
        let next=plan.warmupPhase(index)
        check next!=previous
        previous=next
      check plan.phase(0)!=previous

  test "bounds reject empty, unbounded and overflowing schedules":
    for warmup in [-1, 601]:
      expect ValueError: discard fixedSchedule(warmupFrames=warmup)
    for count in [0, 1201, high(int)]:
      expect ValueError: discard fixedSchedule(sampleFrames=count)
    for cycle in [1, 1201]:
      expect ValueError: discard fixedSchedule(cycleFrames=cycle)

  test "arguments are diagnostic only, bounded and unambiguous":
    let config = parseFixedCanvasArgs(@["--output","out","--environment","env.json",
      "--frames","240","--warmup-frames","60","--cycle-frames","120","--objects","10000","--load","properties"])
    check config.schedule.sampleFrames == 240
    check config.schedule.warmupFrames == 60
    check config.schedule.cycleFrames == 120
    check config.producer.objects == 10000
    check config.producer.capacity == 240
    check not config.producer.formal
    for extra in [@["--sample-ms","30000"], @["--frames","1","--frames","2"],
        @["--frames"], @["--frames","0"], @["--load","typo"]]:
      expect ValueError:
        discard parseFixedCanvasArgs(@["--output","out","--environment","env.json"] & extra)

  test "schedule fingerprint binds order, not just the phase sum":
    let plan = fixedSchedule(sampleFrames=8,cycleFrames=4)
    check plan.fingerprint == fixedSchedule(sampleFrames=8,cycleFrames=4).fingerprint
    check plan.fingerprint != fixedSchedule(sampleFrames=8,cycleFrames=8).fingerprint
    check plan.fingerprint != fixedSchedule(sampleFrames=4,cycleFrames=4).fingerprint
