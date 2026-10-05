## Independent vendored archive readers are test-only package imports.
import std/os
switch("path", currentSourcePath().parentDir.parentDir.parentDir / "src/leaf/vendor/zippy")
