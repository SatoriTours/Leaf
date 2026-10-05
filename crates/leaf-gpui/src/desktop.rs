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
                let weak = entity.downgrade();
                window.on_next_frame(move |window, cx| {
                    let _ = weak.update(cx, |view, cx| {
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
                        view.accept(bridge.ready());
                        cx.notify();
                    });
                    if frames {
                        schedule_frame(weak, window);
                    }
                });
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
