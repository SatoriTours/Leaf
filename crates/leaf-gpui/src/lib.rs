mod bridge;
mod desktop;
mod model;
pub use bridge::{leaf_gpui_abi_version, leaf_gpui_run};
#[cfg(test)]
use model::Snapshot;
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_accepts_nim_unicode_tree_and_rejects_invalid_kind() {
        let valid = r##"{"title":"中文","width":640,"height":480,"root":{"kind":"text","id":"root","text":"你好","children":[],"styles":{},"attributes":{},"events":{}}}"##;
        let snapshot = Snapshot::parse(valid).unwrap();
        assert_eq!(snapshot.root.text, "你好");
        assert!(Snapshot::parse(&valid.replace("\"text\",", "\"invalid\",")).is_err());
        assert!(Snapshot::parse(&valid.replace("640", "0")).is_err());
    }
    #[test]
    fn ffi_rejects_null_without_starting_a_window() {
        assert_eq!(
            unsafe { leaf_gpui_run(std::ptr::null(), 0, None, std::ptr::null_mut()) },
            1
        );
        assert_eq!(leaf_gpui_abi_version(), 1);
    }
}
