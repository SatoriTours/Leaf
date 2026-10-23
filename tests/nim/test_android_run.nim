import std/unittest
import leaf/[android_run, core]
suite "Android device selection":
  test "only a single ready device is selected implicitly":
    check selectAndroidDevice("List of devices attached\nemulator-5560\tdevice product:sample\n","")=="emulator-5560"
    expect UiError:discard selectAndroidDevice("List of devices attached\n","")
    expect UiError:discard selectAndroidDevice("a\tdevice\nb\tdevice\n","")
    expect UiError:discard selectAndroidDevice("a\tunauthorized\n","")
  test "an explicit serial must identify a ready device without changing other devices":
    check selectAndroidDevice("a\tdevice\nb\tdevice\n","b")=="b"
    expect UiError:discard selectAndroidDevice("a\tdevice\nb\toffline\n","b")
    expect UiError:discard selectAndroidDevice("a\tdevice\n","missing")
    expect UiError:discard selectAndroidDevice("a\tdevice\n","a\n")
