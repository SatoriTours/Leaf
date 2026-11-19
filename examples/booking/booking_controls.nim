## Reusable library; consumers own the guest count and pass the state name.
import leaf

component Stepper, exported:
  model value: int
  prop minimum: int = 1
  prop maximum: int = 8
  view:
    row:
      gap: 8
      button "−", key = "minus", disabled = value <= minimum:
        value -= 1
      text value:
        key: "guests"
      button "+", key = "plus", disabled = value >= maximum:
        value += 1
