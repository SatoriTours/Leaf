import leaf/model
import std/strutils

type ApplicationRecord* = ref object of TimestampedRecord
  category*: string
proc normalizeCategory(record: ApplicationRecord) = record.category = record.category.strip()
defineAbstractModel(ApplicationRecord):
  validates category, maxLength = 200
  beforeValidation normalizeCategory
  scope home, it.category == "home"

type Task* = ref object of ApplicationRecord
  title*: string
  done*: bool
  priority*: int
proc normalizeTitle(record: Task) = record.title = record.title.strip()
defineModel(Task, table = "tasks"):
  validates title, presence = true, maxLength = 200
  beforeValidation normalizeTitle
  scope unfinished, it.done == false

type Note* = ref object of ApplicationRecord
  body*: string
defineModel(Note, table = "notes")
