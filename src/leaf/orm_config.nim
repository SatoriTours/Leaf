## Compiler configuration shared by the source checkout, CLI and offline SDK.
import std/os

proc ormCompilerArgs*(sourceRoot: string): seq[string] =
  for package in ["norm", "lowdb", "db_connector"]:
    result.add("--path:" & sourceRoot / "leaf/vendor/orm" / package / "src")
  result.add("--deepcopy:on")
  let library = when defined(windows): "winsqlite3.dll"
    elif defined(macosx): "libsqlite3.dylib"
    else: "libsqlite3.so(|.0)"
  result.add("-d:leafOrmSqliteLibrary=" & library)
