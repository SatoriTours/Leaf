import std/[unittest,os,json,tempfiles]
import leaf/licenses
import ./cleanup_support

let root=createTempDir("leaf-ui-licenses-","")
removeDirectoryOnExit(root)

suite "standard UI attribution":
  test "redistributed licenses preserve pinned upstream source and MIT notice":
    collectLicenses(root)
    require fileExists(root/"shadcn-ui/LICENSE.txt")
    check readFile(root/"shadcn-ui/LICENSE.txt").len>900
    let inventory=parseFile(root/"inventory.json")
    require inventory.hasKey("shadcn-ui")
    check inventory["shadcn-ui"]["commit"].getStr=="42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9"
    check inventory["shadcn-ui"]["license"].getStr=="MIT"
    check inventory["shadcn-ui"]["license_file"].getStr=="shadcn-ui/LICENSE.txt"
