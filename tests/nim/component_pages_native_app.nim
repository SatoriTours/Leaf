## Native harness fixture for the managed component pages example. The harness
## drives navigation, editing, reset, an unknown address and close through the
## stable keys defined in examples/component_pages.nim.
import std/os
import leaf
import ../../examples/component_pages

when isMainModule:
  quit(run(pagesApplication(getEnv("LEAF_TEST_TITLE", "Leaf component pages"))))
