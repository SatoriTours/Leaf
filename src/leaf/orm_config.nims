import std/[os, strutils]
import ./orm_config
for argument in ormCompilerArgs(currentSourcePath().parentDir.parentDir):
  let separator = argument.find(':')
  let key = argument[0..<separator].strip(chars = {'-'})
  switch(if key == "d": "define" else: key, argument[separator+1..^1])
