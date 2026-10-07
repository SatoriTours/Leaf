## Norm storage objects borrow Leaf's SQLite handle; only Leaf owns the handle.
import ../../sqlite as storage except dbValue
import norm/[model, sqlite]
import norm/private/sqlite/rowutils
import lowdb/sqlite as low
import db_connector/db_common
import std/options
import ../metadata

proc insertStorage*[S: Model](db: storage.Database, value: var S) =
  let borrowed = cast[low.DbConn](db.borrowSqliteHandle())
  try:
    borrowed.insert(value)
  except DbError as error:
    db.raiseSqliteError(error.msg)

proc lowValue(value: storage.SqlValue): low.DbValue =
  case value.kind
  of storage.sqlNull: low.DbValue(kind: low.dvkNull)
  of storage.sqlInteger: low.dbValue(value.integer)
  of storage.sqlFloat: low.dbValue(value.number)
  of storage.sqlText: low.dbValue(value.text)

proc mappedValue[T](value: storage.SqlValue, _: typedesc[T]): low.DbValue =
  when T is Option:
    if value.kind == storage.sqlNull: return low.DbValue(kind: low.dvkNull)
    mappedValue(value, typeof(default(T).get))
  else:
    # Validate kinds/ranges before Norm reads DbValue variant fields.
    lowValue(fieldValue(fieldFromValue(value, T)))

proc selectStorage*[S: Model](db: storage.Database, sql: string,
                             values: openArray[storage.SqlValue]): seq[S] =
  db.requireUsable()
  var expected = 0
  for field, value in S()[].fieldPairs: inc expected
  for row in db.query(sql, values):
    if row.len != expected:
      raise newException(storage.DatabaseError, "raw model query must select every persistent column in declaration order")
    var mapped: low.Row
    var column = 0
    for field, dummy in S()[].fieldPairs:
      mapped.add(mappedValue(row[column], typeof(dummy)))
      inc column
    var instance = S()
    instance.fromRow(mapped)
    result.add(instance)

proc executeAffected*(db: storage.Database, sql: string,
                      values: openArray[storage.SqlValue]): int64 =
  int64(db.execute(sql, values))
