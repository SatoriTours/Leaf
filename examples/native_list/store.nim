## Sparse SQLite edits keyed by the stable item id, not a viewport/pool index.
import leaf/sqlite
export sqlite.DatabaseError

const ListItemCount* = 10_000

type
  ListItem* = object
    id*: int
    note*: string
    done*: bool
  ListStore* = ref object
    db: Database

proc requireId(id: int) =
  if id < 0 or id >= ListItemCount:
    raise newException(ValueError, "row id is outside the 10k source")

proc openListStore*(path: string): ListStore =
  let db = openDatabase(path)
  try:
    db.executeScript("""CREATE TABLE IF NOT EXISTS native_list_items (
      id INTEGER PRIMARY KEY CHECK (id >= 0 AND id < 10000),
      note TEXT NOT NULL, done INTEGER NOT NULL CHECK (done IN (0, 1))
    );""")
    result = ListStore(db: db)
  except:
    db.close()
    raise

proc close*(storage: ListStore) =
  if storage != nil: storage.db.close()

proc loadItem*(storage: ListStore, id: int): ListItem =
  requireId(id)
  let rows = storage.db.query(
    "SELECT note, done FROM native_list_items WHERE id = ?", @[dbValue(id)])
  result = ListItem(id: id)
  if rows.len == 1:
    result.note = rows[0][0].asString
    result.done = rows[0][1].asBool

proc saveItem*(storage: ListStore, item: ListItem) =
  requireId(item.id)
  discard storage.db.execute("""INSERT INTO native_list_items(id, note, done)
    VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET note=excluded.note,
    done=excluded.done""", @[dbValue(item.id), dbValue(item.note), dbValue(item.done)])
