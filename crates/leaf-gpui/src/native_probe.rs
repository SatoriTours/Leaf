//! Optional test-build geometry probe. It never sends UI trees over the bridge.
use gpui_kit::test::TestWindowExt;
use gpui_kit::{App, Window};
pub fn write(window: &Window, _cx: &App, targets: impl Iterator<Item = (String, String)>) {
    write_host(window, _cx, targets, 0);
}
pub fn write_host(
    window: &Window,
    _cx: &App,
    targets: impl Iterator<Item = (String, String)>,
    viewport_requests: u64,
) {
    let Ok(path) = std::env::var("LEAF_TEST_GEOMETRY") else {
        return;
    };
    let mut nodes = serde_json::Map::new();
    for (name, id) in targets.chain(std::iter::once(("watch-error".into(), "leaf-error".into()))) {
        if let Some(element) = window.try_find(id) {
            let b = element.bounds();
            nodes.insert(name,serde_json::json!({"x":f32::from(b.origin.x),"y":f32::from(b.origin.y),"width":f32::from(b.size.width),"height":f32::from(b.size.height)}));
        }
    }
    let value = serde_json::json!({"nodes":nodes,"scale":window.scale_factor(),"viewport_requests":viewport_requests});
    let temporary = format!("{path}.tmp");
    if std::fs::write(&temporary, value.to_string()).is_ok() {
        let _ = std::fs::rename(temporary, path);
    }
}
