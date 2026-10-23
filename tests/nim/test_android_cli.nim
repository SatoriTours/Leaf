import std/unittest
import leaf/[cli_options, core]
suite "Android CLI options":
  test "build pack doctor and run accept an explicit Android target":
    check parseCli(@["build","--target","android"]).target=="android"
    check parseCli(@["pack","--target","android","--binary","app.apk"]).binary=="app.apk"
    check parseCli(@["doctor","--target","android","--json"]).jsonOutput
    check parseCli(@["run","--target","android","--device","emulator-5560"]).device=="emulator-5560"
  test "device selection and desktop modes cannot be mixed":
    for args in [@["run","--device","x"],@["build","--target","android","--device","x"],
        @["doctor","--target","android","--device","x"],@["run","--target","android","--device",""],
        @["run","--target","android","--device","a","--device","b"],
        @["run","--target","android","--backend","gpui"],@["build","--target","android","--headless"],
        @["--watch","--target","android"]]:
      expect UiError:discard parseCli(args)
