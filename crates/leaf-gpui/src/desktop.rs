use gpui_kit as gpui;
#[path = "lists.rs"]
mod lists;
#[path = "styles.rs"]
mod styles;
use crate::{
    bridge::Bridge,
    model::{Node, NodeKind, Response, Snapshot},
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
    AnyElement, App, Bounds, Context, Entity, Focusable, KeyBinding, SharedString, Subscription,
    Window, WindowBounds, WindowOptions, actions, div, prelude::*, px, rgb, size,
};
use serde_json::json;
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
};
actions!(leaf, [Quit]);
#[derive(Clone)]
struct ListAddress {
    list: String,
    key: String,
    index: usize,
}
struct InputSlot {
    state: Entity<InputState>,
    observed_value: String,
    model_value: String,
    placeholder: String,
    _subscription: Subscription,
    stamp: u64,
    list_address: Option<ListAddress>,
}
struct Desktop {
    snapshot: Snapshot,
    bridge: Bridge,
    inputs: HashMap<String, InputSlot>,
    list_slots: RefCell<HashMap<String, lists::ListSlot>>,
    error: Option<String>,
    sync_clock: u64,
    frame_start: Option<std::time::Instant>,
    ready_sent: bool,
    rendering_supported: bool,
    last_rendering: Option<serde_json::Value>,
    _bounds_subscription: Subscription,
}
impl Desktop {
    fn new(
        snapshot: Snapshot,
        bridge: Bridge,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut view = Self {
            snapshot,
            bridge,
            inputs: HashMap::new(),
            list_slots: RefCell::new(HashMap::new()),
            error: None,
            sync_clock: 0,
            frame_start: None,
            ready_sent: false,
            rendering_supported: false,
            last_rendering: None,
            _bounds_subscription: cx.observe_window_bounds(window, |view, window, _| {
                view.sample_rendering(window);
            }),
        };
        view.sync_inputs(window, cx);
        if std::env::var_os("LEAF_WATCH_STATUS").is_some() {
            cx.spawn_in(window, async move |view, cx| {
                loop {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(200))
                        .await;
                    if view
                        .update_in(cx, |view, _, cx| {
                            let response = view.bridge.request(json!({"op":"status"}));
                            let old = view.error.clone();
                            view.accept(response);
                            if old != view.error {
                                cx.notify();
                            }
                        })
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
    fn rendering_sample(window: &Window) -> serde_json::Value {
        let scale = window.scale_factor();
        let logical = window.viewport_size();
        let width = f32::from(logical.width);
        let height = f32::from(logical.height);
        json!({
            "scale_factor": scale,
            "logical_size": {"width": width, "height": height},
            "device_size_calculated": {"width": width * scale, "height": height * scale},
            "dpi_from_scale_calculated": 96.0 * scale,
        })
    }
    fn sample_rendering(&mut self, window: &Window) {
        if !self.rendering_supported {
            return;
        }
        let sample = Self::rendering_sample(window);
        if self.last_rendering.as_ref() == Some(&sample) {
            return;
        }
        self.last_rendering = Some(sample.clone());
        // Diagnostics must never replace the snapshot or business error.
        let error = match self.bridge.rendering(sample) {
            Ok(response) => response.error,
            Err(error) => Some(error),
        };
        if let Some(error) = error {
            eprintln!("leaf GPUI rendering diagnostics: {error}");
        }
    }
    fn schedule_ready(entity: &Entity<Self>, window: &Window, frames: bool) {
        let weak = entity.downgrade();
        window.on_next_frame(move |window, cx| {
            let _ = weak.update(cx, |view, cx| {
                if view.ready_sent {
                    return;
                }
                if view.error.is_some()
                    || view
                        .list_slots
                        .borrow()
                        .values()
                        .any(|slot| slot.frame_failed)
                {
                    if std::env::var_os("LEAF_WATCH_READY").is_some() {
                        cx.quit();
                    }
                    return;
                }
                view.ready_sent = true;
                let sample = Self::rendering_sample(window);
                view.last_rendering = Some(sample.clone());
                let response = view.bridge.ready(sample);
                match response {
                    Ok((response, supported)) => {
                        view.rendering_supported = supported;
                        view.accept(Ok(response));
                    }
                    Err(error) => {
                        view.accept(Err(error));
                    }
                }
                cx.notify();
            });
            if frames {
                schedule_frame(weak, window);
            }
        });
    }
    fn accept(&mut self, response: Result<Response, String>) -> Vec<Node> {
        match response {
            Ok(response) => {
                self.snapshot = response.snapshot;
                self.error = response.error;
                response.rows
            }
            Err(error) => {
                self.error = Some(error);
                Vec::new()
            }
        }
    }
    fn dispatch(
        &mut self,
        id: String,
        kind: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot.root.find(&id).is_none_or(|n| {
            n.disabled
                || match kind {
                    "click" => !n.events.click,
                    "change" => !n.events.change,
                    "submit" => !n.events.submit,
                    _ => true,
                }
        }) {
            return;
        }
        let protected = self
            .inputs
            .iter()
            .filter(|(_, slot)| slot.state.read(cx).focus_handle(cx).is_focused(window))
            .filter_map(|(id, slot)| {
                slot.list_address
                    .clone()
                    .map(|address| (id.clone(), address))
            })
            .collect::<Vec<_>>();
        self.accept(self.bridge.request(
            json!({"op":"event","id":id,"kind":kind,"value":text,"checked":text=="true"}),
        ));
        for (input, address) in protected {
            if self
                .snapshot
                .root
                .find(&address.list)
                .is_some_and(|n| n.list.is_some())
            {
                self.accept(self.bridge.request(json!({"op":"list","id":address.list,"first":0,"finish":0,"protected":[],"protected_keys":[{"key":address.key,"index":address.index}]})));
            }
            if self.snapshot.root.find(&input).is_none() {
                self.inputs.remove(&input);
            }
        }
        for slot in self.list_slots.borrow_mut().values_mut() {
            slot.last_failure = None;
        }
        cx.notify();
    }
    fn sync_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let mut all = Vec::new();
        self.snapshot.root.walk(&mut all);
        let desired: Vec<Node> = all
            .into_iter()
            .filter(|node| node.kind == NodeKind::Input)
            .cloned()
            .collect();
        let mut addresses = HashMap::new();
        let mut nodes = Vec::new();
        self.snapshot.root.walk(&mut nodes);
        for list in nodes.iter().filter(|n| n.list.is_some()) {
            for row in &list.children {
                if let (Some(index), Some(key)) = (row.list_index, row.item_key.as_ref()) {
                    let mut descendants = Vec::new();
                    row.walk(&mut descendants);
                    for input in descendants
                        .into_iter()
                        .filter(|n| n.kind == NodeKind::Input)
                    {
                        addresses.insert(
                            input.id.clone(),
                            ListAddress {
                                list: list.id.clone(),
                                key: key.clone(),
                                index,
                            },
                        );
                    }
                }
            }
        }
        let live: HashSet<String> = desired.iter().map(|node| node.id.clone()).collect();
        self.sync_clock += 1;
        let mut all = Vec::new();
        self.snapshot.root.walk(&mut all);
        let list_ids: Vec<String> = all
            .iter()
            .filter(|n| n.list.is_some())
            .map(|n| n.id.clone())
            .collect();
        self.inputs.retain(|id, _| {
            live.contains(id)
                || list_ids
                    .iter()
                    .any(|list| id.starts_with(&format!("{list}/")))
        });
        for node in desired {
            if let Some(slot) = self.inputs.get_mut(&node.id) {
                slot.stamp = self.sync_clock;
                slot.list_address = addresses.get(&node.id).cloned();
                // Equal controlled values must not call set_value: it resets
                // selection, composition and undo history in the native input.
                let model_changed = slot.model_value != node.text;
                if slot.state.read(cx).value().as_ref() != node.text {
                    let changed = slot.state.update(cx, |input, cx| {
                        // Kit keeps IME preedit locally and emits Change only
                        // on commit. An unchanged model must not cancel it.
                        if !model_changed
                            && gpui::EntityInputHandler::marked_text_range(input, window, cx)
                                .is_some()
                        {
                            return false;
                        }
                        input.set_value(node.text.clone(), window, cx);
                        true
                    });
                    if changed {
                        slot.observed_value = node.text.clone();
                    }
                }
                slot.model_value = node.text.clone();
                if slot.placeholder != node.placeholder {
                    slot.placeholder = node.placeholder.clone();
                    slot.state.update(cx, |input, cx| {
                        input.set_placeholder(node.placeholder.clone(), window, cx)
                    });
                }
            } else {
                let state = cx.new(|cx| {
                    let mut input =
                        InputState::new(window, cx).placeholder(node.placeholder.clone());
                    input.set_value(node.text.clone(), window, cx);
                    input
                });
                let id = node.id.clone();
                let subscription =
                    cx.subscribe_in(&state, window, move |view, input, event, window, cx| {
                        let text = input.read(cx).value().to_string();
                        let Some(slot) = view.inputs.get_mut(&id) else {
                            return;
                        };
                        let kind = match event {
                            InputEvent::Change => {
                                // Native programmatic changes also emit Change.
                                // Acknowledge them without reentering Nim.
                                if slot.observed_value == text {
                                    return;
                                }
                                slot.observed_value = text.clone();
                                "change"
                            }
                            InputEvent::PressEnter { .. } => "submit",
                            _ => return,
                        };
                        let node = view.snapshot.root.find(&id);
                        let token = node
                            .map(|node| match kind {
                                "change" => node.events.change,
                                "submit" => node.events.submit,
                                _ => false,
                            })
                            .unwrap_or(false);
                        if token {
                            view.dispatch(id.clone(), kind, &text, window, cx);
                        }
                    });
                self.inputs.insert(
                    node.id.clone(),
                    InputSlot {
                        state,
                        observed_value: node.text.clone(),
                        model_value: node.text,
                        placeholder: node.placeholder,
                        _subscription: subscription,
                        stamp: self.sync_clock,
                        list_address: addresses.get(&node.id).cloned(),
                    },
                );
            }
        }
        // Keep a bounded cache of offscreen input entities and never evict focus.
        let mut cached: Vec<(String, u64)> = self
            .inputs
            .iter()
            .filter(|(id, slot)| {
                !live.contains(*id) && !slot.state.read(cx).focus_handle(cx).is_focused(window)
            })
            .map(|(id, slot)| (id.clone(), slot.stamp))
            .collect();
        cached.sort_by_key(|(_, stamp)| *stamp);
        let excess = cached.len().saturating_sub(128);
        for (id, _) in cached.into_iter().take(excess) {
            self.inputs.remove(&id);
        }
    }

    fn render_node(&self, node: &Node, cx: &mut Context<Self>) -> AnyElement {
        let id = SharedString::from(node.id.clone());
        match node.kind {
            NodeKind::VirtualList => self.render_virtual_list(node, cx),
            NodeKind::Column | NodeKind::Row => {
                let mut layout = div().id(id).flex().min_w_0().min_h_0();
                if node.kind == NodeKind::Column {
                    layout = layout.flex_col();
                }
                if node.styles.get("overflow").is_some_and(|s| s == "scroll") {
                    layout = layout.overflow_y_scroll();
                }
                let layout = styles::apply(layout, &node.styles);
                layout
                    .children(
                        node.children
                            .iter()
                            .map(|child| self.render_node(child, cx)),
                    )
                    .into_any_element()
            }
            NodeKind::Text => styles::apply(div().id(id).child(node.text.clone()), &node.styles)
                .into_any_element(),
            NodeKind::Button => {
                let token = node.id.clone();
                let button = Button::new(id)
                    .label(node.text.clone())
                    .disabled(node.disabled)
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.dispatch(token.clone(), "click", "", window, cx)
                    }));
                let button = match node.attr("variant") {
                    "primary" => button.primary(),
                    "danger" => button.danger(),
                    "outline" => button.outline(),
                    "ghost" => button.ghost(),
                    _ => button,
                };
                styles::apply(button, &node.styles).into_any_element()
            }
            NodeKind::Checkbox => {
                let token = node.id.clone();
                let view = cx.entity().downgrade();
                let widget = Checkbox::new(id)
                    .label(node.text.clone())
                    .checked(node.attr("checked") == "true")
                    .disabled(node.disabled)
                    .on_change(move |checked, window, cx| {
                        let _ = view.update(cx, |view, cx| {
                            view.dispatch(
                                token.clone(),
                                "change",
                                if *checked { "true" } else { "false" },
                                window,
                                cx,
                            )
                        });
                    });
                styles::apply(widget, &node.styles).into_any_element()
            }
            NodeKind::Switch => {
                let token = node.id.clone();
                let view = cx.entity().downgrade();
                let widget = Switch::new(id)
                    .label(node.text.clone())
                    .checked(node.attr("checked") == "true")
                    .disabled(node.disabled)
                    .on_change(move |checked, window, cx| {
                        let _ = view.update(cx, |view, cx| {
                            view.dispatch(
                                token.clone(),
                                "change",
                                if *checked { "true" } else { "false" },
                                window,
                                cx,
                            )
                        });
                    });
                styles::apply(widget, &node.styles).into_any_element()
            }
            NodeKind::Progress => styles::apply(
                Progress::new(id).value(node.attr("value").parse().unwrap_or(0.0)),
                &node.styles,
            )
            .into_any_element(),
            NodeKind::Tag => {
                let tag = match node.attr("variant") {
                    "primary" => Tag::primary(),
                    "danger" => Tag::danger(),
                    "success" => Tag::success(),
                    "warning" => Tag::warning(),
                    "info" => Tag::info(),
                    _ => Tag::secondary(),
                };
                styles::apply(
                    div().id(id).child(tag.child(node.text.clone())),
                    &node.styles,
                )
                .into_any_element()
            }
            NodeKind::Separator => {
                styles::apply(div().id(id).child(Separator::horizontal()), &node.styles)
                    .into_any_element()
            }
            NodeKind::Spinner => {
                styles::apply(div().id(id).child(Spinner::new()), &node.styles).into_any_element()
            }
            NodeKind::Input => {
                if let Some(slot) = self.inputs.get(&node.id) {
                    styles::apply(
                        div()
                            .id(id)
                            .min_w_0()
                            .child(Input::new(&slot.state).disabled(node.disabled)),
                        &node.styles,
                    )
                    .into_any_element()
                } else {
                    div().into_any_element()
                }
            }
        }
    }
}
impl Render for Desktop {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_lists();
        self.sync_inputs(window, cx);
        let tree = self.render_node(&self.snapshot.root, cx);
        div()
            .id("leaf-window")
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(0x111827))
            .text_color(rgb(0xe5e7eb))
            .text_size(px(15.0))
            .child(div().flex_1().min_h_0().overflow_hidden().child(tree))
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
    }
}
pub fn run(snapshot: Snapshot, bridge: Bridge, frames: bool) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    if std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return Err("no graphical session; use --check / --headless".into());
    }
    let failure = Rc::new(RefCell::new(None));
    let startup_error = failure.clone();
    let title = snapshot.title.clone();
    let width = snapshot.width as f32;
    let height = snapshot.height as f32;
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
                    size(px(width), px(height)),
                    cx,
                ))),
                ..Default::default()
            };
            match gpui::open_window(options, cx, |window, cx| {
                window.set_window_title(&title);
                let entity = cx.new(|cx| Desktop::new(snapshot, bridge, window, cx));
                Desktop::schedule_ready(&entity, window, frames);
                entity
            }) {
                Ok(_) => cx.activate(true),
                Err(error) => {
                    *failure.borrow_mut() = Some(error.to_string());
                    cx.quit();
                }
            }
        });
    match startup_error.borrow_mut().take() {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
fn schedule_frame(view: gpui::WeakEntity<Desktop>, window: &Window) {
    window.on_next_frame(move |window, cx| {
        let _ = view.update(cx, |desktop, cx| {
            let elapsed = desktop
                .frame_start
                .take()
                .map(|start| start.elapsed().as_secs_f64() * 1000.0);
            let start = std::time::Instant::now();
            let response = desktop
                .bridge
                .request(json!({"op":"frame","elapsed_ms":elapsed}));
            let close = response.as_ref().map_or(true, |r| r.close);
            desktop.accept(response);
            if close {
                cx.quit();
            } else {
                desktop.frame_start = Some(start);
                cx.notify();
                schedule_frame(view.clone(), window);
            }
        });
    });
}

#[cfg(test)]
#[path = "list_tests.rs"]
mod list_tests;
#[cfg(test)]
#[path = "ui_tests.rs"]
mod tests;

#[cfg(test)]
mod dpi_tests {
    use super::*;
    use gpui::test::TestWindowExt;
    use serde_json::Value;
    use std::ffi::{CString, c_char, c_void};
    // Preserve the old Nim handler's persistent error and receipt semantics.
    struct LegacyHost {
        snapshot: Value,
        response: CString,
        capability: Value,
        error: Option<String>,
        reject_ready: bool,
        null_ready: bool,
        fail_lists: bool,
        ready_sample: Option<Value>,
        diagnostic_failure: bool,
        ready_count: usize,
        receipt_writes: usize,
        unknown_count: usize,
        events: usize,
        samples: Vec<Value>,
    }
    impl LegacyHost {
        fn new(capability: Value) -> Self {
            Self {
                snapshot: json!({"title":"DPI","width":640,"height":480,
                    "root":{"id":"root","kind":"text","text":"中文"}}),
                response: CString::new("").unwrap(),
                capability,
                error: None,
                reject_ready: false,
                null_ready: false,
                fail_lists: false,
                ready_sample: None,
                diagnostic_failure: false,
                ready_count: 0,
                receipt_writes: 0,
                unknown_count: 0,
                events: 0,
                samples: vec![],
            }
        }
        fn bridge(&mut self) -> Bridge {
            Bridge {
                callback,
                context: self as *mut Self as *mut c_void,
            }
        }
    }
    unsafe extern "C" fn callback(ctx: *mut c_void, data: *const u8, len: usize) -> *const c_char {
        let host = unsafe { &mut *(ctx as *mut LegacyHost) };
        let request: Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, len) }).unwrap();
        let mut transient_error = None;
        match request["op"].as_str().unwrap() {
            "ready" => {
                host.ready_count += 1;
                host.ready_sample = Some(request["rendering"].clone());
                if host.null_ready {
                    return std::ptr::null();
                }
                if host.reject_ready || host.error.is_some() {
                    host.error = Some("GPUI initial viewport failed".into());
                } else {
                    host.receipt_writes += 1;
                }
            }
            "rendering" if host.capability == json!(true) => {
                host.samples.push(request["rendering"].clone());
                if host.diagnostic_failure {
                    transient_error = Some("diagnostic failed".to_string());
                }
            }
            "list" if host.fail_lists => {
                host.error = Some("initial viewport failed".into());
            }
            "status" | "list" => {} // Successful status/list do not clear legacy error.
            "event" => {
                host.events += 1;
                host.error = None;
            }
            _ => {
                host.unknown_count += 1;
                host.error = Some("unknown GPUI request".into());
            }
        }
        let mut response = json!({"snapshot":host.snapshot,"rows":[]});
        if let Some(error) = transient_error.as_ref().or(host.error.as_ref()) {
            response["error"] = json!(error);
        }
        if request["op"] == "ready" && host.error.is_none() && !host.capability.is_null() {
            response["capabilities"] = json!({"rendering_diagnostics":host.capability});
        }
        host.response = CString::new(response.to_string()).unwrap();
        host.response.as_ptr()
    }
    fn form<'a>(
        host: &mut LegacyHost,
        cx: &'a mut gpui::TestAppContext,
    ) -> (Entity<Desktop>, &'a mut gpui::VisualTestContext) {
        cx.update(gpui::init);
        let snapshot = Snapshot::parse(&host.snapshot.to_string()).unwrap();
        let bridge = host.bridge();
        let mut desktop = None;
        let (_, visual) = cx.add_window_view(|window, cx| {
            let view = cx.new(|cx| Desktop::new(snapshot, bridge, window, cx));
            desktop = Some(view.clone());
            gpui::base::Root::new(view, window, cx)
        });
        (desktop.unwrap(), visual)
    }
    fn handshake(view: &Entity<Desktop>, cx: &mut gpui::VisualTestContext) {
        cx.update(|window, _| Desktop::schedule_ready(view, window, false));
        cx.update(|window, app| {
            window.render_frame(app);
            window.simulate_next_frame(app);
        });
        cx.run_until_parked();
    }
    fn verify_disabled(capability: Value, reject: bool, cx: &mut gpui::TestAppContext) {
        let mut host = LegacyHost::new(capability);
        host.reject_ready = reject;
        let (view, cx) = form(&mut host, cx);
        // Real bounds subscription fires before ready; it must never probe a new op.
        cx.simulate_scale_factor_change(1.5);
        cx.run_until_parked();
        assert_eq!(host.unknown_count, 0);
        assert!(host.samples.is_empty());
        handshake(&view, cx);
        let expected_error = host.error.clone();
        cx.simulate_scale_factor_change(1.25);
        cx.simulate_resize(size(px(700.), px(500.)));
        cx.run_until_parked();
        // Even scheduling again cannot publish a second receipt.
        handshake(&view, cx);
        assert_eq!(host.ready_count, 1);
        assert_eq!(host.receipt_writes, usize::from(!reject));
        assert_eq!(host.unknown_count, 0);
        assert!(host.samples.is_empty());
        assert_eq!(host.error, expected_error);
        view.update(cx, |view, _| {
            for op in ["status", "list", "event", "status"] {
                let response = view.bridge.request(json!({"op":op}));
                if op == "list" && reject {
                    assert!(response.as_ref().unwrap().error.is_some());
                }
                view.accept(response);
            }
        });
        assert!(host.error.is_none());
        assert_eq!(host.events, 1);
        assert!(view.read_with(cx, |view, _| view.error.is_none()));
    }
    #[gpui::test]
    fn legacy_host_no_capability_never_receives_unknown_op(cx: &mut gpui::TestAppContext) {
        verify_disabled(Value::Null, false, cx);
    }
    #[gpui::test]
    fn false_capability_keeps_bounds_diagnostics_disabled(cx: &mut gpui::TestAppContext) {
        verify_disabled(json!(false), false, cx);
    }
    #[gpui::test]
    fn nonboolean_capability_keeps_bounds_diagnostics_disabled(cx: &mut gpui::TestAppContext) {
        verify_disabled(json!("true"), false, cx);
    }
    #[gpui::test]
    fn failed_initial_ready_keeps_bounds_diagnostics_disabled(cx: &mut gpui::TestAppContext) {
        verify_disabled(json!(true), true, cx);
    }
    #[gpui::test]
    fn ready_transport_failure_never_enables_diagnostics(cx: &mut gpui::TestAppContext) {
        let mut host = LegacyHost::new(json!(true));
        host.null_ready = true;
        let (view, cx) = form(&mut host, cx);
        handshake(&view, cx);
        cx.simulate_scale_factor_change(1.5);
        cx.run_until_parked();
        assert_eq!(host.ready_count, 1);
        assert_eq!(host.receipt_writes, 0);
        assert!(host.samples.is_empty());
        assert!(view.read_with(cx, |view, _| view.error.is_some()));
    }
    #[gpui::test]
    fn initial_list_failure_does_not_publish_ready(cx: &mut gpui::TestAppContext) {
        let mut host = LegacyHost::new(json!(true));
        host.fail_lists = true;
        host.snapshot["root"] = json!({"id":"items","kind":"virtual_list",
            "styles":{"height":"full","width":"full"},
            "list":{"count":1,"row_height":30.,"estimated_height":30.,"overscan":1}});
        let (view, cx) = form(&mut host, cx);
        handshake(&view, cx);
        cx.simulate_scale_factor_change(1.5);
        cx.run_until_parked();
        assert_eq!(host.ready_count, 0);
        assert_eq!(host.receipt_writes, 0);
        assert!(host.samples.is_empty());
    }
    #[gpui::test]
    fn negotiated_bounds_sample_updated_window_and_deduplicate(cx: &mut gpui::TestAppContext) {
        let mut host = LegacyHost::new(json!(true));
        let (view, cx) = form(&mut host, cx);
        cx.simulate_scale_factor_change(1.5);
        cx.simulate_resize(size(px(640.), px(480.)));
        cx.run_until_parked();
        assert!(host.samples.is_empty());
        handshake(&view, cx);
        let initial = host.ready_sample.as_ref().unwrap();
        assert_eq!(initial["scale_factor"], 1.5);
        assert_eq!(initial["logical_size"]["width"], 640.);
        assert_eq!(initial["device_size_calculated"]["width"], 960.);
        assert_eq!(initial["dpi_from_scale_calculated"], 144.);
        cx.simulate_scale_factor_change(1.25);
        cx.run_until_parked();
        assert_eq!(host.samples.len(), 1);
        assert_eq!(host.samples[0]["scale_factor"], 1.25);
        assert_eq!(host.samples[0]["logical_size"]["width"], 640.);
        assert_eq!(host.samples[0]["device_size_calculated"]["width"], 800.);
        assert_eq!(host.samples[0]["dpi_from_scale_calculated"], 120.);
        cx.simulate_scale_factor_change(1.25);
        cx.run_until_parked();
        assert_eq!(host.samples.len(), 1);
        cx.simulate_resize(size(px(700.), px(500.)));
        cx.run_until_parked();
        assert_eq!(host.samples.len(), 2);
        assert_eq!(host.samples[1]["device_size_calculated"]["width"], 875.);
        assert_eq!(host.ready_count, 1);
        assert_eq!(host.receipt_writes, 1);
        host.diagnostic_failure = true;
        cx.simulate_scale_factor_change(1.5);
        cx.run_until_parked();
        assert!(host.error.is_none());
        assert!(view.read_with(cx, |view, _| view.error.is_none()));
        assert_eq!(host.ready_count, 1);
    }
}
