import leaf/model

type ApplicationRecord* = ref object of TimestampedRecord
  category*: string
defineAbstractModel(ApplicationRecord)

type Task* = ref object of ApplicationRecord
  title*: string
  done*: bool
  priority*: int
defineModel(Task, table = "tasks")

type Note* = ref object of ApplicationRecord
  body*: string
defineModel(Note, table = "notes")
