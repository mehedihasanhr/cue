// The Tasks tab — the Mac's `IslandTasks`: projects as cards or a tree, then a project's
// tasks grouped by status, each a 26-point row with its status, priority and menus.

import { useState } from "react";
import { Icon, STROKE } from "../ui/icon";
import { relative } from "./answers";
import {
  firstLine,
  NEXT_STATUS,
  PRIORITY_COLORS,
  PRIORITY_ORDER,
  PRIORITY_SYMBOLS,
  PRIORITY_TITLES,
  STATUS_COLORS,
  STATUS_ORDER,
  STATUS_TITLES,
  store,
  type Priority,
  type Project,
  type TaskItem,
  type TaskStatus,
} from "./data";
import { popup, type MenuEntry } from "./menus";
import type { Prompt } from "./Prompt";

type Filter = "active" | "all" | TaskStatus;
const FILTER_TITLES: Record<Filter, string> = { active: "Active", all: "All", ...STATUS_TITLES };
type View = { kind: "projects" } | { kind: "all" } | { kind: "project"; id: string };

const load = <T,>(key: string, fallback: T): T => {
  try {
    return (localStorage.getItem(key) as T) ?? fallback;
  } catch {
    return fallback;
  }
};
const remember = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* a convenience */
  }
};

type Props = {
  tasks: TaskItem[];
  projects: Project[];
  onPrompt: (prompt: Prompt) => void;
  onMenu?: (open: boolean) => void;
  onStatus: (title: string, symbol: "checkmark.circle.fill" | "trash.fill") => void;
};

export function TasksView({ tasks, projects, onPrompt, onMenu, onStatus }: Props) {
  const [view, setView] = useState<View>(() => (load<string>("tasks.view", "projects") === "all" ? { kind: "all" } : { kind: "projects" }));
  const [filter, setFilterState] = useState<Filter>(() => load<Filter>("tasks.filter", "active"));
  const [layout, setLayoutState] = useState<"grid" | "list">(() => load("tasks.projectLayout", "grid"));
  const setFilter = (f: Filter) => {
    setFilterState(f);
    remember("tasks.filter", f);
  };
  const setLayout = (l: "grid" | "list") => {
    setLayoutState(l);
    remember("tasks.projectLayout", l);
  };
  const go = (v: View) => {
    setView(v);
    remember("tasks.view", v.kind === "all" ? "all" : "projects");
  };

  const project = view.kind === "project" ? projects.find((p) => p.id === view.id) : undefined;
  const children = (parent?: string) => projects.filter((p) => (p.parentID ?? undefined) === parent);
  const path = (p: Project): Project[] => {
    const parent = projects.find((x) => x.id === p.parentID);
    return parent ? [...path(parent), p] : [p];
  };
  const pathName = (id?: string) => {
    const p = projects.find((x) => x.id === id);
    return p ? path(p).map((x) => x.name).join(" › ") : "";
  };
  /** A project and everything under it. */
  const subtree = (id: string): string[] => [id, ...children(id).flatMap((c) => subtree(c.id))];

  const now = () => new Date().toISOString();
  const setStatus = (task: TaskItem, status: TaskStatus) => {
    store.update("tasks", task.id, { status, updatedAt: now() });
    if (status === "complete") onStatus("Task complete", "checkmark.circle.fill");
  };
  const setPriority = (task: TaskItem, priority: Priority) => store.update("tasks", task.id, { priority, updatedAt: now() });

  const newTask = (projectID?: string) =>
    onPrompt({
      type: "task",
      title: "New task",
      projects,
      initial: { text: "", projectID, priority: "medium" },
      onSubmit: (t) => store.put("tasks", { text: t.text, projectID: t.projectID, priority: t.priority, status: "pending", updatedAt: now() }),
    });
  const editTask = (task: TaskItem) =>
    onPrompt({
      type: "task",
      title: "Edit task",
      projects,
      initial: { text: task.text, projectID: task.projectID, priority: task.priority },
      onSubmit: (t) => store.update("tasks", task.id, { text: t.text, projectID: t.projectID ?? null, priority: t.priority, updatedAt: now() }),
    });
  const renameTask = (task: TaskItem) => {
    const [title, ...rest] = task.text.split("\n");
    onPrompt({
      type: "field",
      title: "Rename task",
      initial: title,
      onSubmit: (value) => store.update("tasks", task.id, { text: [value, ...rest].join("\n"), updatedAt: now() }),
    });
  };
  const deleteTask = (task: TaskItem) =>
    onPrompt({
      type: "confirm",
      title: "Delete this task?",
      message: firstLine(task.text),
      confirm: "Delete",
      onConfirm: () => {
        store.remove("tasks", [task.id]);
        onStatus("Task deleted", "trash.fill");
      },
    });
  const newProject = (parentID?: string) =>
    onPrompt({
      type: "field",
      title: parentID ? `New sub-project in ${pathName(parentID)}` : "New project",
      placeholder: "Name",
      submit: "Create",
      onSubmit: (name) => store.put("projects", { name, parentID }),
    });
  const deleteProject = (p: Project) =>
    onPrompt({
      type: "confirm",
      title: "Delete this project?",
      message: "Its tasks stay, with no project.",
      confirm: "Delete",
      onConfirm: () => {
        store.remove("projects", [p.id]);
        if (view.kind === "project" && view.id === p.id) go({ kind: "projects" });
      },
    });

  const statusMenu = (task: TaskItem): MenuEntry[] =>
    STATUS_ORDER.map((s) => ({ text: STATUS_TITLES[s], checked: task.status === s, action: () => setStatus(task, s) }));
  const priorityMenu = (task: TaskItem): MenuEntry[] =>
    PRIORITY_ORDER.map((p) => ({ text: PRIORITY_TITLES[p], checked: task.priority === p, action: () => setPriority(task, p) }));
  const rowMenu = (task: TaskItem): MenuEntry[] => [
    ...statusMenu(task),
    { text: "Priority", items: priorityMenu(task) },
    "-",
    { text: "Edit…", action: () => editTask(task) },
    { text: "Rename…", action: () => renameTask(task) },
    {
      text: "Move to",
      items: [
        { text: "No project", checked: !task.projectID, action: () => store.update("tasks", task.id, { projectID: null, updatedAt: now() }) },
        "-",
        ...projects.map((p) => ({ text: pathName(p.id), checked: task.projectID === p.id, action: () => store.update("tasks", task.id, { projectID: p.id, updatedAt: now() }) })),
      ],
    },
    "-",
    { text: "Delete…", action: () => deleteTask(task) },
  ];
  const show = (e: React.MouseEvent, entries: MenuEntry[]) => {
    e.preventDefault();
    e.stopPropagation();
    popup(entries, onMenu);
  };

  // MARK: Header

  const header = (
    <div className="tasks-header">
      <button className="crumb" onClick={() => go({ kind: "projects" })} disabled={view.kind === "projects"}>
        {view.kind !== "projects" && <Icon name="chevron.left" size={10} weight={STROKE.bold} />}
        Projects
      </button>
      {view.kind === "all" && <span className="crumb-tail">› All tasks</span>}
      {project &&
        path(project).map((p) => (
          <button key={p.id} className="crumb-tail link" onClick={() => go({ kind: "project", id: p.id })}>
            › {p.name}
          </button>
        ))}
      <span className="row-spacer" />
      {view.kind === "projects" ? (
        <>
          <button className="quiet-button" title={layout === "grid" ? "Show as a list" : "Show as cards"} onClick={() => setLayout(layout === "grid" ? "list" : "grid")}>
            <Icon name={layout === "grid" ? "list.bullet" : "square.grid.2x2"} size={13} />
          </button>
          <button className="quiet-button" title="New project" onClick={() => newProject()}>
            <Icon name="plus" size={13} weight={STROKE.bold} /> Project
          </button>
        </>
      ) : (
        <>
          <button
            className={`filter-pill ${filter !== "active" ? "on" : ""}`}
            onClick={(e) =>
              show(e, (["active", "all", ...STATUS_ORDER] as Filter[]).map((f) => ({ text: FILTER_TITLES[f], checked: filter === f, action: () => setFilter(f) })))
            }
          >
            {FILTER_TITLES[filter]}
            <Icon name="chevron.down" size={9} weight={STROKE.bold} />
          </button>
          {project && (
            <button className="quiet-button" title="New sub-project" onClick={() => newProject(project.id)}>
              <Icon name="folder.badge.plus" size={13} />
            </button>
          )}
          <button className="quiet-button" title="New task" onClick={() => newTask(project?.id)}>
            <Icon name="plus" size={13} weight={STROKE.bold} /> Task
          </button>
        </>
      )}
    </div>
  );

  // MARK: Projects

  if (view.kind === "projects") {
    const counts = (ids: string[]) => {
      const list = tasks.filter((t) => t.projectID && ids.includes(t.projectID));
      return { done: list.filter((t) => t.status === "complete").length, total: list.length };
    };
    const all = { done: tasks.filter((t) => t.status === "complete").length, total: tasks.length };
    const card = (title: string, c: { done: number; total: number }, subs: number, onOpen: () => void, menu?: MenuEntry[]) => (
      <button className="project-card" key={title} onClick={onOpen} onContextMenu={menu ? (e) => show(e, menu) : undefined}>
        <Icon name={menu ? "folder.fill" : "checklist"} size={18} />
        <span className="project-name">{title}</span>
        <span className="project-meta">
          {c.done}/{c.total} done{subs ? ` · ${subs} sub` : ""}
        </span>
        <span className="progress">
          <span style={{ width: `${c.total ? (c.done / c.total) * 100 : 0}%` }} />
        </span>
      </button>
    );
    const tree = (parent: string | undefined, depth: number): React.ReactNode[] =>
      children(parent).flatMap((p) => [
        <button
          key={p.id}
          className="project-row"
          style={{ paddingLeft: 10 + depth * 16 }}
          onClick={() => go({ kind: "project", id: p.id })}
          onContextMenu={(e) => show(e, [{ text: "New Sub-project…", action: () => newProject(p.id) }, { text: "Delete Project…", action: () => deleteProject(p) }])}
        >
          <Icon name="folder" size={12} /> {p.name}
          <span className="row-spacer" />
          <span className="project-meta">{counts(subtree(p.id)).done}/{counts(subtree(p.id)).total}</span>
        </button>,
        ...tree(p.id, depth + 1),
      ]);
    return (
      <div className="tasks">
        {header}
        {layout === "grid" ? (
          <div className="project-grid">
            {card("All tasks", all, 0, () => go({ kind: "all" }))}
            {children(undefined).map((p) =>
              card(p.name, counts(subtree(p.id)), children(p.id).length, () => go({ kind: "project", id: p.id }), [{ text: "Delete Project…", action: () => deleteProject(p) }]),
            )}
            {projects.length === 0 && <div className="tasks-empty inline">Add a project with + — or open All tasks.</div>}
          </div>
        ) : (
          <div className="task-list">
            <button className="project-row" onClick={() => go({ kind: "all" })}>
              <Icon name="checklist" size={12} /> All tasks
            </button>
            {tree(undefined, 0)}
            {projects.length === 0 && <div className="tasks-empty">Add a project with +.</div>}
          </div>
        )}
      </div>
    );
  }

  // MARK: Tasks

  const scope = project ? subtree(project.id) : null;
  const inScope = tasks.filter((t) => !scope || (t.projectID && scope.includes(t.projectID)));
  const shown = inScope.filter((t) => (filter === "all" ? true : filter === "active" ? t.status !== "complete" : t.status === filter));
  const sorted = (list: TaskItem[]) =>
    [...list].sort((a, b) => PRIORITY_ORDER.indexOf(a.priority) - PRIORITY_ORDER.indexOf(b.priority) || b.createdAt.localeCompare(a.createdAt));

  return (
    <div className="tasks">
      {header}
      {project && children(project.id).length > 0 && (
        <div className="subproject-pills">
          {children(project.id).map((p) => (
            <button key={p.id} className="chip" onClick={() => go({ kind: "project", id: p.id })}>
              <Icon name="folder" size={11} /> {p.name}
            </button>
          ))}
        </div>
      )}
      <div className="task-list">
        {shown.length === 0 && (
          <div className="tasks-empty">
            {inScope.length === 0 ? "No tasks yet — add one with +." : filter === "active" ? "Everything is complete." : `No ${FILTER_TITLES[filter].toLowerCase()} tasks.`}
          </div>
        )}
        {STATUS_ORDER.map((status) => {
          const group = sorted(shown.filter((t) => t.status === status));
          if (!group.length) return null;
          return (
            <section key={status}>
              <h4 className="status-head">
                {STATUS_TITLES[status]} <span className="count">{group.length}</span>
              </h4>
              {group.map((task) => {
                const [title, ...more] = task.text.split("\n");
                const elsewhere = task.projectID && task.projectID !== project?.id;
                return (
                  <div key={task.id} className="task-row" onContextMenu={(e) => show(e, rowMenu(task))}>
                    <button
                      className="status-icon"
                      style={{ color: STATUS_COLORS[task.status] }}
                      title={`Mark ${STATUS_TITLES[NEXT_STATUS[task.status]].toLowerCase()} — right-click for all`}
                      onClick={() => setStatus(task, NEXT_STATUS[task.status])}
                      onContextMenu={(e) => show(e, statusMenu(task))}
                    >
                      <Icon name={task.status === "complete" ? "checkmark.circle.fill" : task.status === "inProcess" ? "circle.lefthalf.filled" : "circle"} size={14} weight={STROKE.semibold} />
                    </button>
                    <button className={`task-title ${task.status === "complete" ? "done" : ""}`} onClick={() => editTask(task)}>
                      {firstLine(title) || "Untitled"}
                    </button>
                    {more.some((l) => l.trim()) && (
                      <span className="task-note" title="Has notes">
                        <Icon name="text.alignleft" size={10} />
                      </span>
                    )}
                    {elsewhere && <span className="project-pill">{pathName(task.projectID)}</span>}
                    <span className="row-spacer" />
                    <span className="task-date">{relative(new Date(task.updatedAt ?? task.createdAt))}</span>
                    <button className="priority-pill" style={{ color: PRIORITY_COLORS[task.priority] }} onClick={(e) => show(e, priorityMenu(task))}>
                      <Icon name={PRIORITY_SYMBOLS[task.priority]} size={10} weight={STROKE.bold} />
                      <span>{PRIORITY_TITLES[task.priority]}</span>
                    </button>
                    <button className="status-pill" style={{ color: STATUS_COLORS[task.status] }} onClick={(e) => show(e, statusMenu(task))}>
                      {STATUS_TITLES[task.status]}
                    </button>
                  </div>
                );
              })}
            </section>
          );
        })}
      </div>
    </div>
  );
}
