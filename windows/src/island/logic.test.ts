import { describe, expect, it } from "vitest";
import { answers, evaluate } from "./answers";
import { format, parseHex } from "./colormath";
import { applicable, apply, extract } from "./transforms";

describe("colour formats (the Mac's ColorMath)", () => {
  const brand = parseHex("#0E4FEC")!;
  it("formats like the Mac", () => {
    expect(format(brand, "hex")).toBe("#0E4FEC");
    expect(format(brand, "rgb")).toBe("rgb(14, 79, 236)");
    expect(format(brand, "rgba")).toBe("rgba(14, 79, 236, 1)");
    expect(format(brand, "hsl")).toBe("hsl(222.4, 88.8%, 49%)");
    // The same float noise as the Mac: white's hue is not quite zero.
    expect(format({ red: 1, green: 1, blue: 1 }, "oklch")).toMatch(/^oklch\(100% 0 /);
    expect(format({ red: 0, green: 0, blue: 0 }, "cmyk")).toBe("cmyk(0%, 0%, 0%, 100%)");
    expect(format({ red: 1, green: 0, blue: 0 }, "swiftUI")).toBe("Color(red: 1, green: 0, blue: 0)");
  });
  it("parses short and long hex", () => {
    expect(parseHex("fff")).toEqual({ red: 1, green: 1, blue: 1, alpha: 1 });
    expect(parseHex("#00000080")?.alpha).toBeCloseTo(0.502, 3);
    expect(parseHex("#12345")).toBeNull();
  });
});

describe("text transforms", () => {
  it("changes case and shape", () => {
    expect(apply("camelCase", "user ID value")).toBe("userIdValue");
    expect(apply("snakeCase", "userID value")).toBe("user_id_value");
    expect(apply("kebabCase", "Hello, World")).toBe("hello-world");
    expect(apply("sentenceCase", "HELLO there\n  second LINE")).toBe("Hello there\n  Second line");
    expect(apply("titleCase", "hello wide world")).toBe("Hello Wide World");
    expect(apply("oneLine", "a\n  b\tc")).toBe("a b c");
  });
  it("handles JSON and URLs", () => {
    expect(apply("jsonMinified", '{ "b": 1, "a": [1, 2] }')).toBe('{"a":[1,2],"b":1}');
    expect(apply("jsonPretty", "not json")).toBeNull();
    expect(apply("urlEncoded", "a b&c")).toBe("a%20b%26c");
    expect(apply("urlDecoded", "a+b%26c")).toBe("a b&c");
    expect(apply("markdownPlain", "# Title\n\n- **bold** [link](http://x)")).toBe("Title\nbold link");
  });
  it("offers only what changes the text", () => {
    const offered = applicable("hello");
    expect(offered).toContain("plain");
    expect(offered).not.toContain("lowercased");
    expect(offered).not.toContain("jsonPretty");
  });
  it("extracts links, addresses and numbers", () => {
    const found = extract("Mail a@b.co or see https://cue.app/x. Costs 12.50 and 3");
    expect(found.map((g) => g.title)).toEqual(["URLs", "E-mail Addresses", "Numbers"]);
    expect(found[0].values).toEqual(["https://cue.app/x"]);
  });
});

describe("quick answers", () => {
  it("converts numbers between bases", () => {
    expect(answers("255").map((a) => a.value)).toEqual(["0xFF", "0b11111111", "0o377"]);
    expect(answers("0b1010")[0].value).toBe("10");
  });
  it("reads colours, lengths and timestamps", () => {
    expect(answers("#0e4fec")[1].value).toBe("rgb(14, 79, 236)");
    expect(answers("24px").map((a) => a.value)).toEqual(["1.5rem", "1.5em", "18pt"]);
    expect(answers("1700000000")[1].value).toBe("2023-11-14T22:13:20Z");
  });
  it("does sums and base64", () => {
    expect(answers("(3+4)*2")[0].value).toBe("14");
    expect(evaluate("2^10")).toBe(1024);
    expect(evaluate("1+")).toBeNull();
    expect(answers("b64 hello")[0].value).toBe("aGVsbG8=");
    expect(answers("decode aGVsbG8=")[0].value).toBe("hello");
  });
});
