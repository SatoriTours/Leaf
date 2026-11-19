## Calendar dates and a portable picker using Leaf's existing native controls.
import std/[options, strutils, times]
import ./[component_dsl, widgets]

type Date* = object
  year, month, day: int

proc date*(year, month, day: int): Date =
  if year notin 1..9999 or month notin 1..12 or
      day notin 1..getDaysInMonth(Month(month), year):
    raise newException(ValueError, "invalid calendar date")
  Date(year: year, month: month, day: day)

proc today*(): Date =
  let local = now()
  date(local.year, ord(local.month), local.monthday)

proc `<`*(a, b: Date): bool = (a.year, a.month, a.day) < (b.year, b.month, b.day)
proc `<=`*(a, b: Date): bool = not (b < a)
proc `$`*(value: Date): string =
  align($value.year, 4, '0') & "-" & align($value.month, 2, '0') & "-" & align($value.day, 2, '0')

proc eligible(raw: string, earliest, latest: Date): Option[Date] =
  if raw.len != 10 or raw[4] != '-' or raw[7] != '-': return
  for i, c in raw:
    if i notin [4, 7] and c notin Digits: return
  try:
    let candidate = date(parseInt(raw[0..3]), parseInt(raw[5..6]), parseInt(raw[8..9]))
    if earliest <= candidate and candidate <= latest: return some(candidate)
  except ValueError:
    discard

proc canStep(candidate: Option[Date], earliest, latest: Date, direction: int): bool =
  candidate.isSome and
    (if direction < 0: earliest < candidate.get else: candidate.get < latest)

proc stepDate(raw: string, earliest, latest: Date, direction: int): string =
  let candidate = eligible(raw, earliest, latest)
  if not canStep(candidate, earliest, latest, direction): return raw
  let current = candidate.get
  let next = dateTime(current.year, Month(current.month), current.day, zone = utc()) +
    initDuration(days = direction)
  $date(next.year, ord(next.month), next.monthday)

contract DatePicker, exported:
  model day: Date
  prop earliest: Date = date(1, 1, 1)
  prop latest: Date = date(9999, 12, 31)
  prop id: string = "date"

implement DatePicker:
  state:
    editing = false
    draft = ""
  view:
    column:
      if editing:
        input draft, key = id & "-draft", placeholder = "YYYY-MM-DD":
          onChange(e):
            draft = e.value
        let candidate = eligible(draft, earliest, latest)
        row:
          button "前一天", key = id & "-previous", disabled = not canStep(candidate, earliest, latest, -1):
            draft = stepDate(draft, earliest, latest, -1)
          button "后一天", key = id & "-next", disabled = not canStep(candidate, earliest, latest, 1):
            draft = stepDate(draft, earliest, latest, 1)
        row:
          button "确认日期", key = id & "-confirm", disabled = candidate.isNone:
            # Validate the current draft, not the value captured in the view.
            let selected = eligible(draft, earliest, latest)
            if selected.isSome:
              day = selected.get
              editing = false
          button "取消", key = id & "-cancel":
            editing = false
      else:
        button "选择日期: " & $day, key = id & "-open", disabled = latest < earliest:
          draft = $day
          editing = true
