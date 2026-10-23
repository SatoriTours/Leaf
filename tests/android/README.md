# Android JNI boundary fixture

This APK exercises the real `native/android` bridge and `leaf/native_ffi` byte
ownership API. It does not implement the Android Leaf Backend, managed UI,
lifecycle retention, input/IME, database or resource services.

From the repository root, use Nim 2.2.6, JDK 21, Gradle 9.1.0, SDK/build-tools
36, and NDK 28.2.13676358. The Gradle fixture uses AGP 9.0.1 with built-in Kotlin
and a KGP 2.3.20 classpath override. No `kotlin-android` plugin is applied.

Set `LEAF_NIM`, `LEAF_NDK`, `JAVA_HOME`, and `ANDROID_HOME` to installed tools.
Compile the test shared library with the NDK compiler, not the host clang:

```sh
LEAF_CC="$LEAF_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android26-clang"
"$LEAF_NIM" c --cc:clang --os:android --cpu:amd64 --app:lib --noMain:on \
  --threads:on --mm:orc -d:release --skipParentCfg:on --skipUserCfg:on \
  --path:src --clang.exe:"$LEAF_CC" --clang.linkerexe:"$LEAF_CC" \
  --passC:-Iinclude --passL:-Wl,-z,max-page-size=16384 \
  --compile:native/android/src/main/c/leaf_jni.c \
  --compile:tests/android/boundary_probe.c \
  --nimcache:target/verification/native-five-platform/s2/utf8/nimcache-x86_64 \
  --out:target/verification/native-five-platform/s2/utf8/jniLibs/x86_64/libleaf_android_boundary.so \
  tests/android/boundary_probe.nim
gradle --project-dir tests/android --offline --no-daemon --max-workers=2 \
  -Dorg.gradle.jvmargs=-Xmx1024m assembleDebug
```

The output is under `target/verification/native-five-platform/s2/utf8/gradle-build/outputs/apk/debug`.
Install only on an authorized task device, selected explicitly by serial. Start
`dev.leaf.testbridge/.MainActivity`; the app writes `files/boundary-result.txt`
in its private directory. Clear the previous result before rerunning and verify
the installed APK hash and current launch, not just a stale result file.

`--noMain:on` is mandatory: JNI_OnLoad does not initialize Nim. The first
successful `NativeBridge.initialize` must run on the Android main thread.
This library owns Nim initialization; do not combine independent NimMain owners
or initialize the same library through another entry point. No unload/reset
contract is provided. The fixture's marker verifies one initialization.

Pure tests: run `tests/nim/test_native_utf8.nim` with `--path:src --threads:on
--mm:orc`. To check the C layout/calling convention, build `src/leaf/native_ffi.nim`
as a shared library with `--noMain:on`, then link `test_native_utf8.c` against it
using `-Iinclude`. The C harness explicitly calls NimMain once.

JNI rules follow [Android JNI tips](https://developer.android.com/ndk/guides/jni-tips).
The custom Kotlin source directories follow the
[AGP built-in Kotlin migration guide](https://developer.android.com/build/migrate-to-built-in-kotlin).
