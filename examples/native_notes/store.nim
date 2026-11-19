## Local SQLite notebook. Explicit saves only; seed data is inserted atomically
## once, never again over an existing notebook.
import std/[strutils, times, unicode]
import leaf/sqlite
export sqlite.DatabaseError

type
  NotesView* = enum notesAll, notesFavorites, notesArchive
  Note* = object
    id*: int
    title*, body*, tag*, updated*: string
    favorite*, archived*: bool
  NotesStore* = ref object
    db: Database
    seeded*: bool ## True only when this open created the demo rows.

proc close*(store: NotesStore) =
  if store != nil: store.db.close()

proc stamp(): string = now().format("yyyy-MM-dd HH:mm")

proc decode(row: seq[SqlValue]): Note =
  Note(id: row[0].asInt, title: row[1].asString, body: row[2].asString,
    tag: row[3].asString, updated: row[4].asString,
    favorite: row[5].asBool, archived: row[6].asBool)

const columns = "id, title, body, tag, updated, favorite, archived"

proc openNotesStore*(path: string): NotesStore =
  let db = openDatabase(path)
  try:
    db.executeScript("""CREATE TABLE IF NOT EXISTS notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL, body TEXT NOT NULL, tag TEXT NOT NULL,
      updated TEXT NOT NULL,
      favorite INTEGER NOT NULL CHECK(favorite IN (0,1)),
      archived INTEGER NOT NULL CHECK(archived IN (0,1)));
      CREATE TABLE IF NOT EXISTS notes_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);""")
    db.executeScript("BEGIN IMMEDIATE")
    var seeded = false
    try:
      if db.query("SELECT value FROM notes_meta WHERE key = 'seeded'").len == 0:
        let seeds = [
          ("Leaf 的第一份笔记", "周六早上去河边的旧书市。\n从南门进去，先找地图和地方志的摊位。\n\n想带回来的书\n一本有手写批注的游记；一本讲河流或桥梁的书。\n如果遇到旧地图，看看上面还有没有外婆住过的那条街。\n\n回来后写一段\n先别查资料，专注记下沿途听到的声音和看到的颜色。\n把当天最想记住的一句，留作游记的开头。", "灵感", true),
          ("把周末留给自己", "图书馆十点开门，记得带上借书证。\n\n午后去河边绕一圈。下雨就去车站旁的咖啡馆，把上周借的书读完。", "日常", false),
          ("街区地图小项目", "先画从地铁口到菜场的步行路线。\n\n标出有树荫的长椅和能避雨的屋檐；周三请小林试走一遍。", "项目", false),
          ("最近读到的一句话", "桥的另一边，风先到了。\n\n抄在这里，或许可以作为雨天那篇短文的第一句。", "灵感", true)]
        for seed in seeds:
          discard db.execute("INSERT INTO notes(title,body,tag,updated,favorite,archived) VALUES(?,?,?,?,?,0)",
            @[dbValue(seed[0]), dbValue(seed[1]), dbValue(seed[2]), dbValue(stamp()), dbValue(seed[3])])
        discard db.execute("INSERT INTO notes_meta(key,value) VALUES('seeded','1')")
        seeded = true
      db.executeScript("COMMIT")
    except:
      db.executeScript("ROLLBACK")
      raise
    result = NotesStore(db: db, seeded: seeded)
  except:
    db.close()
    raise

proc loadNote*(store: NotesStore, id: int): Note =
  let rows = store.db.query("SELECT " & columns & " FROM notes WHERE id = ?", @[dbValue(id)])
  if rows.len != 1: raise newException(ValueError, "笔记不存在")
  decode(rows[0])

proc notes*(store: NotesStore, query = "", view = notesAll, tag = ""): seq[Note] =
  ## Match Unicode text in Nim: SQLite's default lower() is ASCII-only.
  let needle = unicode.toLower(strutils.strip(query))
  let predicate = case view
    of notesAll: "archived=0"
    of notesFavorites: "archived=0 AND favorite=1"
    of notesArchive: "archived=1"
  for row in store.db.query("SELECT " & columns & " FROM notes WHERE " &
      predicate & " ORDER BY updated DESC, id ASC"):
    let note = decode(row)
    if (tag.len == 0 or note.tag == tag) and (needle.len == 0 or
        unicode.toLower(note.title & "\n" & note.body).contains(needle)):
      result.add(note)

proc save*(store: NotesStore, note: Note) =
  if strutils.strip(note.title).len == 0:
    raise newException(ValueError, "标题不能为空")
  if note.title.len > 4096 or note.body.len > 900_000:
    raise newException(ValueError, "笔记内容过长")
  if note.id <= 0: raise newException(ValueError, "笔记不存在")
  if store.db.execute("UPDATE notes SET title=?,body=?,tag=?,updated=?,favorite=?,archived=? WHERE id=?",
      @[dbValue(note.title), dbValue(note.body), dbValue(note.tag), dbValue(stamp()),
        dbValue(note.favorite), dbValue(note.archived), dbValue(note.id)]) != 1:
    raise newException(ValueError, "笔记不存在")

proc createNote*(store: NotesStore): int =
  discard store.db.execute("INSERT INTO notes(title,body,tag,updated,favorite,archived) VALUES(?,?,?,?,0,0)",
    @[dbValue("未命名笔记"), dbValue(""), dbValue("灵感"), dbValue(stamp())])
  store.db.lastInsertId()
