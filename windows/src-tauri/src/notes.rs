//! Notes: Markdown files in a folder — the Mac's `NoteStore`. A note's id is its file
//! name without `.md`, and the file is named after the note's first line, so the folder
//! reads well in Explorer or in Obsidian.

use anyhow::{Context, Result};
use chrono::{DateTime, Local, Utc};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub text: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub fn folder(roaming: &Path) -> PathBuf {
    roaming.join("Notes")
}

/// Every note, the most recently changed first.
pub fn list(folder: &Path) -> Vec<Note> {
    let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut notes: Vec<Note> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("md")))
        .filter_map(|path| {
            let text = std::fs::read_to_string(&path).ok()?;
            let meta = std::fs::metadata(&path).ok()?;
            let updated: DateTime<Utc> = meta.modified().ok()?.into();
            let created: DateTime<Utc> = meta.created().map(Into::into).unwrap_or(updated);
            Some(Note { id: path.file_stem()?.to_string_lossy().into_owned(), text, created_at: created, updated_at: updated })
        })
        .collect();
    notes.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    notes
}

/// The first line that says something, with the Markdown taken off.
pub fn title(text: &str) -> String {
    text.lines()
        .map(|l| l.trim().trim_start_matches('#').trim_start_matches(['-', '*', '>', ' ']).trim())
        .find(|l| !l.is_empty())
        .map(|l| l.replace("**", "").replace('`', ""))
        .unwrap_or_default()
}

fn file_stem_for(text: &str) -> String {
    let clean: String = title(text).chars().filter(|c| !r#"<>:"/\|?*"#.contains(*c) && !c.is_control()).collect();
    let clean = clean.trim().trim_end_matches('.').to_string();
    if clean.is_empty() {
        format!("Note {}", Local::now().format("%Y-%m-%d %H.%M"))
    } else {
        clean.chars().take(80).collect()
    }
}

/// Saves a note — a new one when `id` is `None` — renaming its file to follow its title.
/// Returns its id.
pub fn save(folder: &Path, id: Option<&str>, text: &str) -> Result<String> {
    std::fs::create_dir_all(folder)?;
    let stem = file_stem_for(text);
    let current = id.map(|id| folder.join(format!("{id}.md")));
    let mut target = folder.join(format!("{stem}.md"));
    if current.as_ref() != Some(&target) {
        let mut n = 2;
        while target.exists() {
            target = folder.join(format!("{stem} {n}.md"));
            n += 1;
        }
    }
    if let Some(current) = current.filter(|c| c.exists() && *c != target) {
        std::fs::rename(&current, &target).context("Could not rename the note")?;
    }
    std::fs::write(&target, text).context("Could not save the note")?;
    Ok(target.file_stem().unwrap().to_string_lossy().into_owned())
}

pub fn delete(folder: &Path, id: &str) -> Result<()> {
    let path = folder.join(format!("{id}.md"));
    trash::delete(&path).or_else(|_| std::fs::remove_file(&path).map_err(|e| trash::Error::Unknown { description: e.to_string() }))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_files_after_the_title() {
        let dir = std::env::temp_dir().join(format!("cue-notes-{}", uuid::Uuid::new_v4()));
        let id = save(&dir, None, "# Shopping: list\n- milk").unwrap();
        assert_eq!(id, "Shopping list");
        let again = save(&dir, Some(&id), "# Groceries\n- milk").unwrap();
        assert_eq!(again, "Groceries");
        assert_eq!(list(&dir).len(), 1);
        let second = save(&dir, None, "Groceries").unwrap();
        assert_eq!(second, "Groceries 2");
        std::fs::remove_dir_all(dir).ok();
    }
}
