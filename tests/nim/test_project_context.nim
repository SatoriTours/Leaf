import ./cleanup_support
import std/[unittest, os, options, strutils, tempfiles]
import leaf/[core, project, project_context]

let base = createTempDir("leaf-nim-project-context-", "")
removeDirectoryOnExit(base)

suite "current project resolution":
  test "nearest project resolves from nested cwd":
    let app = base / "app"
    initProject(app)
    let childDir = app / "src" / "nested" / "deep directory"
    createDir(childDir)
    check requireCurrentProject(childDir).root == realPath(app)
    check requireCurrentProject(childDir).entry == readProject(app).entry
    let resolved = findCurrentProject(childDir)
    check resolved.isSome
    check resolved.get().root == realPath(app)
    check requireCurrentProject(app).root == realPath(app)

  test "nested project wins over the surrounding project":
    let outer = base / "outer"
    initProject(outer)
    let inner = outer / "packages" / "inner"
    initProject(inner)
    let deep = inner / "src" / "views"
    createDir(deep)
    check requireCurrentProject(deep).root == realPath(inner)
    check requireCurrentProject(inner).root == realPath(inner)
    check requireCurrentProject(outer / "src").root == realPath(outer)

  test "no configuration returns none and requires a project":
    let outside = base / "outside"
    createDir(outside)
    check findCurrentProject(outside).isNone
    expect UiError:
      discard requireCurrentProject(outside)

  test "corrupt nearest configuration fails instead of falling back":
    let app = base / "corrupt app"
    initProject(app)
    let broken = app / "broken"
    createDir(broken)
    writeFile(broken / "leaf.json", "{ not valid json")
    expect UiError:
      discard requireCurrentProject(broken)
    expect UiError:
      discard findCurrentProject(broken)
    # A sibling directory without its own manifest still resolves the parent.
    check findCurrentProject(app / "src").get().root == realPath(app)

  test "directory occupying leaf.json is not treated as absent":
    let app = base / "placeholder app"
    initProject(app)
    let shadowed = app / "shadowed"
    createDir(shadowed / "leaf.json")
    expect UiError:
      discard findCurrentProject(shadowed)
    expect UiError:
      discard requireCurrentProject(shadowed)

  when defined(posix):
    test "broken leaf.json symlink is not treated as absent":
      let app = base / "symlink app"
      initProject(app)
      let shadowed = app / "linked"
      createDir(shadowed)
      createSymlink(app / "missing-target.json", shadowed / "leaf.json")
      expect UiError:
        discard findCurrentProject(shadowed)
      expect UiError:
        discard requireCurrentProject(shadowed)

  test "default start directory is the current working directory":
    let app = base / "cwd app"
    initProject(app)
    let deep = app / "src" / "views"
    createDir(deep)
    let previous = getCurrentDir()
    setCurrentDir(deep)
    try:
      check requireCurrentProject().root == realPath(app)
      check findCurrentProject().get().root == realPath(app)
    finally:
      setCurrentDir(previous)

  test "spaces and Chinese characters keep their own root path":
    let app = base / "中文 项目"
    initProject(app)
    let deep = app / "深层 目录"
    createDir(deep)
    let project = requireCurrentProject(deep)
    check project.root == realPath(app)
    check project.root.endsWith("中文 项目")
    check project.name == "中文 项目"
