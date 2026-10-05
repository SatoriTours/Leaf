## Shared presentation; state remains in each typed page object.
import std/[strutils, tables]
import leaf
export leaf

const Background* = "#0B1220"
const Surface* = "#131E30"
const Border* = "#263449"
const Ink* = "#E8EEF7"
const Muted* = "#94A3B8"
const Accent* = "#5EEAD4"

proc merged*(base, extra: Styles): Styles =
  result = base
  for k, v in extra: result[k] = v
proc decimal*(cents: int): string = $(cents div 100) & "." & align($(cents mod 100), 2, '0')
proc validEmail*(value: string): bool =
  let parts = value.strip.split('@')
  parts.len == 2 and parts[0].len > 0 and '.' in parts[1] and
    not parts[1].startsWith(".") and not parts[1].endsWith(".") and
    ' ' notin value and '\n' notin value
proc label*(value: string, key = ""): Node = text(value, key, style({"color": Muted, "font_size": "13"}))
proc title*(value: string, key = "", size = 18): Node =
  text(value, key, style({"font_size": $size, "weight": "bold"}))
proc stack*(children: seq[Node], key = "", gap = 12, styles = default(Styles)): Node =
  column(children, key, merged(style({"width": "full", "gap": $gap}), styles))
proc line*(children: seq[Node], key = "", gap = 12, styles = default(Styles)): Node =
  row(children, key, merged(style({"width": "full", "gap": $gap}), styles))
proc card*(children: seq[Node], key = "", styles = default(Styles)): Node =
  stack(children, key, styles = merged(style({"padding": "20", "gap": "16", "background": Surface,
    "border_width": "1", "border_color": Border, "radius": "14"}), styles))
proc page*(heading, description: string, children: seq[Node], height = 850): Node =
  stack(@[stack(@[stack(@[title(heading, size = 28), label(description)], gap = 8)] & children,
    "page_content", 24, style({"min_height": $height}))],
    styles = style({"padding": "32", "height": "full", "min_height": "0", "overflow": "scroll", "color": Ink}))
proc segment*(height: float64, width = "full", color = "", key = "", align = "start"): Node =
  var styles = style({"height": $height, "min_height": $height, "width": width, "justify": align})
  if color.len > 0: styles["background"] = color
  column(@[], key = key, styles = styles)
proc grow*(): Styles = style({"flex_grow": "1", "min_width": "0"})
