use super::*;
use crate::model::ListDescriptor;
use gpui::{
    ListAlignment, ListOffset, ListState, ScrollStrategy, UniformListScrollHandle, list,
    uniform_list,
};
use std::ops::Range;
#[derive(Clone)]
enum Scroll {
    Uniform(UniformListScrollHandle),
    Variable(ListState),
}
pub(super) struct ListSlot {
    descriptor: ListDescriptor,
    scroll: Scroll,
    visible: HashSet<usize>,
    painting: HashSet<usize>,
    scheduled: bool,
    pub(super) frame_failed: bool,
    pub(super) last_failure: Option<Range<usize>>,
    anchor: Option<String>,
}
impl ListSlot {
    fn new(descriptor: &ListDescriptor) -> Self {
        let scroll = if descriptor.row_height > 0.0 {
            Scroll::Uniform(UniformListScrollHandle::new())
        } else {
            Scroll::Variable(
                ListState::new(
                    descriptor.count,
                    ListAlignment::Top,
                    px(descriptor.estimated_height * descriptor.overscan as f32),
                )
                .with_uniform_item_height(px(descriptor.estimated_height)),
            )
        };
        Self {
            descriptor: descriptor.clone(),
            scroll,
            visible: HashSet::new(),
            painting: HashSet::new(),
            scheduled: false,
            frame_failed: false,
            last_failure: None,
            anchor: None,
        }
    }
    fn top(&self) -> ListOffset {
        match &self.scroll {
            Scroll::Variable(state) => state.logical_scroll_top(),
            Scroll::Uniform(handle) => {
                let y: f32 = (-handle.0.borrow().base_handle.offset().y).into();
                let height = self.descriptor.row_height.max(1.0);
                ListOffset {
                    item_ix: (y / height).floor() as usize,
                    offset_in_item: px(y % height),
                }
            }
        }
    }
    fn scroll_to(&self, offset: ListOffset) {
        if self.descriptor.count == 0 {
            return;
        }
        match &self.scroll {
            Scroll::Variable(state) => state.scroll_to(offset),
            Scroll::Uniform(handle) => {
                handle.scroll_to_item_strict(offset.item_ix, ScrollStrategy::Top)
            }
        }
    }
}
impl Desktop {
    pub(super) fn sync_lists(&self) {
        let mut nodes = Vec::new();
        self.snapshot.root.walk(&mut nodes);
        let live: HashSet<&str> = nodes
            .iter()
            .filter(|n| n.list.is_some())
            .map(|n| n.id.as_str())
            .collect();
        self.list_slots
            .borrow_mut()
            .retain(|id, _| live.contains(id.as_str()));
    }
    fn protected_keys(
        &self,
        id: &str,
        window: &Window,
        cx: &Context<Self>,
    ) -> Vec<serde_json::Value> {
        self.inputs
            .values()
            .filter(|slot| slot.state.read(cx).focus_handle(cx).is_focused(window))
            .filter_map(|slot| slot.list_address.as_ref())
            .filter(|a| a.list == id)
            .map(|a| json!({"key":a.key,"index":a.index}))
            .collect()
    }
    pub(super) fn render_virtual_list(&self, node: &Node, cx: &mut Context<Self>) -> AnyElement {
        let descriptor = node.list.as_ref().expect("validated list");
        let scroll = {
            let mut slots = self.list_slots.borrow_mut();
            let slot = slots
                .entry(node.id.clone())
                .or_insert_with(|| ListSlot::new(descriptor));
            if slot.descriptor.row_height != descriptor.row_height {
                *slot = ListSlot::new(descriptor);
            } else if slot.descriptor.generation != descriptor.generation
                || slot.descriptor.count != descriptor.count
            {
                let old = slot.top();
                let index = slot
                    .anchor
                    .as_ref()
                    .and_then(|key| {
                        self.bridge
                            .request(json!({"op":"locate","id":node.id,"key":key}))
                            .ok()
                    })
                    .and_then(|r| r.index)
                    .unwrap_or(old.item_ix.min(descriptor.count.saturating_sub(1)));
                if let Scroll::Variable(state) = &slot.scroll {
                    state.reset_with_uniform_height(
                        descriptor.count,
                        px(descriptor.estimated_height),
                    );
                }
                slot.descriptor = descriptor.clone();
                slot.visible.clear();
                slot.painting.clear();
                slot.last_failure = None;
                slot.scroll_to(ListOffset {
                    item_ix: index,
                    offset_in_item: old.offset_in_item,
                });
            }
            slot.scroll.clone()
        };
        let entity = cx.entity().downgrade();
        let id = node.id.clone();
        let height = descriptor.row_height;
        let content = match scroll {
            Scroll::Uniform(handle) => uniform_list(
                SharedString::from(format!("{id}:virtual")),
                descriptor.count,
                move |range, window, app| {
                    entity
                        .update(app, |view, cx| {
                            view.render_list_range(&id, range, Some(height), window, cx)
                        })
                        .unwrap_or_default()
                },
            )
            .track_scroll(&handle)
            .size_full()
            .into_any_element(),
            Scroll::Variable(state) => list(state, move |index, window, app| {
                entity
                    .update(app, |view, cx| {
                        view.render_list_range(&id, index..index + 1, None, window, cx)
                            .into_iter()
                            .next()
                            .unwrap_or_else(|| div().into_any_element())
                    })
                    .unwrap_or_else(|_| div().into_any_element())
            })
            .size_full()
            .into_any_element(),
        };
        styles::apply(
            div()
                .id(SharedString::from(node.id.clone()))
                .flex()
                .flex_col()
                .min_h_0()
                .min_w_0()
                .overflow_hidden(),
            &node.styles,
        )
        .child(content)
        .into_any_element()
    }
    fn finish_list_frame(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let indices = {
            let mut slots = self.list_slots.borrow_mut();
            let Some(slot) = slots.get_mut(id) else {
                return;
            };
            slot.scheduled = false;
            // ListState is borrowed by GPUI while invoking a row provider. Read or
            // change scroll state only after that layout has completed.
            if slot.frame_failed {
                slot.painting.clear();
                if let Some(first) = slot.visible.iter().min() {
                    slot.scroll_to(ListOffset {
                        item_ix: *first,
                        offset_in_item: px(0.0),
                    });
                }
                return;
            }
            let top = slot.top().item_ix;
            if let Some(row) = self
                .snapshot
                .root
                .find(id)
                .and_then(|list| list.children.iter().find(|row| row.list_index == Some(top)))
            {
                slot.anchor = row.item_key.clone();
            }
            slot.visible = std::mem::take(&mut slot.painting);
            slot.visible.iter().copied().collect::<Vec<_>>()
        };
        let protected_keys = self.protected_keys(id, window, cx);
        self.accept(self.bridge.request(json!({"op":"list","id":id,"first":0,"finish":0,"protected":indices,"protected_keys":protected_keys})));
        self.sync_inputs(window, cx);
    }
    fn render_list_range(
        &mut self,
        id: &str,
        range: Range<usize>,
        height: Option<f32>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let (protected, schedule, failed) = {
            let mut slots = self.list_slots.borrow_mut();
            let slot = slots.get_mut(id).expect("live slot");
            if !slot.scheduled {
                slot.frame_failed = false;
            }
            slot.painting.extend(range.clone());
            let indices = slot
                .visible
                .union(&slot.painting)
                .copied()
                .filter(|i| *i < slot.descriptor.count)
                .collect::<Vec<_>>();
            let schedule = !slot.scheduled;
            slot.scheduled = true;
            (
                indices,
                schedule,
                slot.last_failure.as_ref() == Some(&range),
            )
        };
        if schedule {
            let weak = cx.entity().downgrade();
            let id = id.to_string();
            window.on_next_frame(move |window, app| {
                let _ = weak.update(app, |view, cx| view.finish_list_frame(&id, window, cx));
            });
        }
        let protected_keys = self.protected_keys(id, window, cx);
        let response = if failed {
            None
        } else {
            Some(self.bridge.request(json!({"op":"list","id":id,"first":range.start,"finish":range.end,"protected":protected,"protected_keys":protected_keys})))
        };
        let success = response
            .as_ref()
            .is_some_and(|r| r.as_ref().is_ok_and(|r| r.error.is_none()));
        let mut rows = if let Some(response) = response {
            self.accept(response)
        } else {
            Vec::new()
        };
        if !success {
            if let Some(slot) = self.list_slots.borrow_mut().get_mut(id) {
                slot.frame_failed = true;
                slot.last_failure = Some(range.clone());
            }
            rows = self
                .snapshot
                .root
                .find(id)
                .map(|list| {
                    list.children
                        .iter()
                        .filter(|row| row.list_index.is_some_and(|i| range.contains(&i)))
                        .cloned()
                        .collect()
                })
                .unwrap_or_default();
            if !failed {
                cx.notify();
            }
        } else if let Some(slot) = self.list_slots.borrow_mut().get_mut(id) {
            slot.last_failure = None;
        }
        self.sync_inputs(window, cx);
        rows.iter()
            .map(|node| {
                let row = div().w_full().child(self.render_node(node, cx));
                if let Some(height) = height {
                    row.h(px(height)).overflow_hidden().into_any_element()
                } else {
                    row.into_any_element()
                }
            })
            .collect()
    }
}
