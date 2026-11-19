import leaf

type Amount = int
proc defaultIncrement(): Amount = 2

contract ImportedControl, exported:
  model count: Amount
  prop increment: Amount = defaultIncrement()
