## Immutable named route configuration shared by component routing.
type
  Route* = object
    name*, path*, page*, view*: string
