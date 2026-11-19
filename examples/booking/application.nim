import std/strutils
import leaf
import ./booking_controls

component Booking:
  state:
    name = ""
    day = today()
    guests = 1
    confirmation = ""
  view:
    column:
      padding: 24
      gap: 12
      text "预约"
      textField name, key = "name", placeholder = "姓名"
      datePicker day, earliest = today()
      stepper guests, maximum = 6
      button "确认", key = "confirm", disabled = name.strip.len == 0:
        confirmation = name.strip & " · " & $day & " · " & $guests & " 位"
      text confirmation:
        key: "confirmation"

proc bookingApp*(): Application =
  app(Booking, title = "Leaf · 预约", width = 460, height = 360)
