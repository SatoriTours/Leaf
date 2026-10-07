# {{name}}

This Leaf application uses page groups, inherited models and SQLite migrations.

```sh
leaf --check .
leaf --watch .
leaf --headless --change task_draft 'First task' --click task_add .
leaf g scaffold Note title:string archived:bool --project .
leaf pack . --target linux --output dist
nim c -r --path:/path/to/leaf/src tests/test_home.nim
```

- `app/models/application_record.nim` inherits TimestampedRecord. Models share CRUD, validations, dirty tracking, queries and transactions through `leaf/model`.
- `app/pages/<group>/logic.nim` owns independent drafts and calls models directly. Editing and cancelling a draft never modifies a saved record. Failed saves retain input and show structured validation messages.
- `page.nim` includes logic and Views. Add new View imports there.
- `app/application.nim` opens and migrates one connection at startup. Its render and executionScope bind that connection for queries and later callbacks. Business methods need no database argument.
- `config/routes.nim` is human owned. Generated pages, routes, migrations and `.leaf/scaffold.json` are generator owned; edited registries are never silently overwritten.

Schema 2 resources use int64 IDs, UTC created_at/updated_at timestamps, required trimmed strings (maximum 200 Unicode codepoints), and finite floats. Fields support string, bool, int and float. Timestamps are SQLite REAL Unix seconds; clean saves do not update timestamps. SQLite INTEGER PRIMARY KEY may reuse deleted IDs. Schema 1 applications continue generating their original service API until manually migrated.

Set `LEAF_DATABASE_PATH` to change storage; the default is the application's user-data directory. Importing configuration does not open a connection. Startup embeds and applies migrations atomically and records checksums in `leaf_schema_migrations`. Never change an applied migration; add a new migration and update the registry. Down SQL is for manual maintenance.

Model query examples within the application's scope:

```nim
let unfinished = Task.where(done = false).all
let first = Task.first     # Option[Task], default id ASC
let last = Task.last       # Option[Task]
let total = Task.count     # int64
let titles = Task.where(it.title.contains("milk")).pluck(it.title)
transaction:
  Task.createOrRaise(title = "First").saveOrRaise()
```

`all` returns seq[Task]. count/exists ignore pagination; first/last(n) respect it and return rows in the original order. Query builders capture their connection. Nil or closed connections, cross-thread access and switching connections inside an active transaction fail explicitly. Background jobs open their own connection and use withDatabase; scopes are synchronous and must not cross await.

Norm, lowdb and db_connector sources and MIT licenses are bundled in Leaf; builds need no Nimble downloads. SQLite comes from libsqlite3.so on Linux, libsqlite3.dylib on macOS, and system winsqlite3.dll on Windows.
