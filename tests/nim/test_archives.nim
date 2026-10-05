import ./cleanup_support
import std/[unittest, os, tempfiles, strutils]
import leaf/[checksum, archives, archive_crc, core]
import ../../src/leaf/vendor/zippy/zippy/[ziparchives, tarballs]

let root = createTempDir("leaf-archives-", "")
removeDirectoryOnExit(root)
suite "Pure Nim release archive primitives":
  test "SHA256 empty abc and large streaming input match known vectors":
    let path = root / "hash.dat"
    writeFile(path, "")
    check sha256File(path) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    writeFile(path, "abc")
    check sha256File(path) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    writeFile(path, repeat('a', 1_000_000))
    check sha256File(path) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  test "archive names sizes and permissions are represented for all targets":
    let file = root / "app"
    writeFile(file, "compiled app")
    let entries = @[archives.ArchiveEntry(source: "", name: "My App/", directory: true),
      archives.ArchiveEntry(source: file, name: "My App/应用", executable: true)]
    writeTarGzip(entries, root / "linux.tar.gz")
    writeZip(entries, root / "portable.zip")
    check readFile(root / "linux.tar.gz")[0..2] == "\x1f\x8b\x08"
    check readFile(root / "portable.zip")[0..3] == "PK\x03\x04"
    let reader = openZipArchive(root / "portable.zip")
    check reader.extractFile("My App/应用") == "compiled app"
    reader.close()
    tarballs.extractAll(root / "linux.tar.gz", root / "linux-unpacked")
    ziparchives.extractAll(root / "portable.zip", root / "zip-unpacked")
    check readFile(root / "linux-unpacked/My App/应用") == "compiled app"
    when defined(posix):
      check fpUserExec in getFilePermissions(root / "linux-unpacked/My App/应用")
      check fpUserExec in getFilePermissions(root / "zip-unpacked/My App/应用")
  test "CRC32 updates preserve the independent known checksum":
    var crc: Crc32
    crc.update("1234"); crc.update("56789")
    check crc.digest() == 0xcbf43926'u32
  test "long UTF8 paths empty files and deterministic archive bytes survive readers":
    let file = root / "empty"
    writeFile(file, "")
    let name = "root/" & repeat("目录/", 30) & "空文件.txt"
    let entries = @[archives.ArchiveEntry(source: file, name: name)]
    writeTarGzip(entries, root / "long.tar.gz")
    writeTarGzip(entries, root / "long-again.tar.gz")
    check sha256File(root / "long.tar.gz") == sha256File(root / "long-again.tar.gz")
    tarballs.extractAll(root / "long.tar.gz", root / "long-unpacked")
    check readFile(root / "long-unpacked" / name) == ""
    writeZip(entries, root / "long.zip")
    let reader = openZipArchive(root / "long.zip")
    check reader.extractFile(name) == ""
    reader.close()
  test "files above the compression buffer limit stream into valid ZIP records":
    let file = root / "large"
    writeFile(file, repeat('q', ZipCompressionLimit + 1))
    writeZip(@[archives.ArchiveEntry(source: file, name: "large")], root / "large.zip")
    let reader = openZipArchive(root / "large.zip")
    let contents = reader.extractFile("large")
    check contents.len == ZipCompressionLimit + 1
    check contents[0] == 'q' and contents[^1] == 'q'
    reader.close()
  test "nonportable traversal and case collisions fail before creating artifacts":
    let path = root / "rejected.zip"
    let file = root / "empty"
    expect UiError: writeZip(@[archives.ArchiveEntry(source: file, name: "../outside")], path)
    check not fileExists(path)
    expect UiError: writeZip(@[archives.ArchiveEntry(source: file, name: "Root/File"),
      archives.ArchiveEntry(source: file, name: "root/file")], path)
    check not fileExists(path)
