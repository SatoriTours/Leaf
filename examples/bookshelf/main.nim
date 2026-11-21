import std/strutils
import leaf

type
  Book = object
    id: int
    title, author: string
  Shelf = object
    query: string
    books: array[4, Book]

const sampleBooks = [
  Book(id: 1, title: "设计心理学", author: "唐纳德·诺曼"),
  Book(id: 2, title: "写给大家看的设计书", author: "罗宾·威廉姆斯"),
  Book(id: 3, title: "小王子", author: "安托万·德·圣埃克苏佩里"),
  Book(id: 4, title: "人月神话", author: "弗雷德里克·布鲁克斯")]

proc matchingBooks(shelf: Shelf): seq[Book] =
  for book in shelf.books:
    if shelf.query in book.title: result.add(book)

component Bookshelf:
  state:
    shelf = Shelf(books: sampleBooks)
  view:
    column:
      padding: 24
      gap: 12
      align: "stretch"
      text "我的书架", variant = "primary"
      textField shelf.query, key = "search", placeholder = "搜索书名"
      list shelf.matchingBooks, key = "books", rowHeight = 58,
           styles = style({"height": "full"}):
        column:
          gap: 3
          text item.title
          text item.author, variant = "secondary"

proc bookshelfApp*(theme = matsuLight): Application =
  app(Bookshelf, title = "Leaf · 我的书架", width = 460, height = 380)
    .withNativeTheme(theme)

when isMainModule:
  import std/os
  var args = commandLineParams()
  let dark = args.len > 0 and args[0] == "--dark"
  if dark: args.delete(0)
  quit(run(bookshelfApp(if dark: matsuDark else: matsuLight), args))
