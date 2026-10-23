import leaf
import leaf/mobile
import leaf/sqlite

type Model=object
  saved:State[int64]
  taps:State[int]

proc application*(resources:HostResources):Application =
  let message=resources.readAsset("message.txt")
  let db=openDatabase(resources.dataPath("project.sqlite3"))
  try:
    db.executeScript("CREATE TABLE IF NOT EXISTS counts(id INTEGER PRIMARY KEY,value INTEGER NOT NULL); INSERT OR IGNORE INTO counts VALUES(1,5000000000);")
    let Page=defineComponent[int,Model]("ProjectCliPage",
      proc(ctx:MountContext,p:int):Model =
        ctx.onDispose(proc(e:LifecycleContext)=db.close())
        Model(saved:ctx.state(db.query("SELECT value FROM counts WHERE id=1")[0][0].asInt64),taps:ctx.state(0)),
      proc(ctx:ComponentContext,p:int,s:Model):UiDescription =
        host(column(@[
          text(message,key="message",styles=style({"height":"48"})),
          text("记录=" & $ctx.value(s.saved),key="count",styles=style({"height":"48"})),
          text("会话=" & $ctx.value(s.taps),key="session",styles=style({"height":"48"})),
          button("保存记录",key="save",styles=style({"height":"48"}),onClick=proc(e:Event)=
            let next=s.saved.read()+1
            discard db.execute("UPDATE counts SET value=? WHERE id=1",@[dbValue(next)])
            discard s.saved.set(next)
            discard s.taps.update(proc(x:int):int=x+1))],styles=style({"width":"full"}))))
    result=componentApplication(component(Page,0),"Android project",400,600)
  except CatchableError:
    db.close()
    raise
