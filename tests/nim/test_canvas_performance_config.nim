import std/unittest
import ../../benchmarks/canvas_config

suite "bounded standalone Canvas producer arguments":
  test "default protocol freezes five second warmup and thirty second measurement":
    let config = parseCanvasArgs(@["--output","report","--environment","public.json"])
    check config.objects == 1000
    check config.loadName == "properties"
    check config.warmupMs == 5000
    check config.sampleMs == 30000
    check config.formal
    check config.capacity >= 1800 and config.capacity < 2000
  test "short duration is explicitly smoke and stays bounded":
    let config = parseCanvasArgs(@["--output","report","--environment","public.json",
      "--warmup-ms","0","--sample-ms","100","--objects","10000","--load","geometry"])
    check not config.formal
    check config.capacity < 20
  test "unknown duplicate partial and excessive parameters fail closed":
    for tail in [@["--objects","16"],@["--load","automatic"],@["--sample-ms","99"],
        @["--warmup-ms","60001"],@["--sample-ms","120001"],@["--sample-ms","nan"],
        @["--objects","100","--objects","1000"],@["--install","yes"],@["--load"]]:
      expect ValueError: discard parseCanvasArgs(@["--output","report","--environment","public.json"] & tail)
    for args in [newSeq[string](),@["--output","report"],@["--environment","public.json"]]:
      expect ValueError: discard parseCanvasArgs(args)
