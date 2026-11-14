## Managed Skeleton. One ordinary component-owned animation, no private timer.
## A description rather than a Node: compose using hostShell alongside other
## managed descriptions. Reduced motion uses its initial fully opaque sample.
import std/math
import ../[core,component_description,animation,animation_state]
from ../styles import MaxStyleNumber

type SkeletonProps=object
  width,height:float64
  key:string

let SkeletonComponent=defineComponent[SkeletonProps,Animation[float64]]("StandardSkeleton",
  proc(ctx:MountContext,p:SkeletonProps):Animation[float64]=
    newAnimationInternal(ctx,tween(1.0,0.5,1000.ms,easing=easeInOut,
      repeat=pingPong,autoplay=true)),
  proc(ctx:ComponentContext,p:SkeletonProps,pulse:Animation[float64]):UiDescription=
    host(core.ui(NodeKind.tag,key=p.key,
      styles=style({"width": $p.width,"height": $p.height}),
      attributes=style({"ui_role":"skeleton","ui_opacity": $int(round(ctx.value(pulse)*1000))}))))

proc skeleton*(width,height:float64,key=""):UiDescription=
  ## Fixed positive DIP geometry. Pulse approximates CSS easing with the
  ## existing quadratic easeInOut, retaining its two-second 1→.5→1 cycle.
  for size in [width,height]:
    if classify(size) in {fcNan,fcInf,fcNegInf} or size<=0 or size>MaxStyleNumber:
      fail("skeleton requires finite positive dimensions within layout budget")
  component(SkeletonComponent,SkeletonProps(width:width,height:height,key:key),key=key)
