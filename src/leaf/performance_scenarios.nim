## One identity list shared by harnesses, the runner and baseline validation.
const
  RuntimeScenarios* = ["counter_events", "1000_node_cached_subtree",
    "100000_item_scroll_50_visible", "100000_variable_height_updates",
    "stocks_240_candles", "reports_1000_items_10_visible", "chat_1000_items_10_visible"]
  NativeScenarios* = ["ordinary_128_cells_direction",
    "100000_fixed_rows_update", "100000_variable_rows_update"]
