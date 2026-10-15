// The island's compact forms — the Mac's prompt phase: a line of text to name or rename
// something, a delete to confirm, and the forms for a snippet, a note or a task.
// ↩ saves, ⎋ cancels.

import { useEffect, useRef, useState } from "react";
import { Icon, STROKE } from "../ui/icon";
import { PRIORITY_COLORS, PRIORITY_ORDER, PRIORITY_SYMBOLS, PRIORITY_TITLES, type Priority, type Project } from "./data";

export type Prompt =
  | { type: "field"; title: string; placeholder?: string; initial?: string; submit?: string; onSubmit: (value: string) => void }
  | { type: "confirm"; title: string; message?: string; confirm: string; onConfirm: () => void }
  | { type: "snippet"; title: string; initial?: { keyword: string; name: string; text: string }; onSubmit: (s: { keyword: string; name: string; text: string }) => void }
  | { type: "note"; title: string; initial?: string; onSubmit: (text: string) => void }
  | {
      type: "task";
      title: string;
      initial?: { text: string; projectID?: string; priority: Priority };
      projects: Project[];
      onSubmit: (t: { text: string; projectID?: string; priority: Priority }) => void;
    };

/** The content size each form takes on the island. */
export function promptSize(prompt: Prompt): { width: number; height: number } {
  return prompt.type === "field" || prompt.type === "confirm" ? { width: 460, height: 64 } : { width: 460, height: 300 };
}

export function PromptView({ prompt, onClose }: { prompt: Prompt; onClose: () => void }) {
  const cancelOnEscape = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      onClose();
    }
  };
  switch (prompt.type) {
    case "field":
      return <FieldPrompt prompt={prompt} onClose={onClose} onKey={cancelOnEscape} />;
    case "confirm":
      return <ConfirmPrompt prompt={prompt} onClose={onClose} />;
    case "snippet":
      return <SnippetForm prompt={prompt} onClose={onClose} onKey={cancelOnEscape} />;
    case "note":
      return <NoteForm prompt={prompt} onClose={onClose} onKey={cancelOnEscape} />;
    case "task":
      return <TaskForm prompt={prompt} onClose={onClose} onKey={cancelOnEscape} />;
  }
}

function FieldPrompt({ prompt, onClose, onKey }: { prompt: Extract<Prompt, { type: "field" }>; onClose: () => void; onKey: (e: React.KeyboardEvent) => void }) {
  const [value, setValue] = useState(prompt.initial ?? "");
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    input.current?.focus();
    input.current?.select();
  }, []);
  const submit = () => {
    if (!value.trim()) return;
    prompt.onSubmit(value.trim());
    onClose();
  };
  return (
    <div className="prompt-row" onKeyDown={onKey}>
      <span className="prompt-title">{prompt.title}</span>
      <input
        ref={input}
        className="prompt-field"
        value={value}
        placeholder={prompt.placeholder}
        spellCheck={false}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => e.key === "Enter" && submit()}
      />
      <button className="prompt-button primary" disabled={!value.trim()} onClick={submit}>
        {prompt.submit ?? "Save"}
      </button>
    </div>
  );
}

function ConfirmPrompt({ prompt, onClose }: { prompt: Extract<Prompt, { type: "confirm" }>; onClose: () => void }) {
  const confirm = useRef<HTMLButtonElement>(null);
  useEffect(() => confirm.current?.focus(), []);
  const go = () => {
    prompt.onConfirm();
    onClose();
  };
  return (
    <div
      className="prompt-row"
      tabIndex={-1}
      onKeyDown={(e) => {
        if (e.key === "Escape") onClose();
        if (e.key === "Enter") go();
      }}
    >
      <div className="prompt-text">
        <span className="prompt-title">{prompt.title}</span>
        {prompt.message && <span className="prompt-message">{prompt.message}</span>}
      </div>
      <span className="row-spacer" />
      <button className="prompt-button" onClick={onClose}>Cancel</button>
      <button ref={confirm} className="prompt-button destructive" onClick={go}>{prompt.confirm}</button>
    </div>
  );
}

function FormFrame(props: { title: string; children: React.ReactNode; onSave: () => void; canSave: boolean; onClose: () => void; onKey: (e: React.KeyboardEvent) => void; hint?: string }) {
  return (
    <div
      className="prompt-form"
      onKeyDown={(e) => {
        props.onKey(e);
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && props.canSave) props.onSave();
      }}
    >
      <div className="form-head">
        <span className="prompt-title">{props.title}</span>
        <span className="row-spacer" />
        {props.hint && <span className="form-hint">{props.hint}</span>}
      </div>
      <div className="form-body">{props.children}</div>
      <div className="form-foot">
        <span className="form-hint">Ctrl+Enter saves · Esc cancels</span>
        <span className="row-spacer" />
        <button className="prompt-button" onClick={props.onClose}>Cancel</button>
        <button className="prompt-button primary" disabled={!props.canSave} onClick={props.onSave}>Save</button>
      </div>
    </div>
  );
}

function SnippetForm({ prompt, onClose, onKey }: { prompt: Extract<Prompt, { type: "snippet" }>; onClose: () => void; onKey: (e: React.KeyboardEvent) => void }) {
  const [keyword, setKeyword] = useState(prompt.initial?.keyword ?? ";");
  const [name, setName] = useState(prompt.initial?.name ?? "");
  const [text, setText] = useState(prompt.initial?.text ?? "");
  const first = useRef<HTMLInputElement>(null);
  useEffect(() => {
    first.current?.focus();
    first.current?.setSelectionRange(keyword.length, keyword.length);
  }, []);
  const clean = keyword.replace(/\s/g, "");
  const canSave = clean.length > 1 && text.trim().length > 0;
  const save = () => {
    prompt.onSubmit({ keyword: clean, name: name.trim(), text });
    onClose();
  };
  return (
    <FormFrame title={prompt.title} onSave={save} canSave={canSave} onClose={onClose} onKey={onKey} hint="{{date}} {{time}} {{clipboard}} {{name}}">
      <div className="form-line">
        <input ref={first} className="prompt-field keyword" value={keyword} placeholder=";sig" spellCheck={false} onChange={(e) => setKeyword(e.target.value)} />
        <input className="prompt-field" value={name} placeholder="Name (optional)" spellCheck={false} onChange={(e) => setName(e.target.value)} />
      </div>
      <textarea className="prompt-area" value={text} placeholder="What the keyword turns into" spellCheck={false} onChange={(e) => setText(e.target.value)} />
    </FormFrame>
  );
}

function NoteForm({ prompt, onClose, onKey }: { prompt: Extract<Prompt, { type: "note" }>; onClose: () => void; onKey: (e: React.KeyboardEvent) => void }) {
  const [text, setText] = useState(prompt.initial ?? "");
  const area = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    area.current?.focus();
    area.current?.setSelectionRange(text.length, text.length);
  }, []);
  const save = () => {
    prompt.onSubmit(text);
    onClose();
  };
  return (
    <FormFrame title={prompt.title} onSave={save} canSave={text.trim().length > 0} onClose={onClose} onKey={onKey} hint="Markdown">
      <textarea ref={area} className="prompt-area tall" value={text} placeholder="# Title&#10;Anything worth keeping…" spellCheck onChange={(e) => setText(e.target.value)} />
    </FormFrame>
  );
}

function TaskForm({ prompt, onClose, onKey }: { prompt: Extract<Prompt, { type: "task" }>; onClose: () => void; onKey: (e: React.KeyboardEvent) => void }) {
  const [text, setText] = useState(prompt.initial?.text ?? "");
  const [projectID, setProjectID] = useState(prompt.initial?.projectID ?? "");
  const [priority, setPriority] = useState<Priority>(prompt.initial?.priority ?? "medium");
  const area = useRef<HTMLTextAreaElement>(null);
  useEffect(() => area.current?.focus(), []);

  /** `#project` and `!priority` in the text set those fields, as on the Mac. */
  const parsed = () => {
    let body = text;
    let project = projectID || undefined;
    let level = priority;
    body = body.replace(/(^|\s)!(urgent|high|medium|low)\b/i, (_, space: string, p: string) => {
      level = p.toLowerCase() as Priority;
      return space;
    });
    body = body.replace(/(^|\s)#([\p{L}\p{N}_-]+)/u, (whole, space: string, name: string) => {
      const match = prompt.projects.find((p) => p.name.toLowerCase() === name.toLowerCase());
      if (!match) return whole;
      project = match.id;
      return space;
    });
    return { text: body.trim(), projectID: project, priority: level };
  };
  const save = () => {
    prompt.onSubmit(parsed());
    onClose();
  };
  return (
    <FormFrame title={prompt.title} onSave={save} canSave={text.trim().length > 0} onClose={onClose} hint="#project · !priority" onKey={(e) => {
      onKey(e);
      if (e.ctrlKey && ["1", "2", "3", "4"].includes(e.key)) {
        e.preventDefault();
        setPriority(PRIORITY_ORDER[Number(e.key) - 1]);
      }
    }}>
      <textarea ref={area} className="prompt-area" value={text} placeholder="What needs doing — the first line is its title" spellCheck onChange={(e) => setText(e.target.value)} />
      <div className="form-line">
        <select className="prompt-select" value={projectID} onChange={(e) => setProjectID(e.target.value)} aria-label="Project">
          <option value="">No project</option>
          {prompt.projects.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <div className="priority-picker" role="radiogroup" aria-label="Priority">
          {PRIORITY_ORDER.map((p, i) => (
            <button
              key={p}
              role="radio"
              aria-checked={priority === p}
              className={priority === p ? "on" : ""}
              title={`${PRIORITY_TITLES[p]} (Ctrl+${i + 1})`}
              onClick={() => setPriority(p)}
            >
              <span style={{ color: PRIORITY_COLORS[p] }}><Icon name={PRIORITY_SYMBOLS[p]} size={11} weight={STROKE.bold} /></span>
              {PRIORITY_TITLES[p]}
            </button>
          ))}
        </div>
      </div>
    </FormFrame>
  );
}
