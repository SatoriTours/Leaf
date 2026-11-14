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
    try:
      if db.query("SELECT value FROM notes_meta WHERE key = 'seeded'").len == 0:
        let seeds = [
          ("Leaf 的第一份笔记", "好的工具，让你专注于想法本身。\n不必复杂，也不必喧闹。打开它，写下此刻值得留下的事。\n\n用 Nim 描述界面，\n让状态驱动原生控件。\n\n从一个小小的想法开始\n\n✓ 创建第一份笔记\n✓ 给它一个喜欢的名字\n□ 记录下一个值得实现的点子\n\n想法不必完整，先写下来就好。", "灵感", true),
          ("把周末留给自己", "去公园走走，读完手边的那本书。\n\n留一点时间，做没有截止日期的事。", "日常", false),
          ("关于一个小工具的想法", "少一点打扰，多一点恰到好处。\n\n把复杂留给实现，把简单留给使用。", "项目", false),
          ("最近读到的一句话", "在平常的事物里，发现新的可能。\n\n记录，是和未来的自己对话。", "灵感", true)]
        for seed in seeds:
          discard db.execute("INSERT INTO notes(title,body,tag,updated,favorite,archived) VALUES(?,?,?,?,?,0)",
            @[dbValue(seed[0]), dbValue(seed[1]), dbValue(seed[2]), dbValue(stamp()), dbValue(seed[3])])
        discard db.execute("INSERT INTO notes_meta(key,value) VALUES('seeded','1')")
      db.executeScript("COMMIT")
    except:
      db.executeScript("ROLLBACK")
      raise
    result = NotesStore(db: db)
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
