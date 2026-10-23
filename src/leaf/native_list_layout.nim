## Pure list viewport geometry: no platform objects, no Runtime, no second
## scroll authority. The accepted list owns exactly one HeightIndex; the native
## platform projects the same offset onto its scrollbar and lays out only the
## rows the Runtime materialized.
##
## `listVisible` deliberately does not add overscan: the Runtime adds it once
## when it materializes the viewport (`materializeList`), so a second addition
## here would silently widen every viewport.
import std/math
import ./[core, height_index, native_layout, backend]

proc clampListOffset*(total, viewport, requested: float64): float64 =
  ## Finite, non-negative offset clamped into the reachable scroll range.
  ## `total`/`viewport` are caller-owned derived geometry; a non-finite or
  ## negative value is a programming error, not a silent 0.
  if classify(total) in {fcNan, fcInf, fcNegInf} or total < 0.0:
    fail("invalid list total height")
  if classify(viewport) in {fcNan, fcInf, fcNegInf} or viewport < 0.0:
    fail("invalid list viewport height")
  if classify(requested) in {fcNan, fcInf, fcNegInf}:
    fail("invalid list offset")
  clamp(requested, 0.0, max(0.0, total - viewport))

proc listVisible*(heights: HeightIndex, offset, viewport: float64): VisibleRange =
  ## Half-open row range for one viewport. Overscan stays a Runtime concern.
  heights.visible(offset, viewport, overscan = 0)

proc listRowRect*(heights: HeightIndex, binding: NativeRowBinding,
                  viewport: DipRect, offset: float64): DipRect =
  ## Screen rect of one row root inside its list viewport. `y` comes from the
  ## prefix sum of the row's *item* index, never from an active sibling
  ## position, so protected and non-contiguous rows keep their real place.
  if classify(offset) in {fcNan, fcInf, fcNegInf}:
    fail("invalid list offset")
  if classify(viewport.x) in {fcNan, fcInf, fcNegInf} or
      classify(viewport.y) in {fcNan, fcInf, fcNegInf} or
      classify(viewport.width) in {fcNan, fcInf, fcNegInf} or
      classify(viewport.height) in {fcNan, fcInf, fcNegInf}:
    fail("invalid list viewport")
  if viewport.width < 0.0 or viewport.height < 0.0:
    fail("invalid list viewport")
  if binding.itemIndex < 0 or binding.itemIndex >= heights.len:
    fail("row item index is outside the height index")
  let top = heights.prefix(binding.itemIndex)
  result = DipRect(x: viewport.x, y: viewport.y + top - offset,
    width: viewport.width, height: heights.height(binding.itemIndex))
  if classify(result.y) in {fcNan, fcInf, fcNegInf} or
      classify(result.height) in {fcNan, fcInf, fcNegInf}:
    fail("row geometry is not finite")
