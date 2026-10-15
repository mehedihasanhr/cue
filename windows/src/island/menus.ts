// Context menus as plain data — titles, actions, submenus, ticks — popped up as the
// system's own menus, as the Mac's cards do.

import { CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu } from "@tauri-apps/api/menu";

export type MenuEntry =
  | "-"
  | null
  | false
  | undefined
  | { text: string; action?: () => void; enabled?: boolean; checked?: boolean; items?: MenuEntry[] };

async function build(entries: MenuEntry[]): Promise<(MenuItem | Submenu | PredefinedMenuItem | CheckMenuItem)[]> {
  const out: (MenuItem | Submenu | PredefinedMenuItem | CheckMenuItem)[] = [];
  const kept = entries.filter((e): e is Exclude<MenuEntry, null | false | undefined> => !!e);
  // No separator first, last, or twice in a row.
  const cleaned = kept.filter((e, i) => e !== "-" || (i > 0 && i < kept.length - 1 && kept[i - 1] !== "-"));
  for (const entry of cleaned) {
    if (entry === "-") {
      out.push(await PredefinedMenuItem.new({ item: "Separator" }));
    } else if (entry.items) {
      const items = await build(entry.items);
      out.push(await Submenu.new({ text: entry.text, items, enabled: entry.enabled ?? items.length > 0 }));
    } else if (entry.checked !== undefined) {
      out.push(await CheckMenuItem.new({ text: entry.text, checked: entry.checked, enabled: entry.enabled ?? true, action: entry.action }));
    } else {
      out.push(await MenuItem.new({ text: entry.text, enabled: entry.enabled ?? true, action: entry.action }));
    }
  }
  return out;
}

/** Shows `entries` at the pointer; `onOpen` hears it open and close, so the island stays put. */
export async function popup(entries: MenuEntry[], onOpen?: (open: boolean) => void) {
  const menu = await Menu.new({ items: await build(entries) });
  onOpen?.(true);
  try {
    await menu.popup();
  } finally {
    onOpen?.(false);
  }
}
