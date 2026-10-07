## Compile-time mapping: public Leaf objects never inherit the Norm state model.
import std/[macros, tables, strutils, sets, sequtils]
import norm/model as normModel
import norm/pragmas
import ../sqlite
import ./[record, metadata, validation, callbacks, persistence]

type Declaration = object
  abstract: bool
  symbol: NimNode
  body: NimNode

var declarations {.compileTime.}: Table[string, Declaration]

proc modelSymbol*(node: NimNode): NimNode {.compileTime.} =
  result = node.getTypeInst
  if result.kind == nnkBracketExpr and result[0].eqIdent("typedesc"): result = result[1]
  if result.kind != nnkSym: error("expected a model type", node)

proc declarationKey(node: NimNode): string {.compileTime.} = node.signatureHash
proc normalized(name: string): string {.compileTime.} = name.replace("_", "").toLowerAscii
proc fieldName(node: NimNode): NimNode {.compileTime.} =
  result = node
  if result.kind == nnkPostfix: result = result[1]
  if result.kind == nnkPragmaExpr: result = result[0]

proc objectNode(symbol: NimNode): NimNode {.compileTime.} =
  result = symbol.getImpl[2]
  if result.kind == nnkRefTy: result = result[0]
  if result.kind != nnkObjectTy: error("model must be a ref object", symbol)

proc modelFieldDefs*(symbol: NimNode): seq[NimNode] {.compileTime.} =
  if symbol == bindSym"Record": return
  let definition = objectNode(symbol)
  for field in definition[2]:
    if field.kind != nnkIdentDefs: error("variant model objects are not supported", field)
    for i in 0..<field.len-2:
      result.add(newIdentDefs(fieldName(field[i]), field[^2], newEmptyNode()))
  if definition[1].kind == nnkOfInherit:
    result.add(modelFieldDefs(definition[1][0]))

proc fieldOwner(symbol, name: NimNode): NimNode {.compileTime.} =
  let definition = objectNode(symbol)
  for field in definition[2]:
    if field.kind == nnkIdentDefs:
      for i in 0..<field.len-2:
        if normalized($fieldName(field[i])) == normalized($name): return symbol
  if definition[1].kind == nnkOfInherit: return fieldOwner(definition[1][0], name)

proc requireConcreteModel*(symbol: NimNode) {.compileTime.} =
  let key = declarationKey(symbol)
  if key notin declarations or declarations[key].abstract:
    error("database operations require a concrete defineModel declaration", symbol)

proc defineDeclaration(symbol: NimNode, body: NimNode, abstract: bool) {.compileTime.} =
  let key = declarationKey(symbol)
  if key in declarations: error("model type is already declared", symbol)
  let definition = objectNode(symbol)
  if symbol.getImpl[2].kind != nnkRefTy:
    error("model must be a ref object", symbol)
  if definition[1].kind != nnkOfInherit: error("model must inherit Record or an abstract model", symbol)
  let parent = definition[1][0]
  if parent != bindSym"Record" and parent != bindSym"TimestampedRecord":
    let parentKey = declarationKey(parent)
    if parentKey notin declarations or not declarations[parentKey].abstract:
      error("a concrete model must inherit a declared abstract model", parent)
  declarations[key] = Declaration(abstract: abstract, symbol: symbol, body: body.copyNimTree)

proc declareRules(symbol, body: NimNode): NimNode {.compileTime.} =
  let parent = objectNode(symbol)[1][0]
  let recordArg = ident"record"
  let phaseArg = ident"phase"
  let eventArg = ident"event"
  let builtinParent = parent == bindSym"Record" or parent == bindSym"TimestampedRecord"
  let parentValidations = if builtinParent: bindSym"runValidations" else: ident"runValidations"
  let parentCallbacks = if builtinParent: bindSym"runCallbacks" else: ident"runCallbacks"
  var validations = newStmtList(newCall(parentValidations, newCall(parent, recordArg)))
  var branches = newNimNode(nnkCaseStmt)
  branches.add(phaseArg)
  var phaseBodies = initTable[string, NimNode]()
  for statement in body:
    if statement.kind notin {nnkCall, nnkCommand} or statement.len < 2:
      error("expected validates, callback or scope declaration", statement)
    let keyword = $statement[0]
    if keyword == "validates":
      if statement[1].kind notin {nnkIdent, nnkSym}: error("validation requires a field name", statement[1])
      let name = $statement[1]
      let field = newDotExpr(recordArg, ident(name))
      for i in 2..<statement.len:
        let rule = statement[i]
        if rule.kind != nnkExprEqExpr: error("expected named validation option", rule)
        case $rule[0]
        of "presence", "finite":
          if not rule[1].eqIdent("true") and not rule[1].eqIdent("false"):
            error("validation flag must be true or false", rule)
          if rule[1].eqIdent("true"):
            let helper = if rule[0].eqIdent("presence"): bindSym"validatePresence" else: bindSym"validateFinite"
            validations.add(newCall(helper, recordArg, newLit(name), field.copyNimTree))
        of "maxLength":
          if rule[1].kind notin {nnkIntLit..nnkUInt64Lit} or rule[1].intVal < 0:
            error("maxLength must be a non-negative integer literal", rule)
          validations.add(newCall(bindSym"validateMaxLength", recordArg, newLit(name), field.copyNimTree, rule[1]))
        else: error("unknown validation rule: " & $rule[0], rule)
    elif keyword == "scope":
      discard # Scope generation is added with the query DSL.
    else:
      if keyword notin ["beforeValidation", "afterValidation", "beforeSave", "afterSave",
          "beforeCreate", "afterCreate", "beforeUpdate", "afterUpdate", "beforeDestroy",
          "afterDestroy", "afterCommit", "afterRollback"]:
        error("unknown model declaration: " & keyword, statement)
      if statement.len != 2: error("callback expects one proc", statement)
      if keyword notin phaseBodies: phaseBodies[keyword] = newStmtList()
      let action = if keyword in ["afterCommit", "afterRollback"]:
        newCall(bindSym"invokeEventCallback", recordArg, eventArg, statement[1])
      else: newCall(bindSym"invokeCallback", recordArg, phaseArg, statement[1])
      phaseBodies[keyword].add(action)
  for keyword in ["beforeValidation", "afterValidation", "beforeSave", "afterSave",
      "beforeCreate", "afterCreate", "beforeUpdate", "afterUpdate", "beforeDestroy",
      "afterDestroy", "afterCommit", "afterRollback"]:
    if keyword in phaseBodies:
      var phaseNode: NimNode
      for phase in bindSym"CallbackPhase".getTypeImpl:
        if phase.kind == nnkSym and $phase == keyword & "Phase": phaseNode = phase
      if phaseNode == nil: error("unknown callback phase", body)
      branches.add(newTree(nnkOfBranch, phaseNode, phaseBodies[keyword]))
  branches.add(newTree(nnkElse, newStmtList(newTree(nnkDiscardStmt, newEmptyNode()))))
  result = quote do:
    proc runValidations*(`recordArg`: `symbol`) =
      `validations`
    proc runCallbacks*(`recordArg`: `symbol`, `phaseArg`: CallbackPhase, `eventArg`: ModelEvent = nil) =
      if `phaseArg`.isBefore:
        `parentCallbacks`(`parent`(`recordArg`), `phaseArg`, `eventArg`)
      `branches`
      if not `phaseArg`.isBefore:
        `parentCallbacks`(`parent`(`recordArg`), `phaseArg`, `eventArg`)

macro defineAbstractModel*(T: typedesc, body: untyped = nil): untyped =
  let symbol = modelSymbol(T)
  let rules = if body.kind == nnkNilLit: newStmtList() else: body
  defineDeclaration(symbol, rules, true)
  result = declareRules(symbol, rules)

macro defineModel*(T: typedesc, table: static[string], body: untyped = nil): untyped =
  let symbol = modelSymbol(T)
  let rules = if body.kind == nnkNilLit: newStmtList() else: body
  if table.len == 0 or '\0' in table or '"' in table:
    error("model table name must not be empty or contain NUL or double quotes", T)
  defineDeclaration(symbol, rules, false)
  let fields = modelFieldDefs(symbol)
  var seen = initHashSet[string]()
  seen.incl("id")
  let storage = genSym(nskType, $symbol & "Storage")
  var recordList = newNimNode(nnkRecList)
  var params = @[symbol, newIdentDefs(ident"modelType", newTree(nnkBracketExpr, ident"typedesc", symbol))]
  var constructor = newTree(nnkObjConstr, symbol)
  var fieldList = newNimNode(nnkBracket)
  var values = newNimNode(nnkBracket)
  var assign = newStmtList()
  var toAssignments = newStmtList()
  var fromAssignments = newStmtList()
  for field in fields:
    let name = field[0]
    let fieldTypeExpr = newCall(bindSym"typeof", newDotExpr(newCall(symbol), name.copyNimTree))
    let key = normalized($name)
    let managed = key in ["createdat", "updatedat"]
    if key in seen: error("duplicate or reserved model field: " & $name, name)
    seen.incl(key)
    # Timestamp fields are reserved except when declared by TimestampedRecord.
    if managed:
      if fieldOwner(symbol, name) != bindSym"TimestampedRecord":
        error("reserved model timestamp field: " & $name, name)
    recordList.add(newIdentDefs(newTree(nnkPostfix, ident"*", ident($name)), field[1].copyNimTree))
    fieldList.add(newCall(bindSym"fieldMetadata", fieldTypeExpr.copyNimTree, newLit($name), newLit(managed)))
    values.add(newTree(nnkTupleConstr, newTree(nnkExprColonExpr, ident"name", newLit($name)),
      newTree(nnkExprColonExpr, ident"value", newCall(bindSym"fieldValue", newDotExpr(ident"record", name)))))
    assign.add(newAssignment(newDotExpr(ident"record", name), newCall(bindSym"fieldFromValue",
      newCall(bindSym"valueFor", ident"values", newLit($name)),
      newCall(bindSym"typeof", newDotExpr(ident"record", name.copyNimTree)))))
    toAssignments.add(newAssignment(newDotExpr(ident"result", name), newDotExpr(ident"record", name)))
    fromAssignments.add(newAssignment(newDotExpr(ident"result", name), newDotExpr(ident"stored", name)))
    if not managed:
      params.add(newIdentDefs(name.copyNimTree, field[1].copyNimTree, newCall(bindSym"default", fieldTypeExpr.copyNimTree)))
      constructor.add(newTree(nnkExprColonExpr, name.copyNimTree, name.copyNimTree))
  fieldList.add(newCall(bindSym"fieldMetadata", newCall(bindSym"typeof", newLit(0'i64)), newLit("id"), newLit(true)))
  values.add(newTree(nnkTupleConstr, newTree(nnkExprColonExpr, ident"name", newLit("id")),
    newTree(nnkExprColonExpr, ident"value", newCall(bindSym"fieldValue", newCall(bindSym"id", ident"record")))))
  let storageType = newTree(nnkTypeSection, newTree(nnkTypeDef,
    newTree(nnkPragmaExpr, storage, newTree(nnkPragma, newTree(nnkExprColonExpr, bindSym"tableName", newLit(table)))),
    newEmptyNode(), newTree(nnkRefTy, newTree(nnkObjectTy, newEmptyNode(),
      newTree(nnkOfInherit, bindSym"Model"), recordList))))
  let tableLit = newLit(table)
  let recordArg = ident"record"
  let valuesArg = ident"values"
  let storedArg = ident"stored"
  result = newStmtList(storageType)
  result.add quote do:
    template storageType*(modelType: typedesc[`symbol`]): typedesc = `storage`
    proc modelTable*(modelType: typedesc[`symbol`]): string = `tableLit`
    proc modelFields*(modelType: typedesc[`symbol`]): seq[FieldMeta] = @`fieldList`
    proc modelValues*(`recordArg`: `symbol`): FieldValues =
      requireRecord(`recordArg`)
      @`values`
    proc assignModelValues*(`recordArg`: `symbol`, `valuesArg`: FieldValues) =
      requireRecord(`recordArg`)
      `assign`
    proc toStorage*(`recordArg`: `symbol`): `storage` =
      requireRecord(`recordArg`)
      result = `storage`()
      `toAssignments`
      result.id = id(`recordArg`)
    proc fromStorage*(modelType: typedesc[`symbol`], `storedArg`: `storage`, db: Database): `symbol` =
      result = `symbol`()
      `fromAssignments`
      markLoaded(result, db, `storedArg`.id, modelValues(result))
  result.add(newProc(newTree(nnkPostfix, ident"*", ident"build"), params,
    newAssignment(ident"result", constructor)))
  result.add(declareRules(symbol, rules))
  for operation in ["create", "createOrRaise"]:
    var creation = newStmtList(newAssignment(ident"result", constructor.copyNimTree))
    if operation == "create": creation.add(newTree(nnkDiscardStmt, newCall(bindSym"save", ident"result")))
    else: creation.add(newCall(bindSym"saveOrRaise", ident"result"))
    result.add(newProc(newTree(nnkPostfix, ident"*", ident(operation)), params.mapIt(it.copyNimTree), creation))

proc assignAndSave(record: NimNode, arguments: NimNode, raising: bool): NimNode {.compileTime.} =
  let symbol = modelSymbol(record)
  requireConcreteModel(symbol)
  let variable = genSym(nskLet, "updatingRecord")
  result = newStmtList(newLetStmt(variable, record), newCall(bindSym"requireRecord", variable))
  var assigned = initHashSet[string]()
  for argument in arguments:
    if argument.kind != nnkExprEqExpr: error("update requires named model fields", argument)
    let key = normalized($argument[0])
    if key in ["id", "createdat", "updatedat"]: error("cannot assign a framework-managed field", argument)
    if key in assigned: error("duplicate update field", argument)
    assigned.incl(key)
    result.add(newAssignment(newDotExpr(variable, argument[0]), argument[1]))
  result.add(newCall(if raising: bindSym"saveOrRaise" else: bindSym"save", variable))

macro update*(record: typed, arguments: varargs[untyped]): untyped = assignAndSave(record, arguments, false)
macro updateOrRaise*(record: typed, arguments: varargs[untyped]): untyped = assignAndSave(record, arguments, true)
