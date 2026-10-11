//! Render the accepted, flat host graph directly. ABI 1 keeps its old renderer.
use crate::{
    abi_v2::*,
    bridge_v2::{HostReply, TypedBridge},
    host_store::{DirtyReason, HostNode, HostStore},
    host_styles::{apply_host_styles, boundary_cache_style},
};
use gpui::component::{
    self as component, Disableable,
    button::{Button, ButtonVariants},
    checkbox::Checkbox,
    input::{Input, InputEvent, InputState},
    progress::Progress,
    separator::Separator,
    spinner::Spinner,
    switch::Switch,
    tag::Tag,
};
use gpui::{
    AnyElement, App, Bounds, Context, Entity, Focusable, KeyBinding, ListAlignment, ListOffset,
    ListState, ScrollStrategy, SharedString, Subscription, UniformListScrollHandle, WeakEntity,
    Window, WindowBounds, WindowOptions, actions, div, list, prelude::*, px, rgb, size,
    uniform_list,
};
use gpui_kit as gpui;
#[cfg(feature = "native-test-support")]
use gpui_kit::test::TestSupportExt;
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    ops::Range,
    rc::Rc,
};
actions!(leaf_typed, [Quit]);
struct InputSlot {
    state: Entity<InputState>,
    observed: String,
    model: String,
    placeholder: String,
    reset: u64,
    _subscription: Subscription,
}
#[derive(Clone)]
enum Scroll {
    Uniform(UniformListScrollHandle),
    Variable(ListState),
}
struct ListSlot {
    generation: u64,
    count: usize,
    height: f32,
    estimate: f32,
    scroll: Scroll,
    rows: HashMap<usize, (u64, String)>,
    visible: HashSet<usize>,
    painting: HashSet<usize>,
    scheduled: bool,
    failed: bool,
}
impl ListSlot {
    fn accept_rows(
        &mut self,
        generation: u64,
        current: u64,
        rows: Vec<crate::bridge_v2::HostRow>,
    ) -> bool {
        if generation != current || generation != self.generation {
            return false;
        }
        self.rows = rows
            .into_iter()
            .map(|r| (r.index as usize, (r.handle, r.key)))
            .collect();
        true
    }
    fn begin_finish(&mut self, generation: u64) -> bool {
        if generation != self.generation {
            return false;
        }
        self.scheduled = false;
        true
    }
    fn new(p: &LeafProps) -> Self {
        Self {
            generation: p.list_generation,
            count: p.list_count as usize,
            height: p.row_height as f32,
            estimate: p.estimate as f32,
            scroll: if p.height_mode == 0 {
                Scroll::Uniform(UniformListScrollHandle::new())
            } else {
                Scroll::Variable(
                    ListState::new(
                        p.list_count as usize,
                        ListAlignment::Top,
                        px(p.estimate as f32 * p.overscan as f32),
                    )
                    .with_uniform_item_height(px(p.estimate as f32)),
                )
            },
            rows: HashMap::new(),
            visible: HashSet::new(),
            painting: HashSet::new(),
            scheduled: false,
            failed: false,
        }
    }
}
#[derive(Default)]
struct BoundaryCoordinator {
    views: RefCell<HashMap<u64, WeakEntity<HostView>>>,
    renders: RefCell<HashMap<u64, u64>>,
}
pub struct HostView {
    store: Rc<RefCell<HostStore>>,
    boundary_id: u64,
    bridge: TypedBridge,
    inputs: Rc<RefCell<HashMap<u64, InputSlot>>>,
    lists: Rc<RefCell<HashMap<u64, ListSlot>>>,
    coordinator: Rc<BoundaryCoordinator>,
    boundaries: RefCell<HashMap<u64, Entity<HostView>>>,
    cache_enabled: bool,
    _theme_subscription: Option<Subscription>,
    _quit_subscription: Option<Subscription>,
    error: Option<String>,
    settling: Option<u64>,
    ready_sent: bool,
    closing: bool,
    _bounds_subscription: Option<Subscription>,
}
impl HostView {
    pub fn new(store: Rc<RefCell<HostStore>>, boundary_id: u64, bridge: TypedBridge) -> Self {
        Self {
            store,
            boundary_id,
            bridge,
            inputs: Rc::new(RefCell::new(HashMap::new())),
            lists: Rc::new(RefCell::new(HashMap::new())),
            coordinator: Rc::new(BoundaryCoordinator::default()),
            boundaries: RefCell::new(HashMap::new()),
            cache_enabled: std::env::var("LEAF_GPUI_CACHE").as_deref() != Ok("0"),
            _theme_subscription: None,
            _quit_subscription: None,
            error: None,
            settling: None,
            ready_sent: false,
            closing: false,
            _bounds_subscription: None,
        }
    }
    fn new_window(
        store: Rc<RefCell<HostStore>>,
        boundary_id: u64,
        bridge: TypedBridge,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut view = Self::new(store, boundary_id, bridge);
        view._bounds_subscription = Some(cx.observe_window_bounds(window, |view, window, cx| {
            view.sample_rendering(window, LEAF_REQUEST_RENDERING);
            view.refresh_boundaries(DirtyReason::ExternalLayout, cx);
        }));
        view._theme_subscription = Some(cx.observe_global::<component::Theme>(|view, cx| {
            view.refresh_boundaries(DirtyReason::InheritedStyle, cx)
        }));
        view._quit_subscription = Some(cx.on_app_quit(|view, _| {
            view.inputs.borrow_mut().clear();
            view.lists.borrow_mut().clear();
            view.boundaries.borrow_mut().clear();
            view.coordinator.views.borrow_mut().clear();
            async {}
        }));
        view.sync_inputs(window, cx);
        view
    }
    fn boundary_element(
        &self,
        id: u64,
        props: &crate::host_store::HostProps,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let entity = {
            let mut boundaries = self.boundaries.borrow_mut();
            boundaries
                .entry(id)
                .or_insert_with(|| {
                    let store = self.store.clone();
                    let bridge = self.bridge.clone();
                    let inputs = self.inputs.clone();
                    let lists = self.lists.clone();
                    let coordinator = self.coordinator.clone();
                    let cache_enabled = self.cache_enabled;
                    cx.new(|cx| {
                        let mut view = HostView::new(store, id, bridge);
                        view.inputs = inputs;
                        view.lists = lists;
                        view.coordinator = coordinator;
                        view.cache_enabled = cache_enabled;
                        view.coordinator
                            .views
                            .borrow_mut()
                            .insert(id, cx.entity().downgrade());
                        view
                    })
                })
                .clone()
        };
        if self.cache_enabled {
            if let Some(style) = boundary_cache_style(props) {
                return entity.cached(style).into_any_element();
            }
        }
        entity.into_any_element()
    }
    fn notify_dirty(&self, cx: &mut Context<Self>) {
        let dirty = self.store.borrow_mut().take_dirty_boundaries();
        if dirty.is_empty() {
            return;
        }
        let mut views = Vec::new();
        let registry = self.coordinator.views.borrow();
        for id in dirty.into_iter().chain(std::iter::once(0)) {
            if id == self.boundary_id {
                cx.notify();
                continue;
            }
            if let Some(view) = registry.get(&id) {
                views.push(view.clone());
            }
        }
        drop(registry);
        for view in views {
            let _ = view.update(cx, |_, cx| cx.notify());
        }
    }
    fn refresh_boundaries(&self, reason: DirtyReason, cx: &mut Context<Self>) {
        self.store.borrow_mut().invalidate_all(reason);
        self.notify_dirty(cx);
        cx.notify();
    }
    #[cfg(test)]
    fn boundary_renders(&self, id: u64) -> u64 {
        *self.coordinator.renders.borrow().get(&id).unwrap_or(&0)
    }
    fn accept(
        &mut self,
        result: Result<HostReply, crate::bridge_v2::BridgeError>,
    ) -> Vec<crate::bridge_v2::HostRow> {
        match result {
            Ok(reply) => {
                if let Some(message) = &reply.scope_error {
                    eprintln!("leaf GPUI: {message}");
                }
                self.error = reply.scope_error;
                reply.rows
            }
            Err(e) => {
                eprintln!("leaf GPUI: {}", e.message);
                self.error = Some(e.message);
                Vec::new()
            }
        }
    }
    fn sample_rendering(&self, window: &Window, tag: u64) {
        let mut request = self.bridge.command(tag);
        let bounds = window.viewport_size();
        request.scale = window.scale_factor() as f64;
        request.width = f32::from(bounds.width) as f64;
        request.height = f32::from(bounds.height) as f64;
        let _ = self.bridge.request(&request);
    }
    fn dispatch(
        &mut self,
        handle: u64,
        kind: u32,
        value: &str,
        checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (enabled, mask, revision) = {
            let store = self.store.borrow();
            let Some(node) = store.node(handle) else {
                return;
            };
            (
                node.props.values.present & LEAF_P_ENABLED == 0 || node.props.values.enabled != 0,
                node.props.values.event_mask,
                store.revision(),
            )
        };
        if !enabled || mask & (1 << kind) == 0 {
            return;
        }
        let mut request = self.bridge.command(LEAF_REQUEST_EVENT);
        request.handle = handle;
        request.kind = kind;
        request.value = LeafBytes {
            ptr: value.as_ptr(),
            len: value.len() as u64,
        };
        request.checked = u32::from(checked);
        request.generation = 1;
        request.binding_generation = 1;
        request.revision = revision;
        request.sequence = self.bridge.next_sequence();
        self.accept(self.bridge.request(&request));
        self.settling = Some(handle);
        self.sync_inputs(window, cx);
        self.settling = None;
        self.notify_dirty(cx);
        cx.notify();
    }
    fn sync_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let nodes: Vec<HostNode> = self.store.borrow().input_nodes().cloned().collect();
        let live: HashSet<u64> = nodes.iter().map(|node| node.handle).collect();
        let mut inputs = self.inputs.borrow_mut();
        for node in nodes {
            let reset = node.props.values.reset_token;
            if let Some(slot) = inputs.get_mut(&node.handle) {
                let force = slot.reset != reset;
                let change = force
                    || slot.model != node.props.text
                    || (self.settling == Some(node.handle) && slot.observed != node.props.text);
                if change {
                    let composing = slot.state.update(cx, |input, cx| {
                        gpui::EntityInputHandler::marked_text_range(input, window, cx).is_some()
                    });
                    if force || !composing {
                        slot.observed = node.props.text.clone();
                        slot.state.update(cx, |input, cx| {
                            input.set_value(node.props.text.clone(), window, cx)
                        });
                    }
                }
                slot.model = node.props.text;
                if slot.placeholder != node.props.placeholder {
                    slot.placeholder = node.props.placeholder.clone();
                    slot.state.update(cx, |input, cx| {
                        input.set_placeholder(node.props.placeholder, window, cx)
                    });
                }
                slot.reset = reset;
            } else {
                let state = cx.new(|cx| {
                    let mut input =
                        InputState::new(window, cx).placeholder(node.props.placeholder.clone());
                    input.set_value(node.props.text.clone(), window, cx);
                    input
                });
                let id = node.handle;
                let subscription =
                    cx.subscribe_in(&state, window, move |view, input, event, window, cx| {
                        let text = input.read(cx).value().to_string();
                        let mut inputs = view.inputs.borrow_mut();
                        let Some(slot) = inputs.get_mut(&id) else {
                            return;
                        };
                        let kind = match event {
                            InputEvent::Change => {
                                if slot.observed == text {
                                    return;
                                }
                                slot.observed = text.clone();
                                1
                            }
                            InputEvent::PressEnter { .. } => 2,
                            _ => return,
                        };
                        drop(inputs);
                        view.dispatch(id, kind, &text, false, window, cx);
                    });
                inputs.insert(
                    id,
                    InputSlot {
                        state,
                        observed: node.props.text.clone(),
                        model: node.props.text,
                        placeholder: node.props.placeholder,
                        reset,
                        _subscription: subscription,
                    },
                );
            }
        }
        inputs.retain(|id, slot| {
            live.contains(id) || slot.state.read(cx).focus_handle(cx).is_focused(window)
        });
        let live_lists: HashSet<u64> = self.store.borrow().list_nodes().map(|n| n.handle).collect();
        self.lists
            .borrow_mut()
            .retain(|id, _| live_lists.contains(id));
    }
    fn protected_rows(
        &self,
        list_id: u64,
        window: &Window,
        cx: &Context<Self>,
    ) -> Vec<(usize, String)> {
        let mut keys = Vec::new();
        let store = self.store.borrow();
        let slots = self.lists.borrow();
        let Some(list) = slots.get(&list_id) else {
            return keys;
        };
        for (id, slot) in self.inputs.borrow().iter() {
            if !slot.state.read(cx).focus_handle(cx).is_focused(window) {
                continue;
            }
            let mut current = *id;
            while let Some(node) = store.node(current) {
                if node.parent == list_id {
                    if let Some((index, (_, key))) =
                        list.rows.iter().find(|(_, (handle, _))| *handle == current)
                    {
                        keys.push((*index, key.clone()));
                    }
                    break;
                }
                if node.parent == 0 {
                    break;
                }
                current = node.parent;
            }
        }
        keys
    }
    fn request_rows(
        &mut self,
        id: u64,
        range: Range<usize>,
        protected: Vec<(usize, String)>,
        cx: &mut Context<Self>,
    ) -> bool {
        let generation = {
            let store = self.store.borrow();
            let Some(node) = store.node(id) else {
                return false;
            };
            node.props.values.list_generation
        };
        let rows: Vec<LeafProtected> = protected
            .iter()
            .map(|(index, key)| LeafProtected {
                index: *index as u64,
                key: LeafBytes {
                    ptr: key.as_ptr(),
                    len: key.len() as u64,
                },
            })
            .collect();
        let mut request = self.bridge.command(LEAF_REQUEST_VIEWPORT);
        request.handle = id;
        request.generation = generation;
        request.first = range.start as u64;
        request.finish = range.end as u64;
        request.protected_rows = rows.as_ptr();
        request.protected_len = rows.len() as u64;
        let result = self.bridge.request(&request);
        let mut success = result.is_ok();
        let rows = self.accept(result);
        self.notify_dirty(cx);
        let current = self
            .store
            .borrow()
            .node(id)
            .map(|n| n.props.values.list_generation)
            .unwrap_or(0);
        if let Some(slot) = self.lists.borrow_mut().get_mut(&id) {
            if success {
                success = slot.accept_rows(generation, current, rows);
            }
            slot.failed = !success;
        }
        success
    }
    fn render_range(
        &mut self,
        id: u64,
        range: Range<usize>,
        height: Option<f32>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let (schedule, mut protected, generation) = {
            let mut lists = self.lists.borrow_mut();
            let Some(slot) = lists.get_mut(&id) else {
                return Vec::new();
            };
            slot.painting.extend(range.clone());
            let schedule = !slot.scheduled;
            slot.scheduled = true;
            let keys = slot
                .visible
                .union(&slot.painting)
                .filter_map(|index| slot.rows.get(index).map(|(_, key)| (*index, key.clone())))
                .collect::<Vec<_>>();
            (schedule, keys, slot.generation)
        };
        protected.extend(self.protected_rows(id, window, cx));
        self.request_rows(id, range.clone(), protected, cx);
        self.sync_inputs(window, cx);
        if schedule {
            let weak = cx.entity().downgrade();
            window.on_next_frame(move |window, app| {
                let _ = weak.update(app, |view, cx| view.finish_list(id, generation, window, cx));
            });
        }
        let handles = {
            let lists = self.lists.borrow();
            let Some(slot) = lists.get(&id) else {
                return Vec::new();
            };
            range
                .filter_map(|index| slot.rows.get(&index).map(|(id, _)| *id))
                .collect::<Vec<_>>()
        };
        handles
            .into_iter()
            .map(|handle| {
                let row = div().w_full().child(self.render_node(handle, cx));
                if let Some(height) = height {
                    row.h(px(height)).overflow_hidden().into_any_element()
                } else {
                    row.into_any_element()
                }
            })
            .collect()
    }
    fn finish_list(
        &mut self,
        id: u64,
        generation: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut protected = {
            let mut lists = self.lists.borrow_mut();
            let Some(slot) = lists.get_mut(&id) else {
                return;
            };
            if !slot.begin_finish(generation) {
                return;
            }
            if slot.failed {
                slot.painting.clear();
                return;
            }
            slot.visible = std::mem::take(&mut slot.painting);
            slot.visible
                .iter()
                .filter_map(|index| slot.rows.get(index).map(|(_, key)| (*index, key.clone())))
                .collect::<Vec<_>>()
        };
        protected.extend(self.protected_rows(id, window, cx));
        self.request_rows(id, 0..0, protected, cx);
        self.sync_inputs(window, cx);
    }
    fn render_list(&self, node: &HostNode, cx: &mut Context<Self>) -> AnyElement {
        let p = &node.props.values;
        // Capture scroll metadata, release the slot borrow, then cross FFI.
        let migration = {
            let lists = self.lists.borrow();
            lists.get(&node.handle).and_then(|slot| {
                if slot.generation == p.list_generation && slot.count == p.list_count as usize {
                    return None;
                }
                let top = match &slot.scroll {
                    Scroll::Variable(state) => state.logical_scroll_top(),
                    Scroll::Uniform(handle) => {
                        let y = f32::from(-handle.0.borrow().base_handle.offset().y);
                        ListOffset {
                            item_ix: (y / slot.height.max(1.0)).floor() as usize,
                            offset_in_item: px(y % slot.height.max(1.0)),
                        }
                    }
                };
                Some((top, slot.rows.get(&top.item_ix).map(|(_, key)| key.clone())))
            })
        };
        let restored = migration.map(|(mut top, key)| {
            if let Some(key) = key {
                let mut request = self.bridge.command(LEAF_REQUEST_LOCATE);
                request.handle = node.handle;
                request.value = LeafBytes {
                    ptr: key.as_ptr(),
                    len: key.len() as u64,
                };
                if let Ok(reply) = self.bridge.request(&request) {
                    if reply.bounds[0] >= 0.0 {
                        top.item_ix = reply.bounds[0] as usize;
                    }
                }
            }
            top.item_ix = top.item_ix.min((p.list_count as usize).saturating_sub(1));
            top
        });
        let scroll = {
            let mut lists = self.lists.borrow_mut();
            let slot = lists.entry(node.handle).or_insert_with(|| ListSlot::new(p));
            if slot.height != p.row_height as f32 || slot.estimate != p.estimate as f32 {
                let rows = std::mem::take(&mut slot.rows);
                *slot = ListSlot::new(p);
                slot.rows = rows;
            }
            if let Some(top) = restored {
                if let Scroll::Variable(state) = &slot.scroll {
                    state.reset_with_uniform_height(p.list_count as usize, px(p.estimate as f32));
                }
                match &slot.scroll {
                    Scroll::Variable(state) => state.scroll_to(top),
                    Scroll::Uniform(handle) => {
                        handle.scroll_to_item_strict(top.item_ix, ScrollStrategy::Top)
                    }
                }
                slot.generation = p.list_generation;
                slot.count = p.list_count as usize;
                slot.visible.clear();
                slot.painting.clear();
            }
            slot.scroll.clone()
        };
        let id = node.handle;
        let view = cx.entity().downgrade();
        let height = p.row_height as f32;
        let content = match scroll {
            Scroll::Uniform(handle) => uniform_list(
                SharedString::from(format!("host-{id}-list")),
                p.list_count as usize,
                move |range, window, app| {
                    view.update(app, |view, cx| {
                        view.render_range(id, range, Some(height), window, cx)
                    })
                    .unwrap_or_default()
                },
            )
            .track_scroll(&handle)
            .size_full()
            .into_any_element(),
            Scroll::Variable(state) => list(state, move |index, window, app| {
                view.update(app, |view, cx| {
                    view.render_range(id, index..index + 1, None, window, cx)
                        .into_iter()
                        .next()
                        .unwrap_or_else(|| div().into_any_element())
                })
                .unwrap_or_else(|_| div().into_any_element())
            })
            .size_full()
            .into_any_element(),
        };
        apply_host_styles(
            div()
                .id(SharedString::from(format!("host-{id}")))
                .flex()
                .flex_col()
                .min_h_0()
                .min_w_0()
                .overflow_hidden(),
            &node.props,
        )
        .child(content)
        .into_any_element()
    }
    fn render_node(&self, handle: u64, cx: &mut Context<Self>) -> AnyElement {
        let node = {
            let store = self.store.borrow();
            store.node(handle).cloned()
        };
        let Some(node) = node else {
            return div().into_any_element();
        };
        let boundary = self.store.borrow().child_boundary(handle, self.boundary_id);
        if let Some(boundary) = boundary {
            return self.boundary_element(boundary, &node.props, cx);
        }
        let id = SharedString::from(format!("host-{handle}"));
        let p = &node.props;
        let disabled = p.values.present & LEAF_P_ENABLED != 0 && p.values.enabled == 0;
        match node.kind {
            0 | 1 => {
                let mut layout = div().id(id).flex().min_w_0().min_h_0();
                if node.kind == 0 {
                    layout = layout.flex_col();
                }
                if p.values.present & LEAF_P_OVERFLOW != 0 && p.values.overflow == 0 {
                    layout = layout.overflow_y_scroll();
                }
                apply_host_styles(layout, p)
                    .children(
                        node.children
                            .iter()
                            .map(|child| self.render_node(*child, cx)),
                    )
                    .into_any_element()
            }
            2 => apply_host_styles(div().id(id).child(p.text.clone()), p).into_any_element(),
            3 => {
                let button = Button::new(id)
                    .label(p.text.clone())
                    .disabled(disabled)
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.dispatch(handle, 0, "", false, window, cx)
                    }));
                let button = match p.values.variant {
                    1 => button.primary(),
                    2 => button.danger(),
                    6 => button.outline(),
                    7 => button.ghost(),
                    _ => button,
                };
                apply_host_styles(button, p).into_any_element()
            }
            4 => self.inputs.borrow().get(&handle).map_or_else(
                || div().into_any_element(),
                |slot| {
                    {
                        let widget = div()
                            .id(id)
                            .min_w_0()
                            .child(Input::new(&slot.state).disabled(disabled));
                        #[cfg(feature = "native-test-support")]
                        let widget = widget.test_support();
                        apply_host_styles(widget, p)
                    }
                    .into_any_element()
                },
            ),
            5 => {
                let view = cx.entity().downgrade();
                let widget = Checkbox::new(id)
                    .label(p.text.clone())
                    .checked(p.values.checked == 1)
                    .disabled(disabled)
                    .on_change(move |checked, window, cx| {
                        let _ = view.update(cx, |view, cx| {
                            view.dispatch(
                                handle,
                                1,
                                if *checked { "true" } else { "false" },
                                *checked,
                                window,
                                cx,
                            )
                        });
                    });
                apply_host_styles(widget, p).into_any_element()
            }
            6 => {
                let view = cx.entity().downgrade();
                let widget = Switch::new(id)
                    .label(p.text.clone())
                    .checked(p.values.checked == 1)
                    .disabled(disabled)
                    .on_change(move |checked, window, cx| {
                        let _ = view.update(cx, |view, cx| {
                            view.dispatch(
                                handle,
                                1,
                                if *checked { "true" } else { "false" },
                                *checked,
                                window,
                                cx,
                            )
                        });
                    });
                apply_host_styles(widget, p).into_any_element()
            }
            7 => apply_host_styles(Progress::new(id).value(p.values.numbers[12] as f32), p)
                .into_any_element(),
            8 => {
                let tag = match p.values.variant {
                    1 => Tag::primary(),
                    2 => Tag::danger(),
                    3 => Tag::success(),
                    4 => Tag::warning(),
                    5 => Tag::info(),
                    _ => Tag::secondary(),
                };
                apply_host_styles(div().id(id).child(tag.child(p.text.clone())), p)
                    .into_any_element()
            }
            9 => {
                apply_host_styles(div().id(id).child(Separator::horizontal()), p).into_any_element()
            }
            10 => apply_host_styles(div().id(id).child(Spinner::new()), p).into_any_element(),
            11 => self.render_list(&node, cx),
            _ => div().into_any_element(),
        }
    }
    fn schedule_ready(view: &Entity<Self>, window: &Window, frames: bool) {
        let view = view.downgrade();
        window.on_next_frame(move |window, cx| {
            let _ = view.update(cx, |view, cx| {
                if view.ready_sent {
                    return;
                }
                if view.error.is_some() || view.lists.borrow().values().any(|slot| slot.failed) {
                    if std::env::var_os("LEAF_WATCH_READY").is_some() {
                        cx.quit();
                    }
                    return;
                }
                view.ready_sent = true;
                view.sample_rendering(window, LEAF_REQUEST_RENDERING);
                view.accept(
                    view.bridge
                        .request(&view.bridge.command(LEAF_REQUEST_READY)),
                );
                cx.notify();
                if frames {
                    view.sample_rendering(window, LEAF_REQUEST_FRAME);
                }
            });
        });
    }
}
impl Render for HostView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.closing {
            return div().into_any_element();
        }
        self.coordinator
            .views
            .borrow_mut()
            .insert(self.boundary_id, cx.entity().downgrade());
        *self
            .coordinator
            .renders
            .borrow_mut()
            .entry(self.boundary_id)
            .or_default() += 1;
        self.notify_dirty(cx);
        self.boundaries
            .borrow_mut()
            .retain(|id, _| self.store.borrow().boundary(*id).is_some());
        self.sync_inputs(window, cx);
        let root = {
            let store = self.store.borrow();
            if self.boundary_id == 0 {
                store.root()
            } else {
                store
                    .boundary(self.boundary_id)
                    .map_or(0, |b| b.root_handle)
            }
        };
        if self.boundary_id != 0 {
            return self.render_node(root, cx);
        }
        #[cfg(feature = "native-test-support")]
        if std::env::var_os("LEAF_TEST_GEOMETRY").is_some() {
            let weak = cx.entity().downgrade();
            window.on_next_frame(move |window, app| {
                let _ = weak.update(app, |view, cx| {
                    let targets = view
                        .store
                        .borrow()
                        .nodes()
                        .map(|n| (n.node_id.clone(), format!("host-{}", n.handle)))
                        .collect::<Vec<_>>();
                    crate::native_probe::write(window, cx, targets.into_iter());
                });
            });
        }
        div()
            .id("leaf-window")
            .on_action(cx.listener(|view, _: &Quit, window, cx| {
                cx.stop_propagation();
                view.closing = true;
                view.inputs.borrow_mut().clear();
                view.lists.borrow_mut().clear();
                view.boundaries.borrow_mut().clear();
                view.coordinator.views.borrow_mut().clear();
                window.blur(cx);
                window.on_next_frame(|window, cx| {
                    // Retire the platform IME handler after the current key
                    // dispatch has returned; the active window is borrowed then.
                    window.draw(cx).clear(cx);
                    window.remove_window();
                    cx.defer(|cx| cx.quit());
                });
                cx.notify();
            }))
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(0x111827))
            .text_color(rgb(0xe5e7eb))
            .text_size(px(15.0))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .overflow_hidden()
                    .child(self.render_node(root, cx)),
            )
            .when_some(self.error.clone(), |view, error| {
                view.child(
                    div()
                        .id("leaf-error")
                        .p(px(12.0))
                        .bg(rgb(0x451a1a))
                        .text_color(rgb(0xfecaca))
                        .child(error),
                )
            })
            .into_any_element()
    }
}
pub fn run(store: Rc<RefCell<HostStore>>, bridge: TypedBridge, frames: bool) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    if std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return Err("no graphical session; use --check / --headless".into());
    }
    let window = store
        .borrow()
        .window()
        .cloned()
        .ok_or("missing host window metadata")?;
    let failure = Rc::new(RefCell::new(None));
    let startup_error = failure.clone();
    gpui::application()
        .with_assets(gpui::assets::Assets)
        .run(move |cx: &mut App| {
            gpui::init(cx);
            component::Theme::change(component::ThemeMode::Dark, None, cx);
            cx.bind_keys([
                KeyBinding::new("ctrl-q", Quit, None),
                KeyBinding::new("cmd-q", Quit, None),
            ]);
            cx.on_action(|_: &Quit, cx| cx.quit());
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            let options = WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(window.width as f32), px(window.height as f32)),
                    cx,
                ))),
                ..Default::default()
            };
            match gpui::open_window(options, cx, |native, cx| {
                native.set_window_title(&window.title);
                let entity = cx.new(|cx| HostView::new_window(store, 0, bridge, native, cx));
                HostView::schedule_ready(&entity, native, frames);
                entity
            }) {
                Ok(_) => cx.activate(true),
                Err(e) => {
                    *failure.borrow_mut() = Some(e.to_string());
                    cx.quit();
                }
            }
        });
    let result = startup_error.borrow_mut().take();
    match result {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[cfg(test)]
#[path = "host_ui_tests.rs"]
mod host_ui_tests;

#[cfg(test)]
mod typed_list_tests {
    use super::*;
    #[test]
    fn obsolete_rows_and_frame_cannot_replace_new_source() {
        let props = LeafProps {
            list_generation: 2,
            list_count: 100,
            height_mode: 0,
            row_height: 24.0,
            ..Default::default()
        };
        let mut slot = ListSlot::new(&props);
        slot.rows.insert(9, (90, "accepted".into()));
        assert!(!slot.accept_rows(1, 2, vec![]));
        assert_eq!(slot.rows[&9].1, "accepted");
        slot.scheduled = true;
        assert!(!slot.begin_finish(1));
        assert!(slot.scheduled);
        assert!(slot.accept_rows(
            2,
            2,
            vec![crate::bridge_v2::HostRow {
                handle: 10,
                index: 1,
                key: "new".into()
            }]
        ));
        assert_eq!(slot.rows[&1].1, "new");
    }
}
