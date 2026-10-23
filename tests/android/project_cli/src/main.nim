import std/os
import leaf
import leaf/[app_resources,project]
import app
let data=getTempDir() / "leaf-project-cli-desktop"
createDir(data)
let resources=newHostResources(proc(relative:string,maxBytes:int):string=readFile(asset(relative)),data,data)
try:quit run(application(resources))
finally:resources.close()
