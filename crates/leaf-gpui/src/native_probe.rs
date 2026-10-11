//! Optional test-build geometry probe. It never sends UI trees over the bridge.
use gpui_kit::test::TestWindowExt;
use gpui_kit::{App, Window};
pub fn write(window: &Window, _cx: &App, targets: impl Iterator<Item = (String, String)>) {
    let Ok(path) = std::env::var("LEAF_TEST_GEOMETRY") else {
        return;
    };
    let mut nodes = serde_json::Map::new();
    for (name, id) in targets {
        if let Some(element) = window.try_find(id) {
            let b = element.bounds();
            nodes.insert(name,serde_json::json!({"x":f32::from(b.origin.x),"y":f32::from(b.origin.y),"width":f32::from(b.size.width),"height":f32::from(b.size.height)}));
        }
    }
    let value = serde_json::json!({"nodes":nodes,"scale":window.scale_factor()});
    let temporary = format!("{path}.tmp");
    if std::fs::write(&temporary, value.to_string()).is_ok() {
        let _ = std::fs::rename(temporary, path);
    }
}
