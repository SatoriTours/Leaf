use gpui_kit::{AlignItems, FontWeight, Overflow, Styled, px, relative, rgb, rgba};
use std::collections::BTreeMap;

/// Values are validated before committing a snapshot. Apply only owned data.
pub(super) fn apply<E: Styled>(mut element: E, styles: &BTreeMap<String, String>) -> E {
    for (name, value) in styles {
        let number = || value.parse::<f32>().unwrap_or(0.0);
        match name.as_str() {
            "gap" => element = element.gap(px(number())),
            "padding" => element = element.p(px(number())),
            "width" => {
                element = match value.as_str() {
                    "full" => element.w(relative(1.0)),
                    "auto" => element.w_auto(),
                    _ => element.w(px(number())),
                }
            }
            "height" => {
                element = match value.as_str() {
                    "full" => element.h(relative(1.0)),
                    "auto" => element.h_auto(),
                    _ => element.h(px(number())),
                }
            }
            "min_width" => element = element.min_w(px(number())),
            "min_height" => element = element.min_h(px(number())),
            "max_width" => element = element.max_w(px(number())),
            "max_height" => element = element.max_h(px(number())),
            "font_size" => element = element.text_size(px(number())),
            "border_width" => element = element.border(px(number())),
            "radius" => element = element.rounded(px(number())),
            "flex_shrink" => element.style().flex_shrink = Some(number()),
            "flex_grow" => element.style().flex_grow = Some(number()),
            "background" | "color" | "border_color" => {
                let expanded;
                let digits = if value.len() == 4 {
                    expanded = value[1..].chars().flat_map(|c| [c, c]).collect::<String>();
                    expanded.as_str()
                } else {
                    &value[1..]
                };
                let hex = u32::from_str_radix(digits, 16).unwrap_or(0);
                let color = if value.len() == 9 {
                    rgba(hex)
                } else {
                    rgb(hex)
                };
                element = match name.as_str() {
                    "background" => element.bg(color),
                    "color" => element.text_color(color),
                    _ => element.border_color(color),
                };
            }
            "align" => match value.as_str() {
                "start" => element = element.items_start(),
                "end" => element = element.items_end(),
                "center" => element = element.items_center(),
                _ => element.style().align_items = Some(AlignItems::Stretch),
            },
            "justify" => {
                element = match value.as_str() {
                    "center" => element.justify_center(),
                    "end" => element.justify_end(),
                    "between" => element.justify_between(),
                    "around" => element.justify_around(),
                    "evenly" => element.justify_evenly(),
                    _ => element.justify_start(),
                }
            }
            "opacity" => element = element.opacity(number()),
            "weight" => {
                element = element.font_weight(match value.as_str() {
                    "bold" => FontWeight::BOLD,
                    "medium" => FontWeight::MEDIUM,
                    "semibold" => FontWeight::SEMIBOLD,
                    _ => FontWeight::NORMAL,
                })
            }
            "overflow" if value == "hidden" => {
                element.style().overflow.x = Some(Overflow::Hidden);
                element.style().overflow.y = Some(Overflow::Hidden);
            }
            _ => {}
        }
    }
    element
}
