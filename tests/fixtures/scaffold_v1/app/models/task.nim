from "$lib/system" as nim_system import nil
import std/strutils

type
  TaskValidationError* = object of nim_system.ValueError
  Task* = object
    id*: int
    title*: string
    done*: bool

proc validate*(value: Task) =
  if value.title.strip().len == 0:
    raise newException(TaskValidationError, "title cannot be empty")
