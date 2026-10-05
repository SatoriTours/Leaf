import std/[unittest, strutils, tables, math]
import leaf
import ../../example/[main, stocks, reports, chat]

proc click(rt: Runtime, key: string) = discard rt.dispatch(key, Event(kind: click))
proc change(rt: Runtime, key, value: string) = discard rt.dispatch(key, Event(kind: change, value: value))
proc checked(rt: Runtime, key: string, value: bool) = discard rt.dispatch(key, Event(kind: change, checked: value))
proc keyed(root: MountedNode, prefix: string): seq[MountedNode] =
  if root.node.key.startsWith(prefix): result.add(root)
  for child in root.children: result.add(keyed(child, prefix))
proc keyed(rt: Runtime, prefix: string): seq[MountedNode] = keyed(rt.snapshot.root, prefix)
proc value(rt: Runtime, key: string): string = rt.find(key).node.text

suite "Seven-page Nim market and report data behavior":
  test "240 candle geometry has a common 200 pixel baseline":
    let rt = newRuntime(galleryApp("stocks"))
    rt.click("stock_window_240")
    check rt.keyed("candle_").len == 240
    var total = 0.0
    for child in rt.find("candle_240").children:
      let height = parseFloat(child.node.styles["height"])
      check height >= 0
      total += height
    check abs(total - 200) < 0.1
  test "stock history remains bounded after batch and reset":
    let rt = newRuntime(galleryApp("stocks"))
    rt.click("stock_batch"); rt.click("stock_window_240")
    check rt.value("stock_frame") == "50"
    check rt.keyed("candle_").len == 240
    check rt.find("candle_290") != nil
    rt.click("stock_tick"); rt.click("stock_reset")
    check rt.value("stock_frame") == "0"
  test "symbols have independent reset price data":
    let rt = newRuntime(galleryApp("stocks"))
    rt.click("stock_symbol_1")
    check rt.value("stock_symbol") == "NOVA / USD"
    rt.click("stock_symbol_2")
    check rt.value("stock_symbol") == "LUMA / USD"
    rt.click("stock_symbol_0")
    check rt.value("stock_symbol") == "Leaf / USD"
  test "full report builds a viewport of 1000 rows and reaches tail":
    let rt = newRuntime(galleryApp("reports"))
    rt.click("report_size_1000"); rt.checked("report_full", true)
    check rt.find("report_rows").node.listSource.len == 1000
    discard rt.materialize("report_rows", 990, 1000)
    check rt.keyed("record_").len == 10
    check rt.stats.mountedNodes < 1000
    check rt.value("report_matches") == "1000"
    check rt.find("report_next").node.disabled
  test "pagination and empty filtering reset range":
    let rt = newRuntime(galleryApp("reports"))
    rt.click("report_next")
    check rt.value("report_range") == "51–100 / 500"
    rt.change("report_search", "不存在")
    check rt.value("report_matches") == "0"
    check rt.value("report_range") == "0–0 / 0"
    check rt.find("report_empty") != nil
  test "paid and refunded totals are integer cents":
    let rt = newRuntime(galleryApp("reports"))
    rt.change("report_search", "ORD-00003")
    check rt.value("report_matches") == "1"
    check rt.value("report_revenue") == "¥103.73"
    check rt.value("report_refunds") == "¥0.00"
    rt.change("report_search", "ORD-00002")
    check rt.value("report_revenue") == "¥0.00"
    check rt.value("report_refunds") == "¥95.82"
  test "report status and sort affect displayed rows":
    let rt = newRuntime(galleryApp("reports"))
    rt.click("report_size_100"); rt.click("report_paid")
    check rt.value("report_matches") == "33"
    let descending = rt.keyed("record_")
    check descending[0].children[4].node.text == "已支付"
    check parseFloat(descending[0].children[3].node.text.replace("¥", "")) > parseFloat(descending[^1].children[3].node.text.replace("¥", ""))
    rt.click("report_sort")
    let ascending = rt.keyed("record_")
    check parseFloat(ascending[0].children[3].node.text.replace("¥", "")) < parseFloat(ascending[^1].children[3].node.text.replace("¥", ""))
  test "refresh clamps a filtered last page when results shrink":
    let rt = newRuntime(galleryApp("reports"))
    rt.click("report_size_1000"); rt.change("report_search", "华"); rt.click("report_pending")
    for i in 0..<5: rt.click("report_next")
    check rt.value("report_range") == "251–251 / 251"
    rt.click("report_refresh")
    check rt.value("report_range") == "201–249 / 249"
    check rt.keyed("record_").len == 49
    check rt.find("report_next").node.disabled
  test "standalone entries start at large data settings":
    let stock = newRuntime(stocksApp())
    check stock.keyed("candle_").len == 240
    let report = newRuntime(reportsApp())
    check report.find("report_rows").node.listSource.len == 1000
    discard report.materialize("report_rows", 0, 10)
    check report.keyed("record_").len == 10

  test "chat ignores whitespace and sends trimmed Chinese on Enter":
    let rt = newRuntime(galleryApp("chat"))
    rt.change("chat_draft", "   ")
    discard rt.dispatch("chat_draft", Event(kind: submit))
    check rt.value("chat_total") == "80"
    rt.change("chat_draft", "  你好，Nim  ")
    discard rt.dispatch("chat_draft", Event(kind: submit))
    check rt.value("chat_total") == "81"
    check rt.value("message_body_1_81") == "你好，Nim"
    check rt.value("chat_draft") == ""
  test "chat retains independent drafts across conversations and pages":
    let rt = newRuntime(galleryApp("chat"))
    rt.change("chat_draft", "第一份草稿"); rt.click("conversation_2")
    rt.change("chat_draft", "第二份草稿"); rt.click("nav_dashboard"); rt.click("nav_chat")
    check rt.value("chat_draft") == "第二份草稿"
    rt.click("conversation_1")
    check rt.value("chat_draft") == "第一份草稿"
  test "chat batch and broadcast preserve pagination and unread counts":
    let rt = newRuntime(galleryApp("chat"))
    rt.click("chat_batch")
    check rt.value("chat_total") == "180"
    check rt.value("chat_rendered") == "50"
    rt.click("chat_broadcast")
    check rt.value("unread_1") == "0"
    check rt.value("unread_2") == "1"
    rt.click("conversation_2")
    check rt.value("unread_2") == "0"
    check rt.value("chat_total") == "21"
  test "chat full source stays bounded and survives unrelated draft edits":
    let rt = newRuntime(galleryApp("chat"))
    rt.click("chat_stress"); rt.checked("chat_full", true); rt.click("chat_incoming")
    let source = rt.find("message_list").node.listSource
    check source.len == 1000
    check rt.value("chat_total") == "1000"
    discard rt.materialize("message_list", 0, 10)
    check rt.keyed("message_body_").len == 10
    check rt.find("message_body_1_1001") != nil
    rt.change("chat_draft", "stable")
    check rt.find("message_list").node.listSource == source
    discard rt.materialize("message_list", 0, 10)
    check rt.find("message_body_1_1001") != nil
  test "chat historical loading preserves earlier position and latest action":
    let rt = newRuntime(galleryApp("chat"))
    rt.click("chat_older"); rt.click("chat_load")
    check rt.value("chat_total") == "280"
    check rt.find("message_body_1_-199") != nil
    check not rt.find("chat_latest").node.disabled
    rt.click("chat_latest")
    check rt.find("message_body_1_80") != nil
    check rt.find("chat_latest").node.disabled
  test "negative message IDs use historical timestamps and Unicode bodies":
    let rt = newRuntime(galleryApp("chat"))
    rt.click("chat_load"); rt.checked("chat_newest", false)
    let rows = rt.find("message_list").children
    check rows[0].node.key == "message_1_-169"
    for i, clock in ["06:11", "06:12", "06:13"]:
      check ("07-15 " & clock) in rows[i].children[0].children[0].node.text
      check rows[i].children[0].children[1].node.text.len > 0
  test "standalone chat starts with a viewport of 1000 messages":
    let rt = newRuntime(chatApp())
    check rt.find("message_list").node.listSource.len == 1000
    discard rt.materialize("message_list", 0, 10)
    check rt.keyed("message_body_").len == 10
