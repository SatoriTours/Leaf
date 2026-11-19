import leaf
import ./declarative_contract
export declarative_contract

implement ImportedControl:
  view:
    button "shared import", key = "imported":
      count += increment

implement ImportedControl, platform = headless:
  view:
    button "headless import", key = "imported":
      count += increment * 2

implement ImportedControl, platform = ios:
  view:
    iosOnlyImplementationNotAvailableOnOtherTargets()
