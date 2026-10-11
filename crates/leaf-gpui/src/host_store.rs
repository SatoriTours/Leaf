//! Owned rendering records. A prepared overlay never shadows the accepted graph
//! outside this store; publication moves reserved entries into the flat maps.
#![allow(dead_code)]
use crate::abi_v2::*;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

#[derive(Clone, Debug, PartialEq)]
pub struct HostProps {
    pub values: LeafProps,
    pub text: String,
    pub placeholder: String,
}
#[derive(Clone, Debug)]
pub struct HostNode {
    pub handle: u64,
    pub parent: u64,
    pub kind: u32,
    pub node_id: String,
    pub props: HostProps,
    pub children: Rc<[u64]>,
}
impl HostNode {
    fn bytes(&self) -> usize {
        size_of::<Self>()
            + self.node_id.len()
            + self.props.text.len()
            + self.props.placeholder.len()
            + self.children.len() * 8
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum DirtyReason {
    Content,
    Children,
    ExternalLayout,
    InheritedStyle,
    GlobalRefresh,
}
#[derive(Clone, Debug)]
pub struct BoundaryState {
    pub root_handle: u64,
    pub parent: u64,
    pub layout_style: LeafProps,
    pub revision: u64,
    pub dirty_reason: DirtyReason,
}
#[derive(Clone, Debug)]
pub struct HostWindow {
    pub title: String,
    pub width: u32,
    pub height: u32,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct PrepareStats {
    pub visited_nodes: u64,
    pub owned_nodes: u64,
}
struct Prepared {
    nodes: HashMap<u64, Option<HostNode>>,
    boundaries: HashMap<u64, Option<BoundaryState>>,
    window: Option<HostWindow>,
    boundary_roots: HashMap<u64, Rc<[u64]>>,
    dirty: Vec<u64>,
    dirty_reasons: HashMap<u64, DirtyReason>,
    root: u64,
    count: usize,
    bytes: usize,
    revision: u64,
    epoch: u64,
    applied: bool,
    stats: PrepareStats,
}
pub struct HostStore {
    session: u64,
    revision: u64,
    epoch: u64,
    disposed: bool,
    nodes: HashMap<u64, HostNode>,
    inputs: HashSet<u64>,
    lists: HashSet<u64>,
    boundaries: HashMap<u64, BoundaryState>,
    boundary_roots: HashMap<u64, Rc<[u64]>>,
    dirty: Vec<u64>,
    root: u64,
    bytes: usize,
    window: Option<HostWindow>,
    prepared: Option<Prepared>,
}
fn bad(message: &str) -> AbiError {
    AbiError(message.into())
}
fn own_props(data: &DecodedBatch<'_>, props: &LeafProps) -> Result<HostProps, AbiError> {
    let text = data.text(props.text)?.to_owned();
    let placeholder = data.text(props.placeholder)?.to_owned();
    let mut values = *props;
    values.text = LeafSpan::default();
    values.placeholder = LeafSpan::default();
    Ok(HostProps {
        values,
        text,
        placeholder,
    })
}
fn lookup<'a>(
    nodes: &'a HashMap<u64, HostNode>,
    overlay: &'a HashMap<u64, Option<HostNode>>,
    id: u64,
) -> Option<&'a HostNode> {
    match overlay.get(&id) {
        Some(node) => node.as_ref(),
        None => nodes.get(&id),
    }
}
impl HostStore {
    pub fn new(session: u64) -> Self {
        Self {
            session,
            revision: 0,
            epoch: 1,
            disposed: false,
            nodes: HashMap::new(),
            inputs: HashSet::new(),
            lists: HashSet::new(),
            boundaries: HashMap::new(),
            boundary_roots: HashMap::new(),
            dirty: Vec::new(),
            root: 0,
            bytes: 0,
            window: None,
            prepared: None,
        }
    }
    pub fn take_dirty_boundaries(&mut self) -> Vec<u64> {
        std::mem::take(&mut self.dirty)
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn session(&self) -> u64 {
        self.session
    }
    pub fn root(&self) -> u64 {
        self.root
    }
    pub fn nodes(&self) -> impl Iterator<Item = &HostNode> {
        self.nodes.values()
    }
    pub fn node(&self, id: u64) -> Option<&HostNode> {
        self.nodes.get(&id)
    }
    pub fn input_nodes(&self) -> impl Iterator<Item = &HostNode> {
        self.inputs.iter().filter_map(|id| self.nodes.get(id))
    }
    pub fn list_nodes(&self) -> impl Iterator<Item = &HostNode> {
        self.lists.iter().filter_map(|id| self.nodes.get(id))
    }
    pub fn child_boundary(&self, handle: u64, parent: u64) -> Option<u64> {
        self.boundary_roots
            .get(&handle)?
            .iter()
            .copied()
            .find(|id| self.boundaries.get(id).is_some_and(|b| b.parent == parent))
    }
    pub fn invalidate_all(&mut self, reason: DirtyReason) {
        for (id, boundary) in &mut self.boundaries {
            boundary.dirty_reason = reason;
            self.dirty.push(*id);
        }
        self.dirty.sort_unstable();
        self.dirty.dedup();
    }
    pub fn window(&self) -> Option<&HostWindow> {
        self.window.as_ref()
    }
    pub fn boundary(&self, id: u64) -> Option<&BoundaryState> {
        self.boundaries.get(&id)
    }
    pub fn prepared_stats(&self) -> Option<PrepareStats> {
        self.prepared.as_ref().map(|p| p.stats)
    }
    pub fn prepare(&mut self, data: &DecodedBatch<'_>) -> Result<(), AbiError> {
        if self.disposed || self.session == 0 {
            return Err(bad("disposed host session"));
        }
        if self.prepared.is_some() {
            return Err(bad("a host batch is already prepared"));
        }
        if data.header.session_id != self.session {
            return Err(bad("foreign host session"));
        }
        if data.header.base_revision != self.revision
            || self.revision.checked_add(1) != Some(data.header.next_revision)
        {
            return Err(bad("stale host revision"));
        }
        let mut nodes = HashMap::<u64, Option<HostNode>>::new();
        let mut boundaries = HashMap::new();
        let mut structural = HashSet::new();
        let mut creates = HashSet::new();
        let mut deletes = HashSet::new();
        let mut orders: HashMap<u64, HashSet<u64>> = HashMap::new();
        let mut window = None;
        let mut stats = PrepareStats::default();
        for op in data.ops {
            match op.tag {
                1 => {
                    if op.handle == 0
                        || self.nodes.contains_key(&op.handle)
                        || !creates.insert(op.handle)
                    {
                        return Err(bad("duplicate host create"));
                    }
                    nodes.insert(
                        op.handle,
                        Some(HostNode {
                            handle: op.handle,
                            parent: op.parent,
                            kind: op.kind,
                            node_id: data.text(op.node_id)?.to_owned(),
                            props: own_props(data, &op.props)?,
                            children: Rc::from([]),
                        }),
                    );
                    structural.insert(op.handle);
                }
                2 => {
                    if deletes.contains(&op.handle) {
                        return Err(bad("update of removed host"));
                    }
                    let node = lookup(&self.nodes, &nodes, op.handle)
                        .ok_or_else(|| bad("update of unknown host"))?;
                    if node.kind != op.kind {
                        return Err(bad("host kind changed in place"));
                    }
                    if node.parent != op.parent {
                        structural.insert(op.handle);
                    }
                    let node = HostNode {
                        parent: op.parent,
                        node_id: data.text(op.node_id)?.to_owned(),
                        props: own_props(data, &op.props)?,
                        ..node.clone()
                    };
                    nodes.insert(op.handle, Some(node));
                }
                3 => {
                    if orders.contains_key(&op.handle) {
                        return Err(bad("duplicate final child order"));
                    }
                    let node = lookup(&self.nodes, &nodes, op.handle)
                        .ok_or_else(|| bad("order for unknown host"))?;
                    let children = data.child_handles(op.children)?;
                    let mut unique = HashSet::with_capacity(children.len());
                    if children.iter().any(|id| *id == 0 || !unique.insert(*id)) {
                        return Err(bad("duplicate or zero child"));
                    }
                    orders.insert(op.handle, unique);
                    let node = HostNode {
                        children: Rc::from(children),
                        ..node.clone()
                    };
                    nodes.insert(op.handle, Some(node));
                    structural.insert(op.handle);
                }
                4 => {
                    if !deletes.insert(op.handle)
                        || lookup(&self.nodes, &nodes, op.handle).is_none()
                    {
                        return Err(bad("remove of unknown host"));
                    }
                    if creates.contains(&op.handle) {
                        return Err(bad("create and remove in one batch"));
                    }
                    nodes.insert(op.handle, None);
                    structural.insert(op.handle);
                }
                5 => {
                    if op.boundary_id == 0 || boundaries.contains_key(&op.boundary_id) {
                        return Err(bad("invalid boundary id"));
                    }
                    boundaries.insert(
                        op.boundary_id,
                        if op.handle == 0 {
                            None
                        } else {
                            Some(BoundaryState {
                                root_handle: op.handle,
                                parent: op.boundary_parent,
                                layout_style: op.props,
                                revision: data.header.next_revision,
                                dirty_reason: DirtyReason::GlobalRefresh,
                            })
                        },
                    );
                }
                6 => {
                    if window.is_some() {
                        return Err(bad("duplicate host window"));
                    }
                    window = Some(HostWindow {
                        title: data.text(op.props.text)?.to_owned(),
                        width: op.width,
                        height: op.height,
                    });
                }
                _ => return Err(bad("unknown host operation")),
            }
        }
        // Only changed relationships are checked. Properties do not enumerate siblings.
        let mut relations = structural.clone();
        for id in &structural {
            if let Some(old) = self.nodes.get(id) {
                relations.extend(old.children.iter().copied());
            }
            if let Some(new) = lookup(&self.nodes, &nodes, *id) {
                relations.extend(new.children.iter().copied());
            }
        }
        for id in &relations {
            stats.visited_nodes += 1;
            if let Some(node) = lookup(&self.nodes, &nodes, *id) {
                if let Some(old) = self.nodes.get(id)
                    && old.parent != node.parent
                    && old.parent != 0
                    && !orders.contains_key(&old.parent)
                    && !deletes.contains(&old.parent)
                {
                    return Err(bad("old parent order missing for reparented host"));
                }
                if node.parent != 0 {
                    let _parent = lookup(&self.nodes, &nodes, node.parent)
                        .ok_or_else(|| bad("unknown host parent"))?;
                    // The final child list is inspected once per changed parent below.
                    // An unchanged parent cannot gain or lose a relationship.
                    if !orders.contains_key(&node.parent)
                        && (creates.contains(id)
                            || self
                                .nodes
                                .get(id)
                                .is_some_and(|old| old.parent != node.parent))
                    {
                        return Err(bad("parent order missing for changed relationship"));
                    }
                    if orders
                        .get(&node.parent)
                        .is_some_and(|children| !children.contains(id))
                    {
                        return Err(bad("host absent from parent order"));
                    }
                }
                if structural.contains(id) {
                    for child in node.children.iter() {
                        if lookup(&self.nodes, &nodes, *child).is_none_or(|n| n.parent != *id) {
                            return Err(bad("unknown child or multiple parents"));
                        }
                    }
                }
            } else if let Some(old) = self.nodes.get(id) {
                if old.parent != 0
                    && !orders.contains_key(&old.parent)
                    && !deletes.contains(&old.parent)
                {
                    return Err(bad("removed host remains in parent"));
                }
                if old.children.iter().any(|child| {
                    lookup(&self.nodes, &nodes, *child).is_some_and(|n| n.parent == *id)
                }) {
                    return Err(bad("removed parent has surviving children"));
                }
            }
        }
        let mut count = self.nodes.len();
        let mut bytes = self.bytes;
        let mut roots = HashSet::new();
        if self.root != 0 {
            roots.insert(self.root);
        }
        for (id, node) in &nodes {
            if let Some(old) = self.nodes.get(id) {
                count -= 1;
                bytes -= old.bytes();
                if old.parent == 0 {
                    roots.remove(id);
                }
            }
            if let Some(node) = node {
                count += 1;
                bytes = bytes
                    .checked_add(node.bytes())
                    .ok_or_else(|| bad("host byte budget overflow"))?;
                if node.parent == 0 {
                    roots.insert(*id);
                }
            }
            let mut current = *id;
            let mut depth = 0;
            while let Some(node) = lookup(&self.nodes, &nodes, current) {
                stats.visited_nodes += 1;
                depth += 1;
                if depth > LEAF_V2_MAX_DEPTH {
                    return Err(bad("host cycle or depth exceeded"));
                }
                if node.parent == 0 {
                    break;
                }
                current = node.parent;
                if lookup(&self.nodes, &nodes, current).is_none() {
                    return Err(bad("unknown ancestor"));
                }
            }
        }
        // A reparent can increase the depth of unchanged descendants.
        for id in &structural {
            if self.nodes.get(id).is_some_and(|old| {
                lookup(&self.nodes, &nodes, *id).is_some_and(|new| old.parent != new.parent)
            }) {
                let mut pending = vec![(*id, 0u64)];
                let mut ancestor = *id;
                let mut base = 0;
                while let Some(node) = lookup(&self.nodes, &nodes, ancestor) {
                    base += 1;
                    if node.parent == 0 {
                        break;
                    }
                    ancestor = node.parent;
                }
                while let Some((id, below)) = pending.pop() {
                    if base + below > LEAF_V2_MAX_DEPTH {
                        return Err(bad("host depth exceeded"));
                    }
                    if let Some(node) = lookup(&self.nodes, &nodes, id) {
                        pending.extend(node.children.iter().map(|child| (*child, below + 1)));
                    }
                }
            }
        }
        if count > LEAF_V2_MAX_NODES as usize
            || bytes > LEAF_V2_MAX_TREE as usize
            || (count > 0 && roots.len() != 1)
            || (count == 0 && !roots.is_empty())
        {
            return Err(bad("host root or description budget invalid"));
        }
        let boundary_lookup = |id: &u64| match boundaries.get(id) {
            Some(value) => value.as_ref(),
            None => self.boundaries.get(id),
        };
        for (id, boundary) in &boundaries {
            if let Some(boundary) = boundary {
                if lookup(&self.nodes, &nodes, boundary.root_handle).is_none() {
                    return Err(bad("dangling boundary root"));
                }
                let mut current = *id;
                let mut depth = 0;
                while let Some(boundary) = boundary_lookup(&current) {
                    depth += 1;
                    if depth > LEAF_V2_MAX_DEPTH {
                        return Err(bad("boundary cycle or depth exceeded"));
                    }
                    if boundary.parent == 0 {
                        break;
                    }
                    current = boundary.parent;
                    if boundary_lookup(&current).is_none() {
                        return Err(bad("unknown parent boundary"));
                    }
                }
            }
        }
        if !deletes.is_empty() || boundaries.values().any(Option::is_none) {
            for (id, boundary) in &self.boundaries {
                if let Some(final_boundary) = boundary_lookup(id)
                    && (lookup(&self.nodes, &nodes, final_boundary.root_handle).is_none()
                        || (final_boundary.parent != 0
                            && boundary_lookup(&final_boundary.parent).is_none()))
                {
                    return Err(bad("dangling accepted boundary"));
                }
                let _ = boundary;
            }
        }
        let mut root_edits: HashMap<u64, Vec<u64>> = HashMap::new();
        for (id, new) in &boundaries {
            if let Some(old) = self.boundaries.get(id) {
                let ids = root_edits.entry(old.root_handle).or_insert_with(|| {
                    self.boundary_roots
                        .get(&old.root_handle)
                        .map_or_else(Vec::new, |ids| ids.to_vec())
                });
                ids.retain(|value| value != id);
            }
            if let Some(new) = new {
                root_edits
                    .entry(new.root_handle)
                    .or_insert_with(|| {
                        self.boundary_roots
                            .get(&new.root_handle)
                            .map_or_else(Vec::new, |ids| ids.to_vec())
                    })
                    .push(*id);
            }
        }
        let mut dirty: HashSet<u64> = self.dirty.iter().copied().collect();
        dirty.extend(boundaries.keys().copied());
        for id in nodes.keys() {
            let mut current = *id;
            let mut depth = 0;
            while current != 0 && depth <= LEAF_V2_MAX_DEPTH {
                depth += 1;
                if let Some(ids) = root_edits.get(&current) {
                    dirty.extend(ids);
                } else if let Some(ids) = self.boundary_roots.get(&current) {
                    dirty.extend(ids.iter().copied());
                }
                current = lookup(&self.nodes, &nodes, current)
                    .or_else(|| self.nodes.get(&current))
                    .map_or(0, |node| node.parent);
            }
        }
        let mut dirty_reasons = HashMap::new();
        for id in &dirty {
            dirty_reasons.insert(*id, DirtyReason::Content);
        }
        for (id, new) in &boundaries {
            dirty_reasons.insert(*id, DirtyReason::GlobalRefresh);
            if let (Some(old), Some(new)) = (self.boundaries.get(id), new)
                && old.root_handle == new.root_handle
            {
                // Explicit refresh of a retained root invalidates descendants.
                for child in self.boundaries.keys() {
                    let mut ancestor = *child;
                    for _ in 0..LEAF_V2_MAX_DEPTH {
                        if ancestor == *id {
                            dirty.insert(*child);
                            dirty_reasons.insert(*child, DirtyReason::GlobalRefresh);
                            break;
                        }
                        ancestor = boundary_lookup(&ancestor).map_or(0, |b| b.parent);
                        if ancestor == 0 {
                            break;
                        }
                    }
                }
            }
        }
        for (handle, new) in &nodes {
            let Some(new) = new else {
                continue;
            };
            let Some(old) = self.nodes.get(handle) else {
                continue;
            };
            let a = &old.props.values;
            let b = &new.props.values;
            let inherited_mask = LEAF_P_COLOR | LEAF_P_FONT_SIZE | LEAF_P_WEIGHT | LEAF_P_OPACITY;
            let layout_mask = LEAF_P_WIDTH
                | LEAF_P_HEIGHT
                | LEAF_P_GAP
                | LEAF_P_PADDING
                | LEAF_P_FLEX_GROW
                | LEAF_P_FLEX_SHRINK
                | LEAF_P_MIN_WIDTH
                | LEAF_P_MIN_HEIGHT
                | LEAF_P_MAX_WIDTH
                | LEAF_P_MAX_HEIGHT
                | LEAF_P_ALIGN
                | LEAF_P_JUSTIFY
                | LEAF_P_OVERFLOW;
            let inherited = (a.present & inherited_mask) != (b.present & inherited_mask)
                || a.colors[0] != b.colors[0]
                || a.numbers[10..12] != b.numbers[10..12]
                || a.weight != b.weight;
            let layout = (a.present & layout_mask) != (b.present & layout_mask)
                || a.width != b.width
                || a.height != b.height
                || a.numbers[..8] != b.numbers[..8]
                || a.align != b.align
                || a.justify != b.justify
                || a.overflow != b.overflow;
            let reason = if inherited {
                DirtyReason::InheritedStyle
            } else if layout {
                DirtyReason::ExternalLayout
            } else if old.children != new.children {
                DirtyReason::Children
            } else {
                DirtyReason::Content
            };
            if inherited || layout {
                for (id, boundary) in &self.boundaries {
                    let mut ancestor = boundary.root_handle;
                    for _ in 0..LEAF_V2_MAX_DEPTH {
                        if ancestor == *handle {
                            dirty.insert(*id);
                            dirty_reasons
                                .entry(*id)
                                .and_modify(|r| *r = (*r).max(reason))
                                .or_insert(reason);
                            break;
                        }
                        ancestor = lookup(&self.nodes, &nodes, ancestor).map_or(0, |n| n.parent);
                        if ancestor == 0 {
                            break;
                        }
                    }
                }
            }
            for id in &dirty {
                dirty_reasons
                    .entry(*id)
                    .and_modify(|r| *r = (*r).max(reason))
                    .or_insert(reason);
            }
        }
        self.inputs
            .try_reserve(nodes.len())
            .map_err(|_| bad("input index reservation failed"))?;
        self.lists
            .try_reserve(nodes.len())
            .map_err(|_| bad("list index reservation failed"))?;
        let boundary_roots = root_edits
            .into_iter()
            .map(|(id, ids)| (id, Rc::from(ids)))
            .collect();
        self.boundary_roots
            .try_reserve(boundaries.len() * 2)
            .map_err(|_| bad("boundary index reservation failed"))?;
        self.nodes
            .try_reserve(creates.len())
            .map_err(|_| bad("host reservation failed"))?;
        self.boundaries
            .try_reserve(boundaries.len())
            .map_err(|_| bad("boundary reservation failed"))?;
        stats.owned_nodes = nodes.len() as u64;
        self.prepared = Some(Prepared {
            nodes,
            boundaries,
            window,
            boundary_roots,
            dirty: dirty.into_iter().collect(),
            dirty_reasons,
            root: roots.iter().next().copied().unwrap_or(0),
            count,
            bytes,
            revision: data.header.next_revision,
            epoch: self.epoch,
            applied: false,
            stats,
        });
        Ok(())
    }
    pub fn apply(&mut self) -> Result<(), AbiError> {
        if self.disposed {
            return Err(bad("disposed host session"));
        }
        let prepared = self
            .prepared
            .as_mut()
            .ok_or_else(|| bad("no prepared batch"))?;
        if prepared.epoch != self.epoch {
            return Err(bad("stale prepared session"));
        }
        prepared.applied = true;
        Ok(())
    }
    /// No allocation, callbacks, GPUI operations, or fallible validation here.
    pub fn accept(&mut self, revision: u64) -> bool {
        if self.disposed
            || self
                .prepared
                .as_ref()
                .is_none_or(|p| !p.applied || p.epoch != self.epoch || p.revision != revision)
        {
            return false;
        }
        let prepared = self.prepared.take().unwrap();
        for (id, node) in prepared.nodes {
            match node {
                Some(node) => {
                    if node.kind == 4 {
                        self.inputs.insert(id);
                    }
                    if node.kind == 11 {
                        self.lists.insert(id);
                    }
                    self.nodes.insert(id, node);
                }
                None => {
                    self.nodes.remove(&id);
                    self.inputs.remove(&id);
                    self.lists.remove(&id);
                }
            }
        }
        for (id, boundary) in prepared.boundaries {
            match boundary {
                Some(boundary) => {
                    self.boundaries.insert(id, boundary);
                }
                None => {
                    self.boundaries.remove(&id);
                }
            }
        }
        for (root, ids) in prepared.boundary_roots {
            if ids.is_empty() {
                self.boundary_roots.remove(&root);
            } else {
                self.boundary_roots.insert(root, ids);
            }
        }
        for (id, reason) in prepared.dirty_reasons {
            if let Some(boundary) = self.boundaries.get_mut(&id) {
                boundary.revision = revision;
                boundary.dirty_reason = reason;
                if let Some(node) = self.nodes.get(&boundary.root_handle) {
                    boundary.layout_style = node.props.values;
                }
            }
        }
        self.dirty = prepared.dirty;
        if let Some(window) = prepared.window {
            self.window = Some(window);
        }
        self.root = prepared.root;
        self.bytes = prepared.bytes;
        self.revision = revision;
        debug_assert_eq!(self.nodes.len(), prepared.count);
        true
    }
    pub fn discard(&mut self) {
        self.prepared = None;
    }
    pub fn dispose(&mut self) {
        self.disposed = true;
        self.epoch = self.epoch.wrapping_add(1);
        self.discard();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn stage(
        store: &mut HostStore,
        ops: &[LeafOp],
        children: &[u64],
        text: &str,
    ) -> Result<(), AbiError> {
        let batch = LeafBatch {
            struct_size: size_of::<LeafBatch>() as u32,
            abi: 2,
            session_id: 9,
            base_revision: store.revision(),
            next_revision: store.revision() + 1,
            ops: ops.as_ptr(),
            ops_len: ops.len() as u64,
            children: children.as_ptr(),
            children_len: children.len() as u64,
            strings: text.as_ptr(),
            strings_len: text.len() as u64,
        };
        store.prepare(&unsafe { decode_batch(&batch) }?)
    }
    fn create(id: u64, parent: u64) -> LeafOp {
        LeafOp {
            tag: 1,
            kind: if parent == 0 { 0 } else { 2 },
            handle: id,
            parent,
            ..Default::default()
        }
    }
    fn order(parent: u64, count: u64) -> LeafOp {
        LeafOp {
            tag: 3,
            handle: parent,
            children: LeafSpan {
                offset: 0,
                len: count,
            },
            ..Default::default()
        }
    }
    fn mounted(count: u64) -> HostStore {
        let mut store = HostStore::new(9);
        let mut ops = vec![create(1, 0)];
        ops.extend((2..count + 2).map(|id| create(id, 1)));
        ops.push(order(1, count));
        stage(&mut store, &ops, &(2..count + 2).collect::<Vec<_>>(), "").unwrap();
        store.apply().unwrap();
        assert!(store.accept(1));
        store
    }
    #[test]
    fn owns_strings_and_publishes_only_after_accept() {
        let mut store = mounted(1);
        let revision = store.revision();
        let mut op = LeafOp {
            tag: 2,
            kind: 2,
            handle: 2,
            parent: 1,
            ..Default::default()
        };
        op.props.text = LeafSpan { offset: 0, len: 6 };
        {
            let text = String::from("你好");
            stage(&mut store, &[op], &[], &text).unwrap();
        }
        assert_eq!(store.node(2).unwrap().props.text, "");
        store.apply().unwrap();
        assert_eq!(store.revision(), revision);
        assert!(store.accept(revision + 1));
        assert_eq!(store.node(2).unwrap().props.text, "你好");
        assert_eq!(store.revision(), revision + 1);
        stage(&mut store, &[op], &[], "别的").unwrap();
        store.apply().unwrap();
        store.discard();
        assert_eq!(store.node(2).unwrap().props.text, "你好");
    }
    #[test]
    fn rejects_bad_graphs_and_sessions_without_changing_accepted_graph() {
        let mut store = mounted(2);
        let revision = store.revision();
        for ops in [
            vec![create(2, 1)],
            vec![LeafOp {
                tag: 2,
                kind: 3,
                handle: 2,
                parent: 1,
                ..Default::default()
            }],
            vec![LeafOp {
                tag: 4,
                handle: 99,
                ..Default::default()
            }],
            vec![LeafOp {
                tag: 5,
                boundary_id: 1,
                handle: 99,
                ..Default::default()
            }],
        ] {
            assert!(stage(&mut store, &ops, &[], "").is_err());
            assert_eq!(store.revision(), revision);
        }
        assert!(stage(&mut store, &[order(1, 2)], &[2, 2], "").is_err());
        // Reparent root under its own descendant: a cycle, not a second tree.
        let cycle = [
            LeafOp {
                tag: 2,
                handle: 1,
                parent: 2,
                ..Default::default()
            },
            order(1, 1),
            order(2, 1),
        ];
        assert!(stage(&mut store, &cycle, &[2], "").is_err());
        let batch = LeafBatch {
            struct_size: size_of::<LeafBatch>() as u32,
            abi: 2,
            session_id: 8,
            base_revision: revision,
            next_revision: revision + 1,
            ..Default::default()
        };
        assert!(
            store
                .prepare(&unsafe { decode_batch(&batch) }.unwrap())
                .is_err()
        );
        let batch = LeafBatch {
            session_id: 9,
            base_revision: 0,
            ..batch
        };
        assert!(
            store
                .prepare(&unsafe { decode_batch(&batch) }.unwrap())
                .is_err()
        );
        stage(&mut store, &[], &[], "").unwrap();
        store.apply().unwrap();
        store.dispose();
        assert!(!store.accept(revision + 1));
        assert!(stage(&mut store, &[], &[], "").is_err());
    }
    #[test]
    fn final_order_and_local_update_cost_do_not_scan_static_siblings() {
        let mut costs = vec![];
        for count in [100, 5000] {
            let mut store = mounted(count);
            let mut op = LeafOp {
                tag: 2,
                kind: 2,
                handle: 2,
                parent: 1,
                ..Default::default()
            };
            op.props.text = LeafSpan { offset: 0, len: 1 };
            stage(&mut store, &[op], &[], "1").unwrap();
            costs.push(store.prepared_stats().unwrap().visited_nodes);
            store.apply().unwrap();
            assert!(store.accept(2));
            let reversed = (2..count + 2).rev().collect::<Vec<_>>();
            stage(&mut store, &[order(1, count)], &reversed, "").unwrap();
            store.apply().unwrap();
            assert!(store.accept(3));
            assert_eq!(
                store.node(1).unwrap().children.as_ref(),
                reversed.as_slice()
            );
        }
        assert_eq!(costs[0], costs[1]);
        assert!(costs[0] <= 8);
    }
    #[test]
    fn rejects_multiple_parents_depth_and_dangling_boundaries() {
        let mut store = mounted(2);
        let ops = [order(2, 1)];
        assert!(stage(&mut store, &ops, &[3], "").is_err());
        let ops = [LeafOp {
            tag: 5,
            boundary_id: 1,
            handle: 2,
            ..Default::default()
        }];
        stage(&mut store, &ops, &[], "").unwrap();
        store.apply().unwrap();
        assert!(store.accept(2));
        assert!(
            stage(
                &mut store,
                &[
                    LeafOp {
                        tag: 4,
                        handle: 2,
                        ..Default::default()
                    },
                    order(1, 1)
                ],
                &[3],
                ""
            )
            .is_err()
        );
        let mut deep = HostStore::new(9);
        let mut ops = vec![];
        let mut children = vec![];
        for id in 1..=65 {
            ops.push(create(id, if id == 1 { 0 } else { id - 1 }));
            if id < 65 {
                ops.push(LeafOp {
                    children: LeafSpan {
                        offset: children.len() as u64,
                        len: 1,
                    },
                    ..order(id, 1)
                });
                children.push(id + 1);
            }
        }
        assert!(stage(&mut deep, &ops, &children, "").is_err());
    }
}
