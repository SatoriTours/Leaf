use super::*;
use gpui::test::TestWindowExt;
use std::{
    collections::BTreeSet,
    ffi::{CString, c_char, c_void},
};
struct Fixture {
    keys: Vec<String>,
    active: BTreeSet<usize>,
    response: CString,
    generation: u64,
    events: usize,
    inputs: bool,
}
impl Fixture {
    fn new(inputs: bool) -> Self {
        Self {
            keys: (0..100).map(|i| format!("key{i}")).collect(),
            active: BTreeSet::new(),
            response: CString::new("").unwrap(),
            generation: 1,
            events: 0,
            inputs,
        }
    }
    fn row(&self, index: usize) -> serde_json::Value {
        let key = &self.keys[index];
        json!({"kind":if self.inputs{"input"}else{"button"},"id":format!("items/{key}"),"text":key,"item_key":key,"list_index":index,"styles":{"height":"32"},"events":{"click":true,"change":true}})
    }
    fn snapshot(&self) -> serde_json::Value {
        json!({"title":"List","width":640,"height":480,"root":{"kind":"column","id":"root","styles":{"width":"full","height":"full"},"children":[
            {"kind":"virtual_list","id":"items","styles":{"width":"full","height":"400"},"list":{"generation":self.generation,"count":self.keys.len(),"row_height":0,"estimated_height":32,"overscan":0},"children":self.active.iter().map(|i|self.row(*i)).collect::<Vec<_>>()},
            {"kind":"button","id":"reorder","text":"reorder","events":{"click":true}}
        ]}})
    }
}
unsafe extern "C" fn callback(context: *mut c_void, data: *const u8, len: usize) -> *const c_char {
    let f = unsafe { &mut *(context as *mut Fixture) };
    let request: serde_json::Value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, len) }).unwrap();
    let mut rows = Vec::new();
    let mut index = None;
    match request["op"].as_str().unwrap() {
        "list" => {
            let first = request["first"].as_u64().unwrap() as usize;
            let finish = request["finish"].as_u64().unwrap() as usize;
            f.active = (first..finish).collect();
            for i in request["protected"].as_array().unwrap() {
                f.active.insert(i.as_u64().unwrap() as usize);
            }
            if let Some(keys) = request["protected_keys"].as_array() {
                for entry in keys {
                    if let Some(i) = f
                        .keys
                        .iter()
                        .position(|k| entry["key"].as_str() == Some(k.as_str()))
                    {
                        f.active.insert(i);
                    }
                }
            }
            rows = (first..finish).map(|i| f.row(i)).collect();
        }
        "locate" => {
            index = f
                .keys
                .iter()
                .position(|k| request["key"].as_str() == Some(k.as_str()))
        }
        "event" => {
            f.events += 1;
            if request["id"] == "reorder" {
                f.keys.reverse();
                f.generation += 1;
                f.active.clear();
            }
        }
        _ => {}
    }
    f.response =
        CString::new(json!({"snapshot":f.snapshot(),"rows":rows,"index":index}).to_string())
            .unwrap();
    f.response.as_ptr()
}
fn form<'a>(
    fixture: &mut Fixture,
    cx: &'a mut gpui::TestAppContext,
) -> (Entity<Desktop>, &'a mut gpui::VisualTestContext) {
    cx.update(gpui::init);
    let mut desktop = None;
    let snapshot = Snapshot::parse(&fixture.snapshot().to_string()).unwrap();
    let bridge = Bridge {
        callback,
        context: fixture as *mut Fixture as *mut c_void,
    };
    let (_, visual) = cx.add_window_view(|window, cx| {
        let view = cx.new(|cx| Desktop::new(snapshot, bridge, window, cx));
        desktop = Some(view.clone());
        gpui::base::Root::new(view, window, cx)
    });
    (desktop.unwrap(), visual)
}
#[gpui::test]
fn every_visible_variable_row_remains_clickable(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new(false);
    let (view, cx) = form(&mut f, cx);
    cx.update(|window, app| window.render_frame(app));
    cx.run_until_parked();
    let ids = view.read_with(cx, |view, _| {
        view.snapshot
            .root
            .find("items")
            .unwrap()
            .children
            .iter()
            .map(|n| n.id.clone())
            .collect::<Vec<_>>()
    });
    assert!(ids.len() > 1);
    for id in ids.iter().take(2) {
        cx.update(|window, app| window.click(SharedString::from(id.clone()), app));
        cx.run_until_parked();
    }
    assert_eq!(f.events, 2);
}
#[gpui::test]
fn focused_row_remains_live_after_source_reorder_before_next_paint(cx: &mut gpui::TestAppContext) {
    let mut f = Fixture::new(true);
    let (view, cx) = form(&mut f, cx);
    cx.update(|window, app| window.render_frame(app));
    cx.run_until_parked();
    let input = view.read_with(cx, |view, _| view.inputs["items/key0"].state.clone());
    cx.update(|window, app| input.update(app, |state, cx| state.focus(window, cx)));
    cx.update(|window, app| {
        view.update(app, |view, cx| {
            view.dispatch("reorder".into(), "click", "", window, cx)
        })
    });
    view.read_with(cx, |view, _| {
        assert_eq!(
            view.snapshot.root.find("items/key0").unwrap().list_index,
            Some(99)
        );
        assert_eq!(
            view.inputs["items/key0"].state.entity_id(),
            input.entity_id()
        );
    });
    cx.update(|window, app| {
        view.update(app, |view, cx| {
            view.dispatch("items/key0".into(), "change", "编辑", window, cx)
        })
    });
    assert_eq!(f.events, 2);
}
