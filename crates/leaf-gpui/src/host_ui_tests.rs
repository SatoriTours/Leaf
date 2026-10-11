use super::*;
use crate::bridge_v2::AttachedHost;
use gpui::test::TestWindowExt;
use std::ffi::c_void;
struct Fixture {
    api: LeafRendererApi,
    ctx: *mut c_void,
    revision: u64,
    events: usize,
    reject: bool,
    value: String,
    reset: u64,
    boundaries: bool,
    text_layout: bool,
}
impl Fixture {
    fn new() -> Self {
        Self {
            api: Default::default(),
            ctx: std::ptr::null_mut(),
            revision: 0,
            events: 0,
            reject: false,
            value: "中文abc".into(),
            reset: 0,
            boundaries: false,
            text_layout: false,
        }
    }
    fn publish(&mut self, initial: bool) {
        let mut props = LeafProps {
            present: LEAF_P_ENABLED | LEAF_P_RESET,
            enabled: 1,
            event_mask: 6,
            reset_token: self.reset,
            text: LeafSpan {
                offset: 0,
                len: self.value.len() as u64,
            },
            ..Default::default()
        };
        if self.boundaries {
            props.present |= LEAF_P_WIDTH | LEAF_P_HEIGHT;
            props.width = LeafDimension {
                tag: 1,
                value: 200.0,
                ..Default::default()
            };
            props.height = LeafDimension {
                tag: 1,
                value: 40.0,
                ..Default::default()
            };
        }
        let mut ops = if initial {
            vec![
                LeafOp {
                    tag: 1,
                    handle: 1,
                    ..Default::default()
                },
                LeafOp {
                    tag: 1,
                    kind: 4,
                    handle: 2,
                    parent: 1,
                    props,
                    ..Default::default()
                },
                LeafOp {
                    tag: 1,
                    kind: 3,
                    handle: 3,
                    parent: 1,
                    props: LeafProps {
                        present: LEAF_P_ENABLED,
                        enabled: 1,
                        event_mask: 1,
                        ..Default::default()
                    },
                    ..Default::default()
                },
                LeafOp {
                    tag: 3,
                    handle: 1,
                    children: LeafSpan { offset: 0, len: 2 },
                    ..Default::default()
                },
            ]
        } else {
            vec![LeafOp {
                tag: 2,
                kind: 4,
                handle: 2,
                parent: 1,
                props,
                ..Default::default()
            }]
        };
        // Button text does not need an extra arena.
        if initial {
            props.text = LeafSpan::default();
            ops[0].props = props;
        }
        if self.text_layout {
            if initial {
                ops[0].kind = 1;
                ops[1].kind = 2;
            } else {
                ops[0].kind = 2;
            }
        }
        if initial && (self.boundaries || self.text_layout) {
            if self.boundaries {
                ops[2].props.width = props.width;
                ops[2].props.height = props.height;
                ops[2].props.present |= LEAF_P_WIDTH | LEAF_P_HEIGHT;
            }
            for (id, root) in [(1, 2), (2, 3)] {
                ops.push(LeafOp {
                    tag: 5,
                    boundary_id: id,
                    handle: root,
                    ..Default::default()
                });
            }
        }
        let children = [2, 3];
        let batch = LeafBatch {
            struct_size: size_of::<LeafBatch>() as u32,
            abi: 2,
            session_id: 9,
            base_revision: self.revision,
            next_revision: self.revision + 1,
            ops: ops.as_ptr(),
            ops_len: ops.len() as u64,
            children: children.as_ptr(),
            children_len: 2,
            strings: self.value.as_ptr(),
            strings_len: self.value.len() as u64,
        };
        unsafe {
            assert_eq!(
                self.api.prepare.unwrap()(self.ctx, &batch, std::ptr::null_mut()),
                0
            );
            assert_eq!(self.api.apply.unwrap()(self.ctx, std::ptr::null_mut()), 0);
            self.revision += 1;
            self.api.accept.unwrap()(self.ctx, self.revision);
        }
    }
    fn attach(&mut self) -> AttachedHost {
        let config = LeafConfig {
            struct_size: size_of::<LeafConfig>() as u32,
            session_id: 9,
            width: 640,
            height: 480,
            ..Default::default()
        };
        let callbacks = LeafHostCallbacks {
            struct_size: size_of::<LeafHostCallbacks>() as u32,
            attach: Some(attach),
            request: Some(request),
            detach: Some(detach),
            ..Default::default()
        };
        unsafe { AttachedHost::attach(&config, &callbacks, (self as *mut Self).cast()) }.unwrap()
    }
}
unsafe extern "C" fn attach(
    ctx: *mut c_void,
    api: *const LeafRendererApi,
    renderer: *mut c_void,
    _: *mut LeafError,
) -> i32 {
    let f = unsafe { &mut *ctx.cast::<Fixture>() };
    f.api = unsafe { *api };
    f.ctx = renderer;
    f.publish(true);
    0
}
unsafe extern "C" fn request(
    ctx: *mut c_void,
    req: *const LeafRequest,
    reply: *mut LeafReply,
    _: *mut LeafError,
) -> i32 {
    let f = unsafe { &mut *ctx.cast::<Fixture>() };
    let req = unsafe { &*req };
    if req.tag == 1 {
        f.events += 1;
        if f.reject {
            unsafe { (*reply).accepted_revision = f.revision };
            return 5;
        }
        if req.kind == 1 {
            f.value = unsafe {
                std::str::from_utf8(std::slice::from_raw_parts(
                    req.value.ptr,
                    req.value.len as usize,
                ))
            }
            .unwrap()
            .into();
        }
        f.publish(false);
    }
    unsafe { (*reply).accepted_revision = f.revision };
    0
}
unsafe extern "C" fn detach(_: *mut c_void) {}
fn form<'a>(
    f: &mut Fixture,
    cx: &'a mut gpui::TestAppContext,
) -> (
    AttachedHost,
    Entity<HostView>,
    &'a mut gpui::VisualTestContext,
) {
    cx.update(gpui::init);
    let host = f.attach();
    let store = host.store();
    let bridge = host.bridge();
    let mut view = None;
    let (_, visual) = cx.add_window_view(|window, cx| {
        let entity = cx.new(|cx| HostView::new_window(store, 0, bridge, window, cx));
        view = Some(entity.clone());
        gpui::base::Root::new(entity, window, cx)
    });
    (host, view.unwrap(), visual)
}
#[gpui::test]
fn typed_input_selection_unicode_and_rejection(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new();
    let (_host, view, cx) = form(&mut f, cx);
    let input = view.read_with(cx, |v, _| v.inputs.borrow()[&2].state.clone());
    cx.update(|w, cx| input.update(cx, |input, cx| input.focus(w, cx)));
    cx.simulate_keystrokes(if cfg!(target_os = "macos") {
        "cmd-a"
    } else {
        "ctrl-a"
    });
    cx.update(|w, cx| view.update(cx, |view, cx| view.dispatch(3, 0, "", false, w, cx)));
    cx.run_until_parked();
    assert_eq!(
        view.read_with(cx, |v, _| v.inputs.borrow()[&2].state.entity_id()),
        input.entity_id()
    );
    cx.update(|w, cx| {
        input.update(cx, |input, cx| {
            assert_eq!(
                gpui::EntityInputHandler::selected_text_range(input, false, w, cx)
                    .unwrap()
                    .range,
                0..5
            )
        })
    });
    f.reject = true;
    cx.update(|w, cx| {
        input.update(cx, |input, cx| {
            gpui::EntityInputHandler::replace_text_in_range(input, None, "拒绝", w, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(input.read_with(cx, |i, _| i.value().to_string()), "中文abc");
}
#[gpui::test]
fn typed_reset_reuses_entity_and_click_dispatches(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new();
    let (_host, view, cx) = form(&mut f, cx);
    let input = view.read_with(cx, |v, _| v.inputs.borrow()[&2].state.clone());
    cx.update(|w, cx| {
        w.render_frame(cx);
        w.click("host-3", cx);
    });
    cx.run_until_parked();
    assert_eq!(f.events, 1);
    f.value = "新值".into();
    f.reset = 7;
    f.publish(false);
    cx.update(|w, cx| {
        view.update(cx, |view, cx| {
            view.sync_inputs(w, cx);
            cx.notify();
        })
    });
    cx.run_until_parked();
    assert_eq!(
        view.read_with(cx, |v, _| v.inputs.borrow()[&2].state.entity_id()),
        input.entity_id()
    );
    assert_eq!(input.read_with(cx, |i, _| i.value().to_string()), "新值");
}

#[gpui::test]
fn typed_enter_and_event_transport_use_no_json(cx: &mut gpui::TestAppContext) {
    let before = crate::bridge::json_bridge_calls();
    let mut f = Fixture::new();
    let (_host, view, cx) = form(&mut f, cx);
    let input = view.read_with(cx, |v, _| v.inputs.borrow()[&2].state.clone());
    cx.update(|w, cx| input.update(cx, |input, cx| input.focus(w, cx)));
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(f.events, 1);
    assert_eq!(crate::bridge::json_bridge_calls(), before);
}

#[gpui::test]
fn fixed_sibling_boundary_skips_render_on_counter_update(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new();
    f.boundaries = true;
    let (_host, view, cx) = form(&mut f, cx);
    cx.update(|w, cx| w.render_frame(cx));
    let before = view.read_with(cx, |v, _| v.boundary_renders(2));
    assert!(before > 0);
    cx.update(|w, cx| view.update(cx, |v, cx| v.dispatch(3, 0, "", false, w, cx)));
    cx.run_until_parked();
    cx.update(|w, cx| w.draw(cx).clear(cx));
    assert_eq!(view.read_with(cx, |v, _| v.boundary_renders(2)), before);
    cx.update(|w, cx| w.render_frame(cx));
    assert!(view.read_with(cx, |v, _| v.boundary_renders(2)) > before);
}

#[gpui::test]
fn measured_content_keeps_parent_geometry_with_cache_on_and_off(cx: &mut gpui::TestAppContext) {
    let mut results = Vec::new();
    for enabled in [false, true] {
        let mut f = Fixture::new();
        f.text_layout = true;
        f.value = "9".into();
        let (_host, view, cx) = form(&mut f, cx);
        cx.update(|w, cx| {
            view.update(cx, |v, _| v.cache_enabled = enabled);
            w.render_frame(cx);
        });
        let before = cx.update(|w, _| w.find("host-3").bounds().origin.x);
        f.value = "10".into();
        f.publish(false);
        cx.update(|w, cx| {
            view.update(cx, |v, cx| {
                v.notify_dirty(cx);
                cx.notify();
            });
            w.draw(cx).clear(cx);
        });
        let after = cx.update(|w, _| w.find("host-3").bounds().origin.x);
        assert!(
            after > before,
            "content width must move the following sibling"
        );
        results.push((before, after));
    }
    assert_eq!(results[0], results[1]);
}
#[gpui::test]
fn inherited_and_external_invalidations_repaint_fixed_boundaries(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new();
    f.boundaries = true;
    let (_host, view, cx) = form(&mut f, cx);
    cx.update(|w, cx| w.render_frame(cx));
    for reason in [
        DirtyReason::InheritedStyle,
        DirtyReason::ExternalLayout,
        DirtyReason::GlobalRefresh,
    ] {
        let before = view.read_with(cx, |v, _| v.boundary_renders(2));
        cx.update(|w, cx| {
            view.update(cx, |v, cx| v.refresh_boundaries(reason, cx));
            w.draw(cx).clear(cx);
        });
        assert!(view.read_with(cx, |v, _| v.boundary_renders(2)) > before);
    }
}
