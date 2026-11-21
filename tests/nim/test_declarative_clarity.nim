import std/unittest
import leaf
import ./fixtures/clarity_events as events
import ../../examples/reading_list

type
  Filter = object
    query: string
  Book = object
    filter: Filter
    title: string
  Entry = object
    id: int
    code, title: string

component SearchBox:
  model book: Book
  event onSearch: string
  view:
    textField book.filter.query, key = "query":
      onChange(query):
        onSearch(book.filter.query & ":" & query)

component Editor:
  state:
    book = Book(filter: Filter(query: "initial"), title: "kept")
    notice = ""
  view:
    column:
      searchBox book:
        onSearch(query): notice = query
      textField book.title, key = "title":
        onChange: notice = book.title
      textField value = book.filter.query & "!", key = "controlled":
        onChange(query): notice = query
      button "Set", key = "set":
        book = Book(filter: Filter(query: "program"), title: book.title)
      text notice:
        key: "notice"

component ResultButton:
  prop entry: Entry
  event onSelect: int
  state:
    clicks = 0
  view:
    button entry.title & ":" & $clicks, key = "pick-" & entry.code:
      clicks += 1
      onSelect(entry.id)

component ResultList:
  prop shown: seq[Entry]
  event onSelect: int
  event onClear
  view:
    column:
      list shown, key = "results", rowHeight = 30:
        key = item.code
        text item.title
        resultButton item:
          onSelect(id): onSelect(id)
      button "Clear", key = "clear":
        onClear()

const entries = @[
  Entry(id: 1, code: "a", title: "Almanac"),
  Entry(id: 2, code: "b", title: "Botany")]

proc resultsFor(mode: int): seq[Entry] =
  case mode
  of 1: @[entries[1], Entry(id: 3, code: "a", title: "Revised")]
  of 2: @[entries[0]]
  else: entries

component Results:
  state:
    mode = 0
    selected = 0
    item = "outer"
  view:
    column:
      let shown = resultsFor(mode)
      resultList shown:
        onSelect(id): selected = id
        onClear: selected = 0
      button "Reorder", key = "reorder":
        mode = 1
      button "Filter", key = "filter":
        mode = 2
      text item & ":" & $selected:
        key: "selection"
      list shown, key = "by-id", rowHeight = 30:
        text item.title & ":" & $mode:
          key: "caption-" & $item.id
      list ["first", "second"], key = "by-position", rowHeight = 30:
        text item

component EventContract:
  state:
    marker = 0
    notice = ""
  view:
    column:
      events.picker marker:
        onPick(id): notice = $int(id) & ":" & $marker
      text notice:
        key: "contract-notice"
      text marker:
        key: "contract-marker"

suite "concise declarative components":
  test "imported event contracts keep payload types and allow absent handlers":
    let rt = newRuntime(app(EventContract))
    defer: rt.closeRuntime()
    check rt.dispatch("contract-pick", Event(kind: click))
    check rt.find("contract-notice").node.text == "9:9"
    check rt.dispatch("contract-reset", Event(kind: click))
    check rt.find("contract-marker").node.text == "0"
    check rt.find("contract-notice").node.text == "9:9"

  test "reading list filters and saves only when asked":
    let rt = newRuntime(readingListApp())
    defer: rt.closeRuntime()
    check rt.dispatch("search", Event(kind: change, value: "Ada"))
    check rt.find("notes").children.len == 0
    check rt.dispatch("search", Event(kind: change, value: ""))
    discard rt.materialize("notes", 0, 2)
    check rt.find("title").node.text == "Ada"
    check rt.dispatch("search", Event(kind: change, value: "Nim"))
    expect UiError: discard rt.find("open-1")
    check rt.dispatch("open-2", Event(kind: click))
    check rt.find("title").node.text == "Nim"
    check rt.dispatch("title", Event(kind: change, value: "Nim 📚"))
    check rt.find("note-2").node.text == "Nim"
    check rt.find("status").node.text == ""
    check rt.dispatch("save", Event(kind: click))
    check rt.find("note-2").node.text == "Nim 📚"
    check rt.find("status").node.text == "已保存：Nim 📚"

  test "an explicit key may not repeat":
    component DuplicateCodes:
      view:
        list entries:
          key = "same"
          text item.title
    expect UiError: discard newRuntime(app(DuplicateCodes))
  test "nested model writes preserve siblings and notify with the current draft":
    let rt = newRuntime(app(Editor))
    defer: rt.closeRuntime()
    check rt.find("query").node.text == "initial"
    check rt.dispatch("set", Event(kind: click))
    check rt.find("query").node.text == "program"
    check rt.find("notice").node.text == ""
    check rt.dispatch("query", Event(kind: change, value: "中国📚"))
    check rt.find("notice").node.text == "中国📚:中国📚"
    check rt.find("title").node.text == "kept"
    check rt.dispatch("title", Event(kind: change, value: "new title"))
    check rt.find("notice").node.text == "new title"
    check rt.find("query").node.text == "中国📚"

  test "controlled changes notify but do not write their source":
    let rt = newRuntime(app(Editor))
    defer: rt.closeRuntime()
    check rt.find("controlled").node.text == "initial!"
    check rt.dispatch("controlled", Event(kind: change, value: "typed"))
    check rt.find("notice").node.text == "typed"
    check rt.find("controlled").node.text == "initial!"
    check rt.find("query").node.text == "initial"

  test "host rejection rolls back the field and parent event writes":
    let rt = newRuntime(app(Editor))
    defer: rt.closeRuntime()
    var reject = false
    rt.setValidator(proc(snapshot: Snapshot) =
      if reject: fail("rejected"))
    reject = true
    expect UiError:
      discard rt.dispatch("query", Event(kind: change, value: "draft"))
    check rt.find("query").node.text == "initial"
    check rt.find("notice").node.text == ""
    reject = false
    check rt.dispatch("set", Event(kind: click))
    check rt.find("query").node.text == "program"
    check rt.find("notice").node.text == ""

  test "implicit rows are lazy, use expected identities and emit the current row":
    let rt = newRuntime(app(Results))
    defer: rt.closeRuntime()
    check rt.find("by-id").node.listSource.itemKey(0) == "1"
    check rt.find("by-position").node.listSource.itemKey(1) == "1"
    discard rt.materialize("by-id", 0, 2)
    check rt.find("caption-1").node.text == "Almanac:0"
    # The result list uses an explicit test hook for its virtual viewport.
    check rt.find("results").node.listSource.itemKey(0) == "a"
    check rt.find("results").children.len == 0
    discard rt.materialize("results", 0, 2)
    check rt.find("results").children[0].children.len == 2
    let firstRow = rt.find("results").children[0].id
    check rt.dispatch("pick-a", Event(kind: click))
    check rt.find("selection").node.text == "outer:1"
    check rt.dispatch("reorder", Event(kind: click))
    check rt.find("results").node.listSource.itemKey(0) == "b"
    check rt.find("results").children[1].id == firstRow
    check rt.find("pick-a").node.text == "Revised:1"
    check rt.find("caption-2").node.text == "Botany:1"
    discard rt.materialize("by-id", 0, 2)
    check rt.find("caption-3").node.text == "Revised:1"
    check rt.dispatch("pick-a", Event(kind: click))
    check rt.find("selection").node.text == "outer:3"
    check rt.dispatch("pick-b", Event(kind: click))
    check rt.find("selection").node.text == "outer:2"
    check rt.dispatch("filter", Event(kind: click))
    expect UiError:
      discard rt.find("pick-b")
    check rt.dispatch("pick-a", Event(kind: click))
    check rt.find("selection").node.text == "outer:1"
    check rt.dispatch("clear", Event(kind: click))
    check rt.find("selection").node.text == "outer:0"

  test "duplicate default identities are rejected before mounting rows":
    component Duplicates:
      view:
        list @[entries[0], entries[0]]:
          text item.title
    expect UiError: discard newRuntime(app(Duplicates))

proc query(book: Book): string = book.title
proc query(book: var Book): var string = book.title

static:
  doAssert not compiles(block:
    component ReadOnly:
      prop book: Book
      view: textField book.title)
  doAssert not compiles(block:
    component Computed:
      state: book = Book()
      view: textField book.query)
  doAssert not compiles(block:
    component Reference:
      state: book = (value: new(Book), field: "")
      view: textField book.value.title)
  doAssert not compiles(block:
    component Indexed:
      state: book = @["first"]
      view: textField book[0])
  doAssert not compiles(block:
    component ActiveInView:
      event onSave
      view:
        onSave()
        text "Not allowed")
  doAssert not compiles(block:
    component WrongArity:
      view:
        resultList entries:
          onClear(id): discard id)
  doAssert not compiles(block:
    component Unknown:
      view:
        resultList entries:
          onUnknown: discard)
  doAssert not compiles(block:
    component WrongScope:
      view:
        column:
          list entries:
            text item.title
          text item.title)
