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
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    ops::Range,
    rc::Rc,
};
actions!(leaf_typed, [Quit]);
#[derive(Clone)]
struct ListAddress {
    list: u64,
    key: String,
    index: usize,
    generation: u64,
    lineage: Vec<u32>,
}
impl ListAddress {
    fn permits_migration_to(&self, next: &Self) -> bool {
        self.list == next.list
            && self.key == next.key
            && self.lineage == next.lineage
            && self.generation != next.generation
    }
}
struct InputSlot {
    binding: Rc<Cell<u64>>,
    identity: String,
    address: Option<ListAddress>,
    state: Entity<InputState>,
    observed: String,
    model: String,
    placeholder: String,
    reset: u64,
    pending_model: bool,
    _subscription: Subscription,
}
#[derive(Clone)]
enum Scroll {
    Uniform(UniformListScrollHandle),
    Variable(ListState),
}
type ViewportSignature = (Range<usize>, Vec<(usize, String)>);
struct ListSlot {
    generation: u64,
    count: usize,
    height: f32,
    estimate: f32,
    scroll: Scroll,
    rows: HashMap<usize, (u64, String)>,
    by_handle: HashMap<u64, (usize, String)>,
    visible: HashSet<usize>,
    painting: HashSet<usize>,
    scheduled: bool,
    placeholders: bool,
    requested: Option<ViewportSignature>,
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
        self.by_handle = rows
            .iter()
            .map(|r| (r.handle, (r.index as usize, r.key.clone())))
            .collect();
        self.rows = rows
            .into_iter()
            .map(|r| (r.index as usize, (r.handle, r.key)))
            .collect();
        true
    }
    fn begin_finish(&mut self, generation: u64) -> bool {
        if generation != self.generation || !self.scheduled {
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
            by_handle: HashMap::new(),
            visible: HashSet::new(),
            painting: HashSet::new(),
            scheduled: false,
            placeholders: false,
            requested: None,
            failed: false,
        }
    }
}
#[derive(Default)]
struct BoundaryCoordinator {
    measure: Cell<bool>,
    task_wake_scheduled: Cell<bool>,
    #[cfg(feature = "native-test-support")]
    viewport_requests: Cell<u64>,
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
    external_error: Option<String>,
    settling: Option<u64>,
    ready_sent: bool,
    task_running: bool,
    frame_start: Option<std::time::Instant>,
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
            external_error: None,
            settling: None,
            ready_sent: false,
            task_running: false,
            frame_start: None,
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
            view.closing = true;
            view.inputs.borrow_mut().clear();
            view.lists.borrow_mut().clear();
            view.boundaries.borrow_mut().clear();
            view.coordinator.views.borrow_mut().clear();
            async {}
        }));
        view.sync_inputs(window, cx);
        if boundary_id == 0 && std::env::var_os("LEAF_WATCH_STATUS").is_some() {
            cx.spawn_in(window, async move |view, cx| {
                loop {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(200))
                        .await;
                    if view
                        .update_in(cx, |view, _, cx| view.poll_watch_status(cx))
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .detach();
        }
        view
    }
    fn arm_tasks(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing || !self.bridge.tasks_pending() {
            return;
        }
        if self.boundary_id != 0 {
            // A child response wakes the window owner after its current update.
            // Boundary views share negotiation metadata, never a second timer.
            if self.coordinator.task_wake_scheduled.replace(true) {
                return;
            }
            let coordinator = self.coordinator.clone();
            window.defer(cx, move |window, app| {
                coordinator.task_wake_scheduled.set(false);
                let root = coordinator.views.borrow().get(&0).cloned();
                if let Some(root) = root {
                    let _ = root.update(app, |view, cx| view.arm_tasks(window, cx));
                }
            });
            return;
        }
        if self.task_running {
            return;
        }
        self.task_running = true;
        cx.spawn_in(window, async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(16))
                    .await;
                let keep = view.update_in(cx, |view, window, cx| {
                    if view.closing || !view.bridge.tasks_pending() {
                        view.task_running = false;
                        return false;
                    }
                    // Copy only revision metadata, ending the HostStore borrow
                    // before Nim can synchronously prepare/apply a new batch.
                    let revision = view.store.borrow().revision();
                    let result = view
                        .bridge
                        .request(&view.bridge.command(LEAF_REQUEST_TASKS));
                    let success = result.is_ok();
                    view.accept(result);
                    if !success || view.store.borrow().revision() != revision {
                        view.sync_inputs(window, cx);
                        view.notify_dirty(cx);
                        cx.notify();
                    }
                    let pending = success && view.bridge.tasks_pending();
                    if !pending {
                        view.task_running = false;
                    }
                    pending
                });
                if !matches!(keep, Ok(true)) {
                    break;
                }
            }
        })
        .detach();
    }
    fn poll_watch_status(&mut self, cx: &mut Context<Self>) {
        if self.closing {
            return;
        }
        let request = self.bridge.command(LEAF_REQUEST_STATUS);
        if let Ok(reply) = self.bridge.request(&request)
            && let Some(message) = reply.external_status
        {
            let next = (!message.is_empty()).then_some(message);
            if self.external_error != next {
                self.external_error = next;
                cx.notify();
            }
        }
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
        if self.cache_enabled
            && let Some(style) = boundary_cache_style(props)
        {
            return entity.cached(style).into_any_element();
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
        self.capture_input_addresses();
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
        self.arm_tasks(window, cx);
        self.settling = Some(handle);
        self.sync_inputs(window, cx);
        self.settling = None;
        self.notify_dirty(cx);
        cx.notify();
    }
    fn input_address(&self, handle: u64) -> Option<ListAddress> {
        let store = self.store.borrow();
        let lists = self.lists.borrow();
        let mut current = handle;
        let mut lineage = Vec::new();
        while let Some(node) = store.node(current) {
            lineage.push(node.kind);
            let parent = store.node(node.parent)?;
            if parent.kind == 11 {
                let known = lists
                    .get(&parent.handle)
                    .filter(|slot| slot.generation == parent.props.values.list_generation)
                    .and_then(|slot| slot.by_handle.get(&current));
                let (index, key) = if let Some((index, key)) = known {
                    (*index, key.clone())
                } else {
                    // Rows are already in HostStore before the next row reply.
                    // Decode only the length-prefixed logical key, never Nim types.
                    let suffix = node.node_id.strip_prefix(&parent.node_id)?;
                    let keyed = suffix
                        .strip_prefix("/item/k:")
                        .or_else(|| suffix.strip_prefix("/k:"))?;
                    let (length, tail) = keyed.split_once(':')?;
                    let length: usize = length.parse().ok()?;
                    let key = tail.get(..length)?;
                    let rest = tail.get(length..)?;
                    if !rest.is_empty() && !rest.starts_with('/') {
                        return None;
                    }
                    (usize::MAX, key.to_owned())
                };
                return Some(ListAddress {
                    list: parent.handle,
                    key,
                    index,
                    generation: parent.props.values.list_generation,
                    lineage,
                });
            }
            current = node.parent;
        }
        None
    }
    fn capture_input_addresses(&self) {
        for (id, slot) in self.inputs.borrow_mut().iter_mut() {
            if let Some(address) = self.input_address(*id) {
                slot.address = Some(address);
            }
        }
    }
    fn sync_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // The window owner subscribes once. Component owners can unmount while
        // a keyed list editor survives source-generation handle replacement.
        if self.boundary_id != 0 {
            return;
        }
        let nodes: Vec<HostNode> = self.store.borrow().input_nodes().cloned().collect();
        let live: HashSet<u64> = nodes.iter().map(|node| node.handle).collect();
        self.capture_input_addresses();
        let mut inputs = self.inputs.borrow_mut();
        let mut retired: HashMap<String, u64> = inputs
            .iter()
            .filter(|(id, slot)| !live.contains(id) && !slot.identity.is_empty())
            .map(|(id, slot)| (slot.identity.clone(), *id))
            .collect();
        for node in nodes {
            let address = self.input_address(node.handle);
            let migratable = retired
                .get(&node.node_id)
                .and_then(|old| inputs.get(old))
                .and_then(|slot| slot.address.as_ref())
                .zip(address.as_ref())
                .is_some_and(|(old, next)| old.permits_migration_to(next));
            if !inputs.contains_key(&node.handle)
                && migratable
                && let Some(old) = retired.remove(&node.node_id)
                && let Some(slot) = inputs.remove(&old)
            {
                slot.binding.set(node.handle);
                inputs.insert(node.handle, slot);
            }
            let reset = node.props.values.reset_token;
            if let Some(slot) = inputs.get_mut(&node.handle) {
                slot.identity = node.node_id.clone();
                if let Some(address) = self.input_address(node.handle) {
                    slot.address = Some(address);
                }
                let force = slot.reset != reset;
                let change = force
                    || slot.pending_model
                    || slot.model != node.props.text
                    || (self.settling == Some(node.handle) && slot.observed != node.props.text);
                if change {
                    let composing = slot.state.update(cx, |input, cx| {
                        gpui::EntityInputHandler::marked_text_range(input, window, cx).is_some()
                    });
                    slot.pending_model = !force && composing;
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
                let binding = Rc::new(Cell::new(id));
                let event_binding = binding.clone();
                let subscription =
                    cx.subscribe_in(&state, window, move |view, input, event, window, cx| {
                        let id = event_binding.get();
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
                        binding,
                        identity: node.node_id.clone(),
                        address: self.input_address(id),
                        state,
                        observed: node.props.text.clone(),
                        model: node.props.text,
                        placeholder: node.props.placeholder,
                        reset,
                        pending_model: false,
                        _subscription: subscription,
                    },
                );
            }
        }
        inputs.retain(|id, slot| {
            if live.contains(id) {
                return true;
            }
            if slot.state.read(cx).focus_handle(cx).is_focused(window) {
                window.blur(cx);
            }
            false
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
        for slot in self.inputs.borrow().values() {
            if slot.state.read(cx).focus_handle(cx).is_focused(window)
                && let Some(address) = &slot.address
                && address.list == list_id
            {
                keys.push((address.index, address.key.clone()));
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
        #[cfg(feature = "native-test-support")]
        self.coordinator
            .viewport_requests
            .set(self.coordinator.viewport_requests.get() + 1);
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
        let (schedule, generation, handles, estimate) = {
            let mut lists = self.lists.borrow_mut();
            let Some(slot) = lists.get_mut(&id) else {
                return Vec::new();
            };
            slot.painting.extend(range.clone());
            let schedule = !slot.scheduled;
            slot.scheduled = true;
            if schedule {
                slot.placeholders = false;
            }
            let handles = range
                .map(|index| slot.rows.get(&index).map(|(handle, _)| *handle))
                .collect::<Vec<_>>();
            slot.placeholders |= handles.iter().any(Option::is_none);
            (schedule, slot.generation, handles, slot.estimate)
        };
        if schedule {
            let weak = cx.entity().downgrade();
            // All providers in this paint contribute before the effect cycle ends.
            // Unlike on_next_frame, defer does not create a frame while idle.
            window.defer(cx, move |window, app| {
                let _ = weak.update(app, |view, cx| view.finish_list(id, generation, window, cx));
            });
        }
        handles
            .into_iter()
            .map(|handle| match handle {
                Some(handle) => {
                    let row = div().w_full().child(self.render_node(handle, cx));
                    if let Some(height) = height {
                        row.h(px(height)).overflow_hidden().into_any_element()
                    } else {
                        row.into_any_element()
                    }
                }
                // Keep estimated geometry until the merged viewport is accepted.
                None => div()
                    .w_full()
                    .h(px(height.unwrap_or(estimate)))
                    .into_any_element(),
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
        let mut protected = self.protected_rows(id, window, cx);
        protected.sort_unstable();
        protected.dedup();
        let (range, missing, scroll) = {
            let mut lists = self.lists.borrow_mut();
            let Some(slot) = lists.get_mut(&id) else {
                return;
            };
            if !slot.begin_finish(generation) {
                return;
            }
            slot.visible = std::mem::take(&mut slot.painting);
            let range = match (slot.visible.iter().min(), slot.visible.iter().max()) {
                (Some(first), Some(last)) => *first..*last + 1,
                _ => 0..0,
            };
            let signature = (range.clone(), protected.clone());
            if slot.requested.as_ref() == Some(&signature) {
                return;
            }
            let missing = range
                .clone()
                .filter(|index| !slot.rows.contains_key(index))
                .collect::<Vec<_>>();
            slot.requested = Some(signature);
            (range, missing, slot.scroll.clone())
        };
        if self.request_rows(id, range, protected, cx) {
            if let Scroll::Variable(state) = scroll
                && let (Some(first), Some(last)) = (missing.first(), missing.last())
            {
                let anchor = state.logical_scroll_top();
                state.splice(*first..*last + 1, last - first + 1);
                state.scroll_to(anchor);
            }
            self.sync_inputs(window, cx);
        }
        self.arm_tasks(window, cx);
        cx.notify();
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
                if let Ok(reply) = self.bridge.request(&request)
                    && reply.bounds[0] >= 0.0
                {
                    top.item_ix = reply.bounds[0] as usize;
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
                slot.rows.clear();
                slot.by_handle.clear();
                slot.scheduled = false;
                slot.placeholders = false;
                slot.requested = None;
                slot.failed = false;
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
                if view.lists.borrow().values().any(|slot| {
                    slot.scheduled
                        || slot.placeholders
                        || slot
                            .visible
                            .iter()
                            .any(|index| !slot.rows.contains_key(index))
                }) {
                    Self::schedule_ready(&cx.entity(), window, frames);
                    return;
                }
                view.ready_sent = true;
                view.sample_rendering(window, LEAF_REQUEST_RENDERING);
                view.accept(
                    view.bridge
                        .request(&view.bridge.command(LEAF_REQUEST_READY)),
                );
                view.arm_tasks(window, cx);
                cx.notify();
                if frames {
                    view.coordinator.measure.set(true);
                    schedule_frame(cx.entity().downgrade(), window);
                }
            });
        });
    }
}
impl Drop for HostView {
    fn drop(&mut self) {
        self.coordinator
            .views
            .borrow_mut()
            .remove(&self.boundary_id);
        self.coordinator
            .renders
            .borrow_mut()
            .remove(&self.boundary_id);
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
        if cfg!(test) || self.coordinator.measure.get() {
            *self
                .coordinator
                .renders
                .borrow_mut()
                .entry(self.boundary_id)
                .or_default() += 1;
        }
        self.arm_tasks(window, cx);
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
                    crate::native_probe::write_host(
                        window,
                        cx,
                        targets.into_iter(),
                        view.coordinator.viewport_requests.get(),
                    );
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
            .when_some(
                self.external_error.clone().or_else(|| self.error.clone()),
                |view, error| {
                    let banner = div()
                        .id("leaf-error")
                        .p(px(12.0))
                        .bg(rgb(0x451a1a))
                        .text_color(rgb(0xfecaca))
                        .child(error);
                    #[cfg(feature = "native-test-support")]
                    let banner = banner.test_support();
                    view.child(banner)
                },
            )
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

fn schedule_frame(weak: WeakEntity<HostView>, window: &Window) {
    window.on_next_frame(move |window, cx| {
        // An explicit draw measures GPUI layout+paint together; presentation
        // and scheduling remain included only in event-to-frame elapsed time.
        let draw_start = std::time::Instant::now();
        window.draw(cx).clear(cx);
        let draw_ms = draw_start.elapsed().as_secs_f64() * 1000.0;
        let _ = weak.update(cx, |view, cx| {
            let elapsed_ms = view
                .frame_start
                .take()
                .map_or(0.0, |start| start.elapsed().as_secs_f64() * 1000.0);
            let (rust_prepare_ms, rust_apply_ms) = view.bridge.take_timings();
            let host_renders = view.coordinator.renders.borrow().values().sum();
            view.coordinator.renders.borrow_mut().clear();
            let sample = LeafFrameSample {
                elapsed_ms,
                draw_ms,
                rust_prepare_ms,
                rust_apply_ms,
                host_renders,
            };
            let mut request = view.bridge.command(LEAF_REQUEST_FRAME);
            request.scale = window.scale_factor() as f64;
            request.width = f32::from(window.viewport_size().width) as f64;
            request.height = f32::from(window.viewport_size().height) as f64;
            request.value = LeafBytes {
                ptr: (&sample as *const LeafFrameSample).cast(),
                len: size_of::<LeafFrameSample>() as u64,
            };
            let start = std::time::Instant::now();
            match view.bridge.request(&request) {
                Ok(reply) if reply.flags & 1 == 0 => {
                    view.frame_start = Some(start);
                    view.notify_dirty(cx);
                    cx.notify();
                    schedule_frame(weak.clone(), window);
                }
                Ok(_) => cx.quit(),
                Err(error) => {
                    eprintln!("leaf GPUI frame: {error}");
                    cx.quit();
                }
            }
        });
    });
}

#[cfg(test)]
#[path = "host_ui_tests.rs"]
mod host_ui_tests;

#[cfg(test)]
mod typed_list_tests {
    use super::*;
    #[test]
    fn editor_migration_requires_new_source_same_list_key_and_host_lineage() {
        let old = ListAddress {
            list: 1,
            key: "中文".into(),
            index: 0,
            generation: 1,
            lineage: vec![4, 0],
        };
        let mut next = old.clone();
        assert!(!old.permits_migration_to(&next));
        next.generation = 2;
        assert!(old.permits_migration_to(&next));
        next.lineage = vec![4, 1];
        assert!(!old.permits_migration_to(&next));
        next.lineage = old.lineage.clone();
        next.list = 2;
        assert!(!old.permits_migration_to(&next));
        next.list = 1;
        next.key = "other".into();
        assert!(!old.permits_migration_to(&next));
    }
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
