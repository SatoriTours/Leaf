## Pure single-selection radio-group policy. No OS objects, no Win32 import and
## no event plumbing: the constructor, prepare and the native roving-focus
## handler all consume the same small decisions here so the keyboard rules are
## testable anywhere.
##
## First slice: one vertical group, single selection, controlled accepted value.
## The accepted value is the only selection authority; a click or Space key is a
## request, and the group never invents a choice when the accepted value is
## empty or names an option that no longer exists.
import std/sets

type
  RadioItem* = object
    ## One option as the focus policy sees it: the declared value and the
    ## accepted/native state the caller already resolved.
    value*: string
    enabled*: bool
    checked*: bool

  RadioMove* = enum
    radioUp = "up", radioDown = "down", radioHome = "home", radioEnd = "end"

proc radioSelectionReason*(items: openArray[RadioItem], value: string): string =
  ## Construction/prepare refusal reason for one group's option list and
  ## accepted value. Empty means "valid". Never repairs the caller's value.
  if items.len == 0: return "radio group requires at least one option"
  var seen = initHashSet[string]()
  for item in items:
    if item.value.len == 0: return "radio option value cannot be empty"
    if item.value in seen:
      return "radio option values must be unique: " & item.value
    seen.incl(item.value)
  if value.len != 0 and value notin seen:
    return "accepted radio value is not an option: " & value
  var checkedCount = 0
  var checkedValue = ""
  for item in items:
    if item.checked:
      inc checkedCount
      checkedValue = item.value
  if checkedCount > 1: return "radio group cannot accept two options"
  if value.len == 0:
    if checkedCount != 0: return "radio group has no accepted value but an option is checked"
  elif checkedCount != 1 or checkedValue != value:
    return "accepted radio value and checked option disagree"
  ""

proc radioTabStop*(items: openArray[RadioItem]): int =
  ## The group's single Tab entry: the accepted enabled option, otherwise the
  ## first enabled option, otherwise no Tab stop at all.
  for index, item in items:
    if item.enabled and item.checked: return index
  for index, item in items:
    if item.enabled: return index
  -1

proc radioMove*(items: openArray[RadioItem], current: int, move: RadioMove): int =
  ## Roving focus for one group. Up/Down wrap and skip disabled options;
  ## Home/End land on the first/last enabled option. Focus never leaves the
  ## group, and moving focus never selects anything.
  if items.len == 0: return 0
  if current < 0 or current >= items.len: return 0
  case move
  of radioHome:
    for index, item in items:
      if item.enabled: return index
    current
  of radioEnd:
    var index = items.len - 1
    while index >= 0:
      if items[index].enabled: return index
      dec index
    current
  of radioDown:
    for step in 1 .. items.len:
      let index = (current + step) mod items.len
      if items[index].enabled: return index
    current
  of radioUp:
    for step in 1 .. items.len:
      let index = (current - step + items.len * 2) mod items.len
      if items[index].enabled: return index
    current
