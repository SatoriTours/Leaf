use crate::{abi_v2::*, host_store::HostProps};
use gpui_kit::{AlignItems, FontWeight, Overflow, Styled, px, relative, rgba};
pub fn apply_host_styles<E: Styled>(mut element: E, props: &HostProps) -> E {
    let p = &props.values;
    if p.present & LEAF_P_WIDTH != 0 {
        element = match p.width.tag {
            1 => element.w(px(p.width.value as f32)),
            2 => element.w(relative(1.0)),
            _ => element.w_auto(),
        };
    }
    if p.present & LEAF_P_HEIGHT != 0 {
        element = match p.height.tag {
            1 => element.h(px(p.height.value as f32)),
            2 => element.h(relative(1.0)),
            _ => element.h_auto(),
        };
    }
    if p.present & LEAF_P_GAP != 0 {
        element = element.gap(px(p.numbers[0] as f32));
    }
    if p.present & LEAF_P_PADDING != 0 {
        element = element.p(px(p.numbers[1] as f32));
    }
    if p.present & LEAF_P_FLEX_GROW != 0 {
        element.style().flex_grow = Some(p.numbers[2] as f32);
    }
    if p.present & LEAF_P_FLEX_SHRINK != 0 {
        element.style().flex_shrink = Some(p.numbers[3] as f32);
    }
    if p.present & LEAF_P_MIN_WIDTH != 0 {
        element = element.min_w(px(p.numbers[4] as f32));
    }
    if p.present & LEAF_P_MIN_HEIGHT != 0 {
        element = element.min_h(px(p.numbers[5] as f32));
    }
    if p.present & LEAF_P_MAX_WIDTH != 0 {
        element = element.max_w(px(p.numbers[6] as f32));
    }
    if p.present & LEAF_P_MAX_HEIGHT != 0 {
        element = element.max_h(px(p.numbers[7] as f32));
    }
    if p.present & LEAF_P_RADIUS != 0 {
        element = element.rounded(px(p.numbers[8] as f32));
    }
    if p.present & LEAF_P_BORDER_WIDTH != 0 {
        element = element.border(px(p.numbers[9] as f32));
    }
    if p.present & LEAF_P_OPACITY != 0 {
        element = element.opacity(p.numbers[10] as f32);
    }
    if p.present & LEAF_P_FONT_SIZE != 0 {
        element = element.text_size(px(p.numbers[11] as f32));
    }
    if p.present & LEAF_P_COLOR != 0 {
        element = element.text_color(rgba(p.colors[0]));
    }
    if p.present & LEAF_P_BACKGROUND != 0 {
        element = element.bg(rgba(p.colors[1]));
    }
    if p.present & LEAF_P_BORDER_COLOR != 0 {
        element = element.border_color(rgba(p.colors[2]));
    }
    if p.present & LEAF_P_ALIGN != 0 {
        element.style().align_items = Some(match p.align {
            0 => AlignItems::FlexStart,
            1 => AlignItems::FlexEnd,
            2 => AlignItems::Center,
            _ => AlignItems::Stretch,
        });
    }
    if p.present & LEAF_P_JUSTIFY != 0 {
        element = match p.justify {
            1 => element.justify_end(),
            2 => element.justify_center(),
            3 => element.justify_between(),
            4 => element.justify_around(),
            5 => element.justify_evenly(),
            _ => element.justify_start(),
        };
    }
    if p.present & LEAF_P_WEIGHT != 0 {
        element = element.font_weight(match p.weight {
            1 => FontWeight::MEDIUM,
            2 => FontWeight::SEMIBOLD,
            3 => FontWeight::BOLD,
            _ => FontWeight::NORMAL,
        });
    }
    if p.present & LEAF_P_OVERFLOW != 0 && p.overflow == 1 {
        element.style().overflow.x = Some(Overflow::Hidden);
        element.style().overflow.y = Some(Overflow::Hidden);
    }
    element
}

/// Only pixel-sized roots have a definite external layout. Content-sized and
/// percentage-sized boundaries keep GPUI's normal measurement path.
pub fn boundary_cache_style(props: &HostProps) -> Option<gpui_kit::StyleRefinement> {
    let p = &props.values;
    if p.present & (LEAF_P_WIDTH | LEAF_P_HEIGHT) != (LEAF_P_WIDTH | LEAF_P_HEIGHT)
        || p.width.tag != 1
        || p.height.tag != 1
    {
        return None;
    }
    let mut external = gpui_kit::div()
        .w(px(p.width.value as f32))
        .h(px(p.height.value as f32));
    if p.present & LEAF_P_FLEX_GROW != 0 {
        external.style().flex_grow = Some(p.numbers[2] as f32);
    }
    if p.present & LEAF_P_FLEX_SHRINK != 0 {
        external.style().flex_shrink = Some(p.numbers[3] as f32);
    }
    if p.present & (LEAF_P_MIN_WIDTH | LEAF_P_MAX_WIDTH | LEAF_P_MIN_HEIGHT | LEAF_P_MAX_HEIGHT)
        != 0
    {
        return None;
    }
    Some(external.style().clone())
}
