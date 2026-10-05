## Validate the public style vocabulary before GPUI receives a snapshot.
import std/[tables,strutils,math]
import ./core
proc validateStyles*(root:MountedNode) =
  for key,value in root.node.styles:
    case key
    of "gap","padding","min_width","min_height","max_width","max_height","font_size","border_width","radius","flex_grow","flex_shrink","opacity":
      var number:float64
      try:number=parseFloat(value)
      except ValueError:fail("invalid GPUI style number: " & value)
      if classify(number) in {fcNan,fcInf,fcNegInf} or number<0 or number>1_000_000 or (key=="opacity" and number>1):fail("GPUI style number out of bounds")
    of "width","height":
      if value notin ["full","auto"]:
        var number:float64
        try:number=parseFloat(value)
        except ValueError:fail("invalid GPUI dimension")
        if classify(number) in {fcNan,fcInf,fcNegInf} or number<0 or number>1_000_000:fail("GPUI dimension out of bounds")
    of "color","background","border_color":
      if value.len notin [4,7,9] or value[0]!='#':fail("invalid GPUI color")
      for c in value[1..^1]:
        if c notin HexDigits:fail("invalid GPUI color")
    of "align":
      if value notin ["start","end","center","stretch"]:fail("invalid GPUI alignment")
    of "justify":
      if value notin ["start","end","center","between","around","evenly"]:fail("invalid GPUI justification")
    of "weight":
      if value notin ["normal","medium","semibold","bold"]:fail("invalid GPUI font weight")
    of "overflow":
      if value notin ["scroll","hidden","visible"]:fail("invalid GPUI overflow")
    else:fail("unknown GPUI style: " & key)
  for child in root.children:validateStyles(child)
