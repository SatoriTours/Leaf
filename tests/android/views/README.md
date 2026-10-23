# Android Views vertical fixture

Uses the product Android Backend, LAV1 incremental C/JNI bridge, retained
`LeafRuntime`, and `LeafActivity`. Business State and button callbacks are Nim
managed components in `views_probe.nim`. No Compose, WebView, GPUI or JSON tree.

The initial backend declares **column, row, text, button** only. EditText/IME,
checkbox/switch/progress/list/navigation/assets/SQLite and CLI generation remain
unimplemented and must not be claimed from this counter fixture. Unsupported
required kinds/layouts fail the existing capability gate. Decorations follow
compatible/strict diagnostics. This is not a complete Android Backend.

Use Nim 2.2.6/ORC/threads, JDK21, Gradle9.1.0, AGP9.0.1/built-in Kotlin2.3.20,
SDK/build-tools36, NDK28.2.13676358; API26 minimum for this fixture. Build the Nim
module as `--app:lib --noMain:on --os:android`, link `leaf_jni.c`,
`leaf_android_jni.c`, `views_probe.c`, include `include` and
`native/android/src/main/c`, use NDK target clang and
`--passL:-Wl,-z,max-page-size=16384`. Output x86_64 library to
`target/verification/native-five-platform/s2/views/jniLibs/x86_64/libleaf_android_views.so`.
The retained owner factory is registered by NimMain; JNI_OnLoad never calls it.
See `ndk-x86-final-result.json` under that evidence directory for the exact
executed argv. arm64 is compile-only unless an actual device is verified.

From the repository root with the same installed tools:

```
gradle --project-dir tests/android/views --offline --no-daemon --max-workers=2 \
  -Dorg.gradle.jvmargs=-Xmx1024m assembleDebug
```

The fixture verifies stable native views on an update, real main-thread JNI,
foreign-thread rejection, pause, Java apply failure + accepted replay preserving
the original exception, stale view rejection, and Activity recreation retaining
the same Runtime/State. It writes `files/views-result.txt`. An actual touch can
then increment 2→3 through the main-Looper frame callback. Deliver a single-top
Intent with `--ez inspect true` to assert that result, `--ez rotate true` for an
actual landscape configuration change, or `--ez close true` for terminal cleanup.
Use an explicitly authorized adb serial. `performClick` assertions and actual
adb touch results are recorded separately; a screenshot is visual evidence only
for the displayed counter. No editor/IME/list or performance claim follows.

Host tests: `test_android_backend.nim`, `test_android_ffi.nim` with threads/ORC;
`test_android_owner.c` links the real Nim fixture library and validates C layout
and callbacks. Callback data are borrowed for one call. Prepare may allocate;
accept only swaps prepared metadata, with retired state pinned to the next
ordinary prepare. No allocation fence has been collected for this slice.
