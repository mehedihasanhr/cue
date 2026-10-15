// Context menus as plain data — titles, actions, submenus, ticks — popped up as the
// system's own menus, as the Mac's cards do.
//
// While a menu is open the island must not close under it. On the Mac `popup()` returns
// when the menu closes; on Windows it returns as soon as the menu is shown, and nothing
// says when it goes away. So a menu counts as open until one of its items is chosen, or
// until the island sees the click that dismissed it (`menuDismissed`).

import { CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu } from "@tauri-apps/api/menu";

export type MenuEntry =
  | "-"
  | null
  | false
  | undefined
  | { text: string; action?: () => void; enabled?: boolean; checked?: boolean; items?: MenuEntry[] };

async function build(entries: MenuEntry[], chosen: () => void): Promise<(MenuItem | Submenu | PredefinedMenuItem | CheckMenuItem)[]> {
  const out: (MenuItem | Submenu | PredefinedMenuItem | CheckMenuItem)[] = [];
  const kept = entries.filter((e): e is Exclude<MenuEntry, null | false | undefined> => !!e);
  // No separator first, last, or twice in a row.
  const cleaned = kept.filter((e, i) => e !== "-" || (i > 0 && i < kept.length - 1 && kept[i - 1] !== "-"));
  for (const entry of cleaned) {
    const action = entry !== "-" && entry.action
      ? () => {
          chosen();
          entry.action!();
        }
      : undefined;
    if (entry === "-") {
      out.push(await PredefinedMenuItem.new({ item: "Separator" }));
    } else if (entry.items) {
      const items = await build(entry.items, chosen);
      out.push(await Submenu.new({ text: entry.text, items, enabled: entry.enabled ?? items.length > 0 }));
    } else if (entry.checked !== undefined) {
      out.push(await CheckMenuItem.new({ text: entry.text, checked: entry.checked, enabled: entry.enabled ?? true, action }));
    } else {
      out.push(await MenuItem.new({ text: entry.text, enabled: entry.enabled ?? true, action }));
    }
  }
  return out;
}

/** The menu shown now, and how to say it has gone. */
let current: { close: () => void } | null = null;

/** The island saw a click outside it while a menu was up: that click closed the menu. */
export function menuDismissed() {
  current?.close();
}

export function menuIsOpen(): boolean {
  return current !== null;
}

/** Shows `entries` at the pointer; `onOpen` hears it open and close, so the island stays put. */
export async function popup(entries: MenuEntry[], onOpen?: (open: boolean) => void) {
  current?.close();
  let open = true;
  const state = {
    close: () => {
      if (!open) return;
      open = false;
      if (current === state) current = null;
      onOpen?.(false);
    },
  };
  current = state;
  onOpen?.(true);
  const menu = await Menu.new({ items: await build(entries, () => state.close()) });
  const started = performance.now();
  try {
    await menu.popup();
  } catch {
    state.close();
    return;
  }
  // Where `popup()` waits for the menu to close (the Mac), it has closed now. Where it
  // returns at once (Windows), the menu is still up: wait for a choice or a click.
  if (performance.now() - started > 250) state.close();
}
