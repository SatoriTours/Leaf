import std/[os, strutils]
import ./orm_config
for argument in ormCompilerArgs(currentSourcePath().parentDir.parentDir):
  let separator = argument.find(':')
  let key = argument[0..<separator].strip(chars = {'-'})
  let value = argument[separator+1..^1]
  switch(if key == "d": "define" else: key,
    if key == "path": value.replace("$", "$$") else: value)
