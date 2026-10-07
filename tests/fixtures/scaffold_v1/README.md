# scaffold_v1

This Leaf application uses page groups, shared models and services, and independent route configuration.

```sh
leaf --check .
leaf --watch .
leaf --headless --change task_draft 'First task' --click task_add .
leaf g scaffold Note title:string archived:bool --project .
leaf g scaffold Metric count:int amount:float --project . --dry-run
leaf pack . --target linux --output dist
```

Run generated service tests with `nim c -r --path:/path/to/leaf/src tests/test_home.nim` and equivalent resource test files. Set your editor's Nim source path to the same Leaf installation.

- `app/pages/<group>/logic.nim` owns interaction state and calls services.
- `app/pages/<group>/views/` contains the group's Views.
- `page.nim` preloads dependencies and includes the logic and Views; edit the included files without repeating imports.
- `app/models/` defines data and validation. `app/services/` contains operations shared by pages and future jobs.
- `config/routes.nim` is the human-owned route entry. Add custom routes there and corresponding page definitions in `app/application.nim` if needed.
- `app/generated/pages.nim`, `app/generated/migrations.nim`, `config/generated/routes.nim`, and `.leaf/scaffold.json` are generator-owned. Commit them; edits to registration files are detected and never silently overwritten. Removing `.leaf/scaffold.json` disables resource generation.
- Resource scaffolds generate a SQLite create/list/view/edit/delete flow, migration SQL and tests, and automatically register the page and route. Fields support string, bool, int and float. Strings are required and trimmed; float values must be finite.
- Model names use singular PascalCase; file names use snake_case. Plurals use simple y/ies, s/x/z/ch/sh/es and +s rules, not a complete English inflector.

Records are persisted in SQLite; drafts, search and display settings reset on exit. `config/database.nim` defaults to the application's user-data directory and respects `LEAF_DATABASE_PATH`. Application startup opens one connection, applies pending migrations and injects it into page factories and services. Importing configuration has no database side effects. `--check` also initializes storage, so use a separate database path for checks.

`app/generated/migrations.nim` embeds up SQL at compile time. Each migration commits atomically and is recorded in `leaf_schema_migrations`; repeated startup is safe. Do not edit applied migrations or include transaction commands in SQL scripts. Down SQL is available for manual maintenance; startup never automatically rolls back. There is no standalone `leaf db migrate` command. Service tests use an isolated SQLite `:memory:` connection. SQLite AUTOINCREMENT IDs are not reused after deletion.

The application requires a system SQLite library: `libsqlite3.so.0` on Linux, `libsqlite3.dylib` on macOS, `sqlite3.dll` on Windows. Windows distributions must provide the DLL; the packager does not collect it automatically. Background jobs must open their own connections rather than sharing the UI connection.

Add application-specific external API clients in `app/clients/`, background work in `app/jobs/`, scheduling rules in `config/schedules.nim`, and manual maintenance commands in `lib/tasks/` when those capabilities are implemented. Jobs should reuse services; the UI thread owns page state.

Dependencies are preassembled for the generated page groups. Arbitrary new files are not discovered automatically: add them to their page-group entry. Leaf watch rebuilds and replaces the process, resetting page state while saved records remain in SQLite.
