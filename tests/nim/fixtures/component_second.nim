import leaf/[core,widgets,components]
let SameName* = defineComponent[int,int]("SameName",
  proc(ctx:MountContext,props:int):int=props,
  proc(ctx:ComponentContext,props,model:int):UiDescription=host(text($model)))
