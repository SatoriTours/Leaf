import leaf

type Pick* = distinct int

contract Picker, exported:
  model marker: int
  event onPick: Pick
  event onReset

implement Picker:
  view:
    row:
      button "Pick", key = "contract-pick":
        marker = 9
        onPick(Pick(marker))
      button "Reset", key = "contract-reset":
        marker = 0
        onReset()
