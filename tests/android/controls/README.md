# Android remaining native controls fixture

This fixture supplements the accepted input slice with native CheckBox, Switch,
determinate/indeterminate ProgressBar, TextView tag and platform separator.
It retains one managed Nim Runtime and routes checked facts through the same
owner/session/mount/revision/sequence/binding validation as other events.

Build outputs belong under `target/verification/native-five-platform/s2/controls/`.
Use the same offline Gradle/NDK toolchain as the input fixture. ABI3 enables
remaining controls explicitly; ABI1 and ABI2 keep their previous capabilities.

The Activity records initial types and progress, then permits external real
touches. Intent flags `inspect`, `model`, `pause`, `close` are posted after resume
and must be sent with `--activity-single-top`. The `pause` case changes the
native checked fact while delivery is inactive and checks one foreground result;
it is a fixture-driven lifecycle check, separate from an actual HOME test.

No list, navigation, API26 runtime, arm64/16KiB runtime, allocation/GC, full
Android, release packaging or third-party IME completion is claimed here.
