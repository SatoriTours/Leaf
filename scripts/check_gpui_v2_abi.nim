## Compile each language's actual declarations independently and compare layouts.
import std/[os, osproc, strutils, streams]
let root = currentSourcePath().parentDir.parentDir
let output = root / "target" / "ffi-v2"
createDir(output)
proc run(exe:string,args:seq[string]):string =
  let process = startProcess(exe,workingDir=root,args=args,
    options={poUsePath,poStdErrToStdOut})
  let text = process.outputStream.readAll()
  let status = process.waitForExit()
  process.close()
  if status != 0: raise newException(IOError,exe & " failed: " & text)
  text
let compiler = getEnv("NIM",findExe("nim"))
let rust = getEnv("RUSTC",findExe("rustc"))
let cc = getEnv("CC",findExe("gcc"))
if compiler.len == 0 or rust.len == 0 or cc.len == 0:
  quit("ABI check requires existing Nim, rustc and C compiler",1)
let cOut = output / "c-layout".addFileExt(ExeExt)
let nOut = output / "nim-layout".addFileExt(ExeExt)
let rOut = output / "rust-layout".addFileExt(ExeExt)
discard run(cc,@["-std=c11","tests/ffi/gpui_v2_layout.c","-o",cOut])
discard run(compiler,@["c","--path:src","--out:" & nOut,"tests/ffi/gpui_v2_layout.nim"])
discard run(rust,@["--edition","2024","-A","dead_code","tests/ffi/gpui_v2_layout.rs","-o",rOut])
let c = run(cOut,@[])
let n = run(nOut,@[])
let r = run(rOut,@[])
if c != n or c != r:
  writeFile(output/"c-layout.txt",c)
  writeFile(output/"nim-layout.txt",n)
  writeFile(output/"rust-layout.txt",r)
  quit("ABI 2 layout mismatch; see " & output,1)
stdout.writeLine("ABI 2 C/Nim/Rust layout PASS: " & $c.splitLines.len & " entries")
