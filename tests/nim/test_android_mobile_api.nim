## Compile-only API probe: the Android branch must not import desktop/GPUI.
import leaf
import leaf/mobile
let Root=defineComponent[int,int]("MobileApiProbe",
  proc(ctx:MountContext,p:int):int=p,
  proc(ctx:ComponentContext,p:int,m:int):UiDescription=host(text("移动 中文😀")))
proc factory(resources:HostResources):Application =
  discard resources.dataPath("notes.sqlite3")
  componentApplication(component(Root,0),"Mobile",400,600)
registerAndroidApplication(ResourceApplicationFactory(factory))
