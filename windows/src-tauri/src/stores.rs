//! The island's collections besides captures — clipboard history, colours, assets,
//! snippets, tasks, projects and groups — each a JSON array on disk with the Mac's field
//! names (`groupID`, `createdAt`, …), so the web side reads them as the Mac's views do.
//!
//! The items are kept as JSON values: what a card shows is the web side's business, and
//! the few rules that matter here — an id, the limits, what a delete takes with it — are
//! applied below. Every change is announced as `store-changed` with the collection's
//! name, and every window that shows one reloads it.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

pub const KINDS: &[&str] = &["clipboard", "colors", "assets", "snippets", "tasks", "projects", "groups"];

/// The most colours kept; the oldest unpinned ones go first (the Mac's `ColorStore.limit`).
const COLOR_LIMIT: usize = 500;

pub struct Stores {
    roaming: PathBuf,
    local: PathBuf,
    items: Mutex<HashMap<&'static str, Vec<Value>>>,
}

fn kind_name(kind: &str) -> Option<&'static str> {
    KINDS.iter().copied().find(|k| *k == kind)
}

impl Stores {
    pub fn open(roaming: &Path, local: &Path) -> Self {
        let stores = Self { roaming: roaming.to_path_buf(), local: local.to_path_buf(), items: Mutex::new(HashMap::new()) };
        let mut items = stores.items.lock().unwrap();
        for kind in KINDS {
            let list = std::fs::read(stores.path(kind))
                .ok()
                .and_then(|data| serde_json::from_slice::<Vec<Value>>(&data).ok())
                .unwrap_or_default();
            items.insert(kind, list);
        }
        drop(items);
        stores
    }

    /// Where a collection lives: the big or machine-bound ones (clipboard, assets) in
    /// Local, the rest in Roaming beside the settings.
    fn path(&self, kind: &str) -> PathBuf {
        match kind {
            "clipboard" => self.local.join("Clipboard").join("history.json"),
            "assets" => self.assets_folder().join("index.json"),
            "projects" => self.roaming.join("projects.json"),
            other => self.roaming.join(format!("{other}.json")),
        }
    }

    pub fn clipboard_folder(&self) -> PathBuf {
        self.local.join("Clipboard")
    }

    pub fn assets_folder(&self) -> PathBuf {
        self.local.join("Assets")
    }

    pub fn list(&self, kind: &str) -> Vec<Value> {
        kind_name(kind).and_then(|k| self.items.lock().unwrap().get(k).cloned()).unwrap_or_default()
    }

    pub fn get(&self, kind: &str, id: &str) -> Option<Value> {
        self.list(kind).into_iter().find(|item| id_of(item) == Some(id))
    }

    fn save(&self, kind: &str, list: &[Value]) {
        let path = self.path(kind);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let temporary = path.with_extension("json.tmp");
        if std::fs::write(&temporary, serde_json::to_vec(list).unwrap_or_default()).is_ok() {
            std::fs::rename(temporary, &path).ok();
        }
    }

    /// Runs `change` on a collection, saves it, and returns what `change` returned.
    pub fn modify<R>(&self, app: &AppHandle, kind: &str, change: impl FnOnce(&mut Vec<Value>) -> R) -> Option<R> {
        let kind = kind_name(kind)?;
        let mut items = self.items.lock().unwrap();
        let list = items.entry(kind).or_default();
        let result = change(list);
        self.save(kind, list);
        drop(items);
        app.emit("store-changed", kind).ok();
        Some(result)
    }

    /// Adds `item`, or replaces the one with its id. New items go first (newest first),
    /// except groups and projects, which keep the order they were made in.
    pub fn put(&self, app: &AppHandle, kind: &str, mut item: Value, limit: Option<usize>) -> Option<Value> {
        let object = item.as_object_mut()?;
        if !object.get("id").is_some_and(Value::is_string) {
            object.insert("id".into(), Value::String(uuid::Uuid::new_v4().to_string().to_uppercase()));
        }
        if !object.contains_key("createdAt") {
            object.insert("createdAt".into(), Value::String(chrono::Utc::now().to_rfc3339()));
        }
        let id = id_of(&item)?.to_string();
        let at_end = matches!(kind, "groups" | "projects");
        let limit = limit.or((kind == "colors").then_some(COLOR_LIMIT));
        let stored = item.clone();
        let removed = self.modify(app, kind, move |list| {
            if let Some(existing) = list.iter_mut().find(|i| id_of(i) == Some(&id)) {
                *existing = item;
            } else if at_end {
                list.push(item);
            } else {
                list.insert(0, item);
            }
            limit.map(|limit| trim(list, limit)).unwrap_or_default()
        })?;
        self.forget_files(kind, &removed);
        Some(stored)
    }

    /// Merges `patch` into the item `id`; a null in the patch removes that field.
    pub fn update(&self, app: &AppHandle, kind: &str, id: &str, patch: Map<String, Value>) -> Option<Value> {
        self.modify(app, kind, |list| {
            let item = list.iter_mut().find(|i| id_of(i) == Some(id))?;
            let object = item.as_object_mut()?;
            for (key, value) in patch {
                if key == "id" {
                    continue;
                }
                if value.is_null() {
                    object.remove(&key);
                } else {
                    object.insert(key, value);
                }
            }
            Some(item.clone())
        })
        .flatten()
    }

    /// Deletes the items `ids`, with their files; deleting a group ungroups its items.
    pub fn delete(&self, app: &AppHandle, kind: &str, ids: &[String]) {
        let removed = self
            .modify(app, kind, |list| {
                let (gone, kept): (Vec<Value>, Vec<Value>) =
                    std::mem::take(list).into_iter().partition(|i| id_of(i).is_some_and(|id| ids.iter().any(|x| x == id)));
                *list = kept;
                gone
            })
            .unwrap_or_default();
        self.forget_files(kind, &removed);
        if kind == "groups" {
            for group in ids {
                self.ungroup(app, group);
            }
        }
        if kind == "projects" {
            // Their tasks stay, with no project; their sub-projects move up a level.
            for project in ids {
                let clear = |list: &mut Vec<Value>, field: &str| {
                    for item in list.iter_mut() {
                        if item.get(field).and_then(Value::as_str) == Some(project) {
                            item.as_object_mut().map(|o| o.remove(field));
                        }
                    }
                };
                self.modify(app, "tasks", |list| clear(list, "projectID"));
                self.modify(app, "projects", |list| clear(list, "parentID"));
            }
        }
    }

    /// The Mac's "Clear Unpinned …": everything neither pinned nor in a group.
    pub fn clear_unpinned(&self, app: &AppHandle, kind: &str) {
        let ids: Vec<String> = self
            .list(kind)
            .iter()
            .filter(|i| !is_pinned(i) && i.get("groupID").and_then(Value::as_str).is_none())
            .filter_map(|i| id_of(i).map(String::from))
            .collect();
        self.delete(app, kind, &ids);
    }

    fn ungroup(&self, app: &AppHandle, group: &str) {
        for kind in ["clipboard", "colors", "assets"] {
            self.modify(app, kind, |list| {
                for item in list.iter_mut() {
                    if item.get("groupID").and_then(Value::as_str) == Some(group) {
                        item.as_object_mut().map(|o| o.remove("groupID"));
                    }
                }
            });
        }
        if let Ok(id) = uuid::Uuid::parse_str(group) {
            let state = app.state::<crate::state::AppState>();
            state.library.lock().unwrap().ungroup(id).ok();
            app.emit("library-changed", ()).ok();
        }
    }

    /// The files an item had: a clipboard picture, an asset's folder.
    fn forget_files(&self, kind: &str, removed: &[Value]) {
        for item in removed {
            let Some(id) = id_of(item) else { continue };
            match kind {
                "clipboard" => {
                    std::fs::remove_file(self.clipboard_folder().join(format!("{id}.png"))).ok();
                }
                "assets" => {
                    std::fs::remove_dir_all(self.assets_folder().join(id)).ok();
                }
                _ => {}
            }
        }
    }
}

pub fn id_of(item: &Value) -> Option<&str> {
    item.get("id").and_then(Value::as_str)
}

fn is_pinned(item: &Value) -> bool {
    item.get("pinned").and_then(Value::as_bool).unwrap_or(false)
}

/// Drops the oldest unpinned items past `limit`; returns them.
fn trim(list: &mut Vec<Value>, limit: usize) -> Vec<Value> {
    let mut removed = Vec::new();
    while list.len() > limit {
        let Some(index) = list.iter().rposition(|i| !is_pinned(i)) else { break };
        removed.push(list.remove(index));
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn trims_the_oldest_unpinned() {
        let mut list = vec![json!({"id": "a"}), json!({"id": "b", "pinned": true}), json!({"id": "c"}), json!({"id": "d", "pinned": true})];
        let removed = trim(&mut list, 2);
        assert_eq!(removed.iter().filter_map(id_of).collect::<Vec<_>>(), vec!["c", "a"]);
        assert_eq!(list.iter().filter_map(id_of).collect::<Vec<_>>(), vec!["b", "d"]);
    }
}
