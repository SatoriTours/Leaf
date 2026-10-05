use super::*;
use gpui::test::TestWindowExt;
use std::ffi::{CString, c_char, c_void};
struct Fixture {
    value: serde_json::Value,
    response: CString,
    events: usize,
    reject: bool,
}
impl Fixture {
    fn new() -> Self {
        Self {
            value: json!({"title":"Nim GPUI","width":640,"height":480,"root":{"kind":"column","id":"root","children":[
                {"kind":"input","id":"entry","text":"中文abc","events":{"change":true,"submit":true}},
                {"kind":"button","id":"add","text":"增加","events":{"click":true}},
                {"kind":"checkbox","id":"check","text":"选项","disabled":true,"events":{"change":true},"attributes":{"checked":"false"}}
            ]}}),
            response: CString::new("").unwrap(),
            events: 0,
            reject: false,
        }
    }
    fn bridge(&mut self) -> Bridge {
        Bridge {
            callback,
            context: self as *mut Self as *mut c_void,
        }
    }
}
unsafe extern "C" fn callback(context: *mut c_void, data: *const u8, len: usize) -> *const c_char {
    let fixture = unsafe { &mut *(context as *mut Fixture) };
    let message: serde_json::Value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, len) }).unwrap();
    if message["op"] == "event" {
        fixture.events += 1;
        if message["kind"] == "change" && !fixture.reject {
            fixture.value["root"]["children"][0]["text"] = message["value"].clone();
        }
    }
    fixture.response =
        CString::new(json!({"snapshot":fixture.value,"rows":[]}).to_string()).unwrap();
    fixture.response.as_ptr()
}
fn form<'a>(
    fixture: &mut Fixture,
    cx: &'a mut gpui::TestAppContext,
) -> (Entity<Desktop>, &'a mut gpui::VisualTestContext) {
    cx.update(gpui::init);
    let mut desktop = None;
    let snapshot = Snapshot::parse(&fixture.value.to_string()).unwrap();
    let bridge = fixture.bridge();
    let (_, visual) = cx.add_window_view(|window, cx| {
        let view = cx.new(|cx| Desktop::new(snapshot, bridge, window, cx));
        desktop = Some(view.clone());
        gpui::base::Root::new(view, window, cx)
    });
    (desktop.unwrap(), visual)
}
#[gpui::test]
fn kit_click_dispatches_and_disabled_checkbox_rejects(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new();
    let (_, cx) = form(&mut fixture, cx);
    cx.update(|window, app| {
        window.render_frame(app);
        window.click("add", app);
        window.click("check", app);
    });
    cx.run_until_parked();
    assert_eq!(fixture.events, 1);
}
#[gpui::test]
fn stable_input_keeps_entity_selection_and_unicode(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new();
    let (view, cx) = form(&mut fixture, cx);
    let input = view.read_with(cx, |view, _| view.inputs["entry"].state.clone());
    cx.update(|window, app| input.update(app, |input, cx| input.focus(window, cx)));
    cx.simulate_keystrokes(if cfg!(target_os = "macos") {
        "cmd-a"
    } else {
        "ctrl-a"
    });
    cx.update(|window, app| {
        view.update(app, |view, cx| {
            view.dispatch("add".into(), "click", "", window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(
        view.read_with(cx, |view, _| view.inputs["entry"].state.entity_id()),
        input.entity_id()
    );
    cx.update(|window, app| {
        input.update(app, |input, cx| {
            assert_eq!(
                gpui::EntityInputHandler::selected_text_range(input, false, window, cx)
                    .unwrap()
                    .range,
                0..5
            )
        })
    });
}
#[gpui::test]
fn native_input_change_and_submit_return_to_owner(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new();
    let (view, cx) = form(&mut fixture, cx);
    let input = view.read_with(cx, |view, _| view.inputs["entry"].state.clone());
    cx.update(|window, app| input.update(app, |input, cx| input.focus(window, cx)));
    cx.update(|window, app| {
        input.update(app, |state, cx| {
            gpui::EntityInputHandler::replace_text_in_range(state, None, "测试", window, cx)
        })
    });
    cx.run_until_parked();
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert!(fixture.events >= 2, "events={}", fixture.events);
    assert!(
        fixture.value["root"]["children"][0]["text"]
            .as_str()
            .unwrap()
            .contains("测试")
    );
}

#[gpui::test]
fn rejected_controlled_edit_restores_value_without_recursive_change(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new();
    fixture.reject = true;
    let (view, cx) = form(&mut fixture, cx);
    let input = view.read_with(cx, |view, _| view.inputs["entry"].state.clone());
    cx.update(|window, app| {
        input.update(app, |state, cx| {
            gpui::EntityInputHandler::replace_text_in_range(state, Some(0..5), "拒绝", window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(
        input.read_with(cx, |state, _| state.value().to_string()),
        "中文abc"
    );
    assert_eq!(fixture.events, 1);
}
#[gpui::test]
fn ime_preedit_survives_unrelated_refresh_and_commits_once(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new();
    let (view, cx) = form(&mut fixture, cx);
    let input = view.read_with(cx, |view, _| view.inputs["entry"].state.clone());
    cx.update(|window, app| {
        input.update(app, |state, cx| {
            gpui::EntityInputHandler::replace_and_mark_text_in_range(
                state,
                Some(0..5),
                "拼音",
                Some(2..2),
                window,
                cx,
            )
        })
    });
    cx.run_until_parked();
    assert_eq!(fixture.events, 0);
    cx.update(|window, app| {
        view.update(app, |view, cx| {
            view.dispatch("add".into(), "click", "", window, cx)
        })
    });
    cx.run_until_parked();
    cx.update(|window, app| {
        input.update(app, |state, cx| {
            assert_eq!(
                gpui::EntityInputHandler::marked_text_range(state, window, cx),
                Some(0..2)
            );
            gpui::EntityInputHandler::replace_text_in_range(state, Some(0..2), "中文", window, cx);
        })
    });
    cx.run_until_parked();
    assert_eq!(fixture.events, 2);
    assert_eq!(fixture.value["root"]["children"][0]["text"], "中文");
}
