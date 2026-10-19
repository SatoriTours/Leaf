## Independent vendored archive readers are test-only package imports.
import std/os
switch("path", currentSourcePath().parentDir.parentDir.parentDir / "src/leaf/vendor/zippy")
# Test-only fixtures may construct the legacy render-shaped Application; the
# fixture path is excluded from production builds.
