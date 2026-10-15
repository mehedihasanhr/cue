// Ways to paste or copy a text other than as it was copied — the Mac's
// `Clipboard/TextTransform.swift` — and the Extract menu's finds.

export const TRANSFORMS = [
  "plain", "trimmed", "oneLine", "lowercased", "uppercased", "titleCase", "sentenceCase",
  "camelCase", "snakeCase", "kebabCase", "jsonPretty", "jsonMinified", "urlEncoded", "urlDecoded", "markdownPlain", "quoted",
] as const;
export type Transform = (typeof TRANSFORMS)[number];

export const TRANSFORM_TITLES: Record<Transform, string> = {
  plain: "Plain text", trimmed: "Trimmed", oneLine: "One line", lowercased: "lowercase", uppercased: "UPPERCASE",
  titleCase: "Title Case", sentenceCase: "Sentence case", camelCase: "camelCase", snakeCase: "snake_case",
  kebabCase: "kebab-case", jsonPretty: "Pretty JSON", jsonMinified: "Minified JSON", urlEncoded: "URL-encoded",
  urlDecoded: "URL-decoded", markdownPlain: "Markdown → plain text", quoted: "Quoted (> …)",
};

const isLetter = (c: string) => /\p{L}/u.test(c);
const isLetterOrNumber = (c: string) => /[\p{L}\p{N}]/u.test(c);
const isLower = (c: string) => c !== c.toUpperCase() && c === c.toLowerCase();
const isUpper = (c: string) => c !== c.toLowerCase() && c === c.toUpperCase();

/** Words for the identifier cases: split on spaces, punctuation and camelCase humps. */
function words(text: string): string[] {
  const out: string[] = [];
  let current = "";
  let previous = "";
  for (const c of text) {
    if (isLetterOrNumber(c)) {
      if (previous && isLower(previous) && isUpper(c) && current) {
        out.push(current);
        current = "";
      }
      current += c;
    } else if (current) {
      out.push(current);
      current = "";
    }
    previous = c;
  }
  if (current) out.push(current);
  return out;
}

/** Swift's `capitalized`: each word's first letter up, the rest down. */
function capitalized(text: string): string {
  return text.toLowerCase().replace(/(^|[^\p{L}\p{N}'])(\p{L})/gu, (_, before: string, letter: string) => before + letter.toUpperCase());
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value as object).sort().map((k) => [k, sortKeys((value as Record<string, unknown>)[k])]));
  }
  return value;
}

function json(text: string, pretty: boolean): string | null {
  try {
    const value = sortKeys(JSON.parse(text));
    return pretty ? JSON.stringify(value, null, 2) : JSON.stringify(value);
  } catch {
    return null;
  }
}

function stripInlineMarkdown(line: string): string {
  return line
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/(\*|_)(.+?)\1/g, "$2")
    .replace(/~~(.+?)~~/g, "$1")
    .replace(/`([^`]*)`/g, "$1");
}

/** The transformed text, or null when it does not apply (not JSON, say). */
export function apply(transform: Transform, text: string): string | null {
  switch (transform) {
    case "plain": return text;
    case "trimmed": return text.trim();
    case "oneLine": return text.split(/\s+/).filter(Boolean).join(" ");
    case "lowercased": return text.toLowerCase();
    case "uppercased": return text.toUpperCase();
    case "titleCase": return capitalized(text);
    case "sentenceCase":
      return text
        .split("\n")
        .map((line) => {
          const lower = line.toLowerCase();
          const first = [...lower].findIndex(isLetter);
          if (first < 0) return lower;
          const chars = [...lower];
          chars[first] = chars[first].toUpperCase();
          return chars.join("");
        })
        .join("\n");
    case "camelCase": {
      const w = words(text);
      return w.length ? w.map((x, i) => (i === 0 ? x.toLowerCase() : capitalized(x))).join("") : null;
    }
    case "snakeCase": {
      const w = words(text);
      return w.length ? w.map((x) => x.toLowerCase()).join("_") : null;
    }
    case "kebabCase": {
      const w = words(text);
      return w.length ? w.map((x) => x.toLowerCase()).join("-") : null;
    }
    case "jsonPretty": return json(text, true);
    case "jsonMinified": return json(text, false);
    case "urlEncoded": return [...new TextEncoder().encode(text)].map((b) => {
      const c = String.fromCharCode(b);
      return /[A-Za-z0-9\-._~]/.test(c) ? c : "%" + b.toString(16).toUpperCase().padStart(2, "0");
    }).join("");
    case "urlDecoded":
      if (!text.includes("%") && !text.includes("+")) return null;
      try {
        return decodeURIComponent(text.replace(/\+/g, " "));
      } catch {
        return null;
      }
    case "markdownPlain": {
      if (![..."#*_`[>-"].some((c) => text.includes(c))) return null;
      return text
        .split("\n")
        .map((line) => stripInlineMarkdown(line.replace(/^\s*(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)/, "")))
        .filter((line) => line.trim().length > 0)
        .join("\n");
    }
    case "quoted": return text.split("\n").map((l) => `> ${l}`).join("\n");
  }
}

/** The transforms that would change (or apply to) this text, in menu order. */
export function applicable(text: string): Transform[] {
  return TRANSFORMS.filter((t) => {
    const result = apply(t, text);
    return result !== null && (t === "plain" || result !== text);
  });
}

/** The Extract menu: links, e-mail addresses and numbers in a text, each list deduplicated. */
export function extract(text: string): { title: string; values: string[] }[] {
  const unique = (list: string[]) => [...new Set(list)];
  const urls = unique(text.match(/\b(?:https?|ftp):\/\/[^\s<>"'`]+[^\s<>"'`.,;:!?)\]]/gi) ?? []);
  const emails = unique(text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) ?? []);
  const numbers = unique(text.match(/-?\d+(?:[.,]\d+)*/g) ?? []);
  return [
    { title: "URLs", values: urls },
    { title: "E-mail Addresses", values: emails },
    { title: "Numbers", values: numbers },
  ].filter((g) => g.values.length > 0);
}
