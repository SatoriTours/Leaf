use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NodeKind {
    Column,
    Row,
    Text,
    Button,
    Input,
    Checkbox,
    Switch,
    Progress,
    Tag,
    Separator,
    Spinner,
    VirtualList,
}
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Events {
    #[serde(default)]
    pub click: bool,
    #[serde(default)]
    pub change: bool,
    #[serde(default)]
    pub submit: bool,
}
#[derive(Clone, Debug, Deserialize)]
pub struct ListDescriptor {
    #[serde(default)]
    pub generation: u64,
    pub count: usize,
    pub row_height: f32,
    pub estimated_height: f32,
    pub overscan: usize,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Node {
    pub kind: NodeKind,
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub placeholder: String,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub styles: BTreeMap<String, String>,
    #[serde(default)]
    pub attributes: BTreeMap<String, String>,
    #[serde(default)]
    pub events: Events,
    #[serde(default)]
    pub children: Vec<Node>,
    pub list: Option<ListDescriptor>,
    pub list_index: Option<usize>,
    pub item_key: Option<String>,
}
impl Node {
    pub fn walk<'a>(&'a self, out: &mut Vec<&'a Node>) {
        out.push(self);
        for child in &self.children {
            child.walk(out);
        }
    }
    pub fn find(&self, id: &str) -> Option<&Node> {
        if self.id == id {
            Some(self)
        } else {
            self.children.iter().find_map(|n| n.find(id))
        }
    }
    pub fn attr(&self, key: &str) -> &str {
        self.attributes.get(key).map(String::as_str).unwrap_or("")
    }
}
#[derive(Clone, Debug, Deserialize)]
pub struct Snapshot {
    pub title: String,
    pub width: i32,
    pub height: i32,
    pub root: Node,
}
impl Snapshot {
    pub fn parse(text: &str) -> Result<Self, String> {
        if text.len() > 32 * 1024 * 1024 {
            return Err("snapshot exceeds 32 MiB".into());
        }
        let snapshot: Self = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if snapshot.width <= 0 || snapshot.height <= 0 {
            return Err("invalid window dimensions".into());
        }
        let mut ids = HashSet::new();
        fn validate(n: &Node, depth: usize, ids: &mut HashSet<String>) -> Result<(), String> {
            if depth > 64 || ids.len() >= 10_000 || !ids.insert(n.id.clone()) {
                return Err("invalid tree depth, size or duplicate ID".into());
            }
            if n.kind == NodeKind::VirtualList && n.list.is_none() {
                return Err("missing list descriptor".into());
            }
            if let Some(list) = &n.list
                && (list.count > 100_000
                    || !list.row_height.is_finite()
                    || list.row_height < 0.0
                    || !list.estimated_height.is_finite()
                    || list.estimated_height <= 0.0)
            {
                return Err("invalid list dimensions".into());
            }
            for (key, value) in &n.styles {
                if ["color", "background", "border_color"].contains(&key.as_str())
                    && !(value.starts_with('#')
                        && [4, 7, 9].contains(&value.len())
                        && value[1..].bytes().all(|b| b.is_ascii_hexdigit()))
                {
                    return Err("invalid color".into());
                }
            }
            for child in &n.children {
                validate(child, depth + 1, ids)?;
            }
            Ok(())
        }
        validate(&snapshot.root, 0, &mut ids)?;
        Ok(snapshot)
    }
}
#[derive(Deserialize)]
pub struct Response {
    pub snapshot: Snapshot,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub rows: Vec<Node>,
    #[serde(default)]
    pub close: bool,
    pub index: Option<usize>,
}
