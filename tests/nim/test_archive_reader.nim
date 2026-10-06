import ./cleanup_support
import std/[unittest, os, tempfiles, strutils]
import ./archive_reader
import leaf/archives
import ../../src/leaf/vendor/zippy/zippy

let root = createTempDir("leaf-archive-reader-", "")
removeDirectoryOnExit(root)
# Fixed gzip fixture for "abc", independent of Leaf's archive implementation.
const abc = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\x4c\x4a\x06\x00\xc2\x41\x24\x35\x03\x00\x00\x00"

suite "Independent Nim archive reader":
  test "gzip reads every concatenated member and validates their trailers":
    check readGzip(abc & abc) == "abcabc"
    var corrupted = abc & abc
    corrupted[abc.len + 15] = '\0'
    expect ValueError: discard readGzip(corrupted)
    corrupted = abc
    corrupted[^4] = '\x04'
    expect ValueError: discard readGzip(corrupted)
    expect ValueError: discard readGzip(abc[0..^2])
    expect ValueError: discard readGzip(abc & "garbage")
    expect ValueError: discard readGzip("")

  test "gzip optional filename and comment headers survive member boundaries":
    var named = abc
    named[3] = '\x18'
    named.insert("name\0comment\0", 10)
    check readGzip(named & abc) == "abcabc"

  test "multi-member TAR preserves large payload empty files and PAX UTF8 names":
    let source = root / "payload"
    let content = repeat("payload", 180_000)
    writeFile(source, content)
    let empty = root / "empty"
    writeFile(empty, "")
    let longName = "root/" & repeat("目录/", 30) & "内容.txt"
    let archive = root / "large.tar.gz"
    writeTarGzip(@[ArchiveEntry(source: source, name: longName, executable: true),
      ArchiveEntry(source: empty, name: "root/empty")], archive)
    let destination = root / "large"
    extractTar(archive, destination)
    check readFile(destination / longName) == content
    check readFile(destination / "root/empty") == ""
    when defined(posix): check fpUserExec in getFilePermissions(destination / longName)

  test "TAR reader rejects traversal broken header sums and missing end markers":
    let source = root / "safe"
    writeFile(source, "test")
    let archive = root / "safe.tar.gz"
    writeTarGzip(@[ArchiveEntry(source: source, name: "safe")], archive)
    let valid = readGzip(readFile(archive))
    var malformed = valid
    malformed[0] = 'x'
    writeFile(root / "bad.tar.gz", compress(malformed))
    expect ValueError: extractTar(root / "bad.tar.gz", root / "bad-sum")
    check not dirExists(root / "bad-sum")
    malformed = valid
    malformed[0..<100] = "../outside" & repeat('\0', 90)
    malformed[148..<156] = repeat(' ', 8)
    var checksum = 0
    for byte in malformed[0..<512]: checksum += ord(byte)
    malformed[148..<156] = toOct(checksum, 6) & "\0 "
    writeFile(root / "traversal.tar.gz", compress(malformed))
    expect ValueError: extractTar(root / "traversal.tar.gz", root / "traversal")
    check not fileExists(root / "outside")
    check not dirExists(root / "traversal")
    writeFile(root / "unfinished.tar.gz", compress(valid[0..<1024]))
    expect ValueError: extractTar(root / "unfinished.tar.gz", root / "unfinished")
    check not dirExists(root / "unfinished")
