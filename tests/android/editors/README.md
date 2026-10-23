# Android controlled editors probe

This fixture exercises a retained managed Nim component through the exported
Android owner C ABI and real Android EditText/InputConnection. The Kotlin probe
owns no business value: accepted values, handlers, composition conflicts and
reset consumption remain in Nim.

Use Nim 2.2.6 with threads/ORC. `editors_probe.nim` can be compiled as a Linux
shared library and linked to `test_android_editors.c` (`cc -std=c11 -Wall
-Wextra -Werror -Iinclude`, link/rpath to that library). This is a real C caller;
its platform commands are stubs, so it does not prove Android Views behaviour.

The separate Gradle project uses cached AGP 9.0.1/Kotlin 2.3.20, SDK 36, minSdk
26, and product Kotlin sources. Build the NDK fixture library with the two
product JNI C files and `editors_probe.c` into the evidence directory's
`jniLibs/<abi>/libleaf_android_editors.so`, then run `assembleDebug` offline.
All generated output belongs under
`target/verification/native-five-platform/s2/editors/`, not this source tree.

The Activity probe covers UTF-8 Chinese/emoji, controlled rejection without a
render, selection preservation, model updates during composing text,
finishComposingText without a text change, explicit reset, stale input
connections (including API33 overloads), pause/resume end facts and submit.
InputConnection calls are programmatic calls to the actual native editor;
they do not attest a particular third-party IME. External keyboard input is a
separate adb/UI check. Intent actions `inspect`, `noop`, `keyboard`, `close`
use `--activity-single-top` and execute after Activity resumes.

ABI1 callbacks retain the four basic kinds/LAV1. ABI2 additionally supports
input/reset with LAV2 editor writes and command tags 8..11. Strings are strict,
explicit-length scalar UTF-8 with the existing 1 MiB limit. Neither this probe
nor the adapter claims zero allocation, GC/leak safety, full Android support,
API26 runtime compatibility, arm64 runtime coverage, or 16 KiB runtime coverage.
