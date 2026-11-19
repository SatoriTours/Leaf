## Launch options, demo isolation and save/reopen at the file layer.
## No window and no UI: this suite runs headless on every platform.
import ./[cleanup_support, symlink_support]
import std/[unittest, os, tempfiles, strutils, algorithm]
import leaf/native_theme
import ../../examples/native_notes/[launch_options, store]

let base = createTempDir("leaf-notes-launch-", "")
removeDirectoryOnExit(base)
let dataDir = base / "userdata"
let tempRoot = base / "temp"

proc entries(directory: string): seq[string] =
  for _, path in walkDir(directory): result.add(path.extractFilename)
  result.sort()

suite "Leaf Notes launch options":
  test "default launch resolves the user notebook without creating it":
    let normal = parseLaunchOptions(@[])
    check normal.theme == matsuLight
    check not normal.demo
    check not normal.help
    check normal.remaining.len == 0
    let userPath = normal.prepareDatabase(dataDir, tempRoot)
    check userPath == absolutePath(dataDir / "leaf-notes" / "notes.sqlite3")
    check not userPath.startsWith(absolutePath(demoRoot(tempRoot)))
    check not fileExists(userPath)

  test "each demo launch gets a fresh dataset under the temp root":
    let firstPath = parseLaunchOptions(@["--demo"]).prepareDatabase(dataDir, tempRoot)
    let secondPath = parseLaunchOptions(@["--demo"]).prepareDatabase(dataDir, tempRoot)
    check firstPath != secondPath
    check firstPath.startsWith(absolutePath(demoRoot(tempRoot)))
    check secondPath.startsWith(absolutePath(demoRoot(tempRoot)))
    check firstPath.parentDir.parentDir == absolutePath(demoRoot(tempRoot))
    check dirExists(firstPath.parentDir)
    check not fileExists(firstPath)
    check not fileExists(absolutePath(userDatabasePath(dataDir)))

  test "reopening the printed demo path keeps edits and does not reseed":
    let demoPath = parseLaunchOptions(@["--demo"]).prepareDatabase(dataDir, tempRoot)
    let created = openNotesStore(demoPath)
    check created.seeded
    check created.notes().len == 4
    let id = created.notes()[0].id
    var note = created.loadNote(id)
    note.title = "重开核验"
    note.body = "第一行\n第二行"
    created.save(note)
    created.close()

    let reopenedPath = parseLaunchOptions(@["--database", demoPath]).prepareDatabase(dataDir, tempRoot)
    check reopenedPath == demoPath
    let reopened = openNotesStore(reopenedPath)
    check reopened.seeded == false
    check reopened.loadNote(id).title == "重开核验"
    check reopened.loadNote(id).body == "第一行\n第二行"
    reopened.close()

  test "application options come before Leaf flags and are parsed in order":
    let options = parseLaunchOptions(@["--demo", "--theme", "dark",
      "--headless", "--click", "save"])
    check options.demo
    check options.theme == matsuDark
    check options.remaining == @["--headless", "--click", "save"]

  test "help and theme names":
    check parseLaunchOptions(@["--help"]).help
    check parseLaunchOptions(@["--theme", "system"]).theme == systemTheme
    check parseLaunchOptions(@["--theme", "light"]).theme == matsuLight

  test "invalid values and combinations are rejected":
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--theme", "blue"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--theme"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database", ""])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database", "--headless"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--demo", "--database", "notes.sqlite3"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database", base]).prepareDatabase(dataDir, tempRoot)

  test "conflicting demo and database fail before any file side effect":
    let isolatedTemp = base / "conflict-temp"
    let sentinel = base / "conflict.sqlite3"
    writeFile(sentinel, "conflict-sentinel")
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--demo", "--database", sentinel, "--headless"])
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database", sentinel, "--demo", "--headless"])
    check readFile(sentinel) == "conflict-sentinel"
    check not dirExists(demoRoot(isolatedTemp))

  test "removed reset flag leaves explicit database and sidecars untouched":
    let isolatedTemp = base / "reset-temp"
    let explicitDb = base / "explicit.sqlite3"
    writeFile(explicitDb, "db-bytes")
    writeFile(explicitDb & "-wal", "wal-bytes")
    writeFile(explicitDb & "-shm", "shm-bytes")
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--reset"]).prepareDatabase(dataDir, isolatedTemp)
    expect LaunchOptionError:
      discard parseLaunchOptions(@["--database", explicitDb, "--reset"]).prepareDatabase(dataDir, isolatedTemp)
    check readFile(explicitDb) == "db-bytes"
    check readFile(explicitDb & "-wal") == "wal-bytes"
    check readFile(explicitDb & "-shm") == "shm-bytes"
    check not dirExists(demoRoot(isolatedTemp))

  test "symlinked demo root is refused and linked notebooks stay byte-identical":
    if not canCreateSymlink(base, directory = true):
      checkpoint "SKIP: this host cannot create directory symlinks"
      skip()
    else:
      let linkedUser = base / "linked-user" / "leaf-notes"
      let isolatedTemp = base / "symlink-temp"
      createDir(linkedUser)
      let userStore = openNotesStore(linkedUser / "notes.sqlite3")
      userStore.close()
      let dbBytes = readFile(linkedUser / "notes.sqlite3")
      let before = entries(linkedUser)

      createDir(isolatedTemp)
      createSymlink(absolutePath(linkedUser), demoRoot(isolatedTemp))
      expect LaunchOptionError:
        discard parseLaunchOptions(@["--demo"]).prepareDatabase(dataDir, isolatedTemp)
      check symlinkExists(demoRoot(isolatedTemp))
      check readFile(linkedUser / "notes.sqlite3") == dbBytes
      check entries(linkedUser) == before

      # The old destructive path: an explicit database through a symlinked
      # parent combined with --reset must not delete anything either.
      let viaAlias = demoRoot(isolatedTemp) / "notes.sqlite3"
      expect LaunchOptionError:
        discard parseLaunchOptions(@["--database", viaAlias, "--reset"]).prepareDatabase(dataDir, isolatedTemp)
      check readFile(linkedUser / "notes.sqlite3") == dbBytes
      check entries(linkedUser) == before
