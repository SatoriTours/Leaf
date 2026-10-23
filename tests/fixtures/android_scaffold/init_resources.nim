import std/os
import leaf
import leaf/app_resources
import ../src/app
let data = currentSourcePath().parentDir / "private-data"
let cache = currentSourcePath().parentDir / "private-cache"
createDir(data); createDir(cache)
let resources = directoryResources(currentSourcePath().parentDir.parentDir / "assets", data, cache)
let runtime = newRuntime(projectDemoApp(resources))
doAssert runtime.find("message").node.text == resources.readAsset("message.txt")
doAssert runtime.dispatch("add", Event(kind: click))
doAssert runtime.find("count").node.text == "Count: 1"
runtime.closeRuntime()
doAssert resources.readAsset("message.txt").len > 0
resources.close()
echo "init shared resource factory: passed"
