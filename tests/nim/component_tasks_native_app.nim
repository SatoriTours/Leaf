## Stable task UI fixture for the real X11/native harness.
import std/os
import leaf
import ../../examples/component_tasks
when isMainModule:
  quit(run(tasksApplication(getEnv("LEAF_TEST_TITLE", "Leaf component tasks"))))
