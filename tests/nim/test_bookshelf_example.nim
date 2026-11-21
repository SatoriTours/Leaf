import std/unittest
import leaf
import ../../examples/bookshelf/main

suite "bookshelf example":
  test "entering 设计 filters the titles; clearing it restores the shelf":
    let rt = newRuntime(bookshelfApp())
    defer: rt.closeRuntime()

    proc titles(): seq[string] =
      let count = rt.find("books").node.listSource.len
      discard rt.materialize("books", 0, count)
      for row in rt.find("books").children:
        result.add(row.children[0].children[0].node.text)

    let allBooks = @["设计心理学", "写给大家看的设计书", "小王子", "人月神话"]
    check titles() == allBooks
    check rt.dispatch("search", Event(kind: change, value: "设计"))
    check titles() == @["设计心理学", "写给大家看的设计书"]
    check rt.dispatch("search", Event(kind: change, value: ""))
    check titles() == allBooks
