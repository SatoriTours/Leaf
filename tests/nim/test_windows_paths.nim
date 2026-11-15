## Windows build paths must survive non-ASCII names, spaces and a literal `$`.
##
## Two contracts stay separate on purpose:
##  * addressable: whatever spelling windows_paths.compilerPath returns must resolve
##    to the same file, because that is the only thing this function owns;
##  * 8.3 alias: a short ASCII alias is a *volume* capability. When generation is
##    disabled GetShortPathNameW returns nothing and compilerPath deliberately keeps
##    the original spelling, so the alias assertion is reported as NotRun instead of
##    passing silently. This test never changes volume or system settings.
##
## Whether the whole build works under those paths is a different layer: the real
## compile/link/resource build runs in test_windows_manifest.nim ("actual built PE
## resource survives moved sources and complex paths") on the Windows host matrix.
import std/[unittest, os, strutils, tempfiles]
import leaf/windows_paths
import ./cleanup_support
when defined(windows):
  import std/winlean
  import leaf/[windows_process, process_io]

when defined(windows):
  proc getShortPath(path, buffer: WideCString, length: uint32): uint32 {.stdcall,
    dynlib: "kernel32", importc: "GetShortPathNameW".}

  proc shortAlias(path: string): string =
    ## Independent probe of the volume capability, not of compilerPath.
    let wide = newWideCString(path)
    let length = getShortPath(wide, nil, 0)
    if length == 0 or length > 32768: return
    var buffer = newWideCString(int(length) + 1)
    let received = getShortPath(wide, buffer, length + 2)
    if received == 0 or received > length: return
    result = $buffer
    if result == path: result = ""

  suite "Windows build paths":
    test "compilerPath leaves ASCII spaces and dollars untouched":
      # MinGW receives these verbatim through CreateProcess; quoting happens once
      # at the process boundary, so the alias must never rewrite or double `$`.
      let base = createTempDir("leaf paths ascii `$` ", "")
      removeDirectoryOnExit(base)
      let child = base / "cache `$` dir"
      createDir(child)
      check compilerPath(child) == child
      let file = child / "leaf app.c"
      writeFile(file, "int main(void){return 0;}\n")
      check compilerPath(file) == file

    test "compilerPath keeps a non-ASCII file addressable":
      let base = createTempDir("leaf paths 中文 ", "")
      removeDirectoryOnExit(base)
      let nested = base / "子目录 space"
      createDir(nested)
      let file = nested / "leaf 应用.c"
      let contents = "int main(void){return 0;}"
      writeFile(file, contents)
      let aliased = compilerPath(file)
      check aliased.len > 0
      check fileExists(aliased)
      # Addressable means the returned spelling reaches the same bytes; it does not
      # by itself prove that the compiler can build from it.
      check readFile(aliased) == contents

    test "the 8.3 alias contract holds only where the volume provides aliases":
      let base = createTempDir("leaf paths 中文 alias ", "")
      removeDirectoryOnExit(base)
      let nested = base / "子目录 space"
      createDir(nested)
      let file = nested / "leaf 应用.c"
      writeFile(file, "int main(void){return 0;}\n")
      let alias = shortAlias(nested)
      if alias.len == 0:
        echo "NotRun: this volume has no 8.3 alias for the directory; " &
          "compilerPath must fall back to the Unicode spelling"
        skip()
      else:
        let aliased = compilerPath(nested / "leaf 应用.c")
        check aliased != file
        for character in aliased:
          check ord(character) < 128
        check fileExists(aliased)

    test "child argv preserves 中文, spaces and a literal dollar":
      let base = createTempDir("leaf argv 中文 `$` ", "")
      removeDirectoryOnExit(base)
      let file = base / "内容 `$` 1.txt"
      writeFile(file, "literal `$`PATH stays text 中文")
      let comspec = getEnv("COMSPEC")
      check comspec.len > 0
      # "type" reads the argument verbatim: no environment expansion and no `$`
      # doubling may happen between Nim and the child command line.
      let child = startManaged(comspec, @["/d", "/c", "type", file], base)
      defer: child.close()
      while not child.poll(): sleep(10)
      checkpoint child.output
      check child.code == 0
      check child.output.contains("literal `$`PATH stays text 中文")
else:
  suite "Windows build paths":
    test "requires the Windows host matrix":
      echo "NotRun: windows_paths and Windows child argv only exist on a Windows host"
      skip()
