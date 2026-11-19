import leaf
import ./booking/booking_controls

component StepperDemo:
  state:
    guests = 1
  view:
    column:
      padding: 24
      gap: 8
      text "人数"
      stepper guests, maximum = 6
      text "共 " & $guests & " 位"

when isMainModule:
  quit(run(app(StepperDemo, title = "Leaf · Stepper", width = 320, height = 200)))
