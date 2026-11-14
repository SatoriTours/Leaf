## Managed Spinner. One ordinary component-owned animation, no private timer.
## A description rather than a Node: compose using hostShell alongside other
## managed descriptions. Reduced motion uses its initial stationary sample (0 deg).
import std/math
import ../[core, component_description, animation, animation_state]

type SpinnerProps = object
  label: string
  key: string

let SpinnerComponent = defineComponent[SpinnerProps, Animation[float64]]("StandardSpinner",
  proc(ctx: MountContext, p: SpinnerProps): Animation[float64] =
    newAnimationInternal(ctx, tween(0.0, 360.0, 1000.ms, easing=linear,
      repeat=forever, autoplay=true)),
  proc(ctx: ComponentContext, p: SpinnerProps, rot: Animation[float64]): UiDescription =
    host(core.ui(NodeKind.tag, text=p.label, key=p.key,
      styles=style({"width": "16", "height": "16"}),
      attributes=style({"ui_role": "spinner", "ui_angle": $int(round(ctx.value(rot)))}))))

proc spinner*(label = "Loading", key = ""): UiDescription =
  ## Fixed 16 DIP square geometry, non-empty accessible name, managed animation loop.
  if label.len == 0: fail("spinner requires non-empty label")
  component(SpinnerComponent, SpinnerProps(label: label, key: key), key=key)
