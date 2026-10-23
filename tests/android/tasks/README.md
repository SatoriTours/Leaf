# Retained TaskService Android device fixture

This separate APK uses the real managed Runtime, Android Views backend and existing TaskService. It does not modify the accepted Views fixture or product protocols.

Build its Nim library with threads/ORC and the existing NDK/JNI sources; evidence commands and hashes live under `target/verification/native-five-platform/s2/tasks/`. Gradle runs offline with the already installed SDK. Test package: `dev.leaf.testtasks`.

1. Launch and wait for `phase=worker_started` in `files/tasks-result.txt`.
2. Send HOME. Real Activity.onPause pauses the host, then the fixture releases work. `phase=background` asserts callbacks and accepted/native values remain pending. `worker_reached_return` alone does not attest the completion queue publication.
3. Bring the same Activity to the foreground. It pauses again before the queued display frame and requests recreation. The replacement receives the result on the UI thread, while the deliberately pinned old TextView stays pending; factory/initialization counts remain one.
4. Wait for `phase=cancel_wait`, then deliver the fixture close Intent with `--activity-single-top --ez close true`. The second blocking TaskWork must observe cancellation, with no further result/error callback and exactly one component disposal.

All observation waits use a five-second deadline and main-Looper Handler messages in this fixture. They are not a production scheduler. The fixture deliberately pins one old TextView until the new one receives its result, so it cannot prove Activity/View GC freedom. There is no editor/IME, SQLite, process-death persistence, allocation/performance, API26 runtime, arm64 runtime or 16KiB runtime assertion.
