import leaf
import leaf/app_resources
when not defined(android): import leaf/project

component ProjectDemo:
  prop message: string
  state:
    count = 0
  view:
    column:
      padding: 24
      gap: 12
      text "Leaf Project":
        styles: {"font_size": "26"}
      text "Count: " & $count:
        key: "count"
      text message:
        key: "message"
      button "Add", key = "add":
        count += 1

proc projectDemoApp*(resources: HostResources = nil): Application =
  let message = if resources != nil: resources.readAsset("message.txt")
    else:
      when defined(android): raise newException(UiError, "Android application requires HostResources")
      else: readFile(asset("message.txt"))
  app(ProjectDemo, (message: message), title = "Leaf Project Demo")
