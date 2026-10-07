import leaf/sqlite as storage
from ../config/database as database_config import nil
from ../app/models/task as record_model import nil
from ../app/services/task_service as record_service import all, find, save, delete

let connection = database_config.openApplicationDatabase(":memory:")
let service = record_service.newTaskService(connection)
let saved = service.save(record_model.Task(title: "Example", done: false))
doAssert saved.id == 1
doAssert service.all().len == 1
doAssert service.find(saved.id) == saved
var edited = saved
edited.title = "Updated"
discard service.save(edited)
doAssert service.find(saved.id) == edited
service.delete(saved.id)
doAssert service.all().len == 0
try:
  discard service.save(record_model.Task())
  doAssert false, "blank values must fail"
except record_model.TaskValidationError:
  discard
doAssert service.all().len == 0
connection.close()
echo "tasks tests passed"
