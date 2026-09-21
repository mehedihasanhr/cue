"""Reads icons out of an unpacked @hugeicons/core-free-icons npm package
(`npm pack @hugeicons/core-free-icons && tar xzf *.tgz`), whose path is $HUGEICONS.
"""
import re, json, pathlib, sys, os
ROOT = pathlib.Path(os.environ.get("HUGEICONS", "package")) / "dist/esm"

def elements(name):
    src = (ROOT / f"{name}Icon.js").read_text()
    body = src[src.index("= [") + 2 : src.index("];") + 1]
    # JS object literal -> JSON: quote keys
    body = re.sub(r'(\w+):\s', r'"\1": ', body)
    return json.loads(body)

def to_path(tag, a):
    if tag == "path":
        return a["d"]
    if tag == "circle":
        cx, cy, r = float(a["cx"]), float(a["cy"]), float(a["r"])
        return f"M{cx - r} {cy}A{r} {r} 0 1 0 {cx + r} {cy}A{r} {r} 0 1 0 {cx - r} {cy}Z"
    if tag == "ellipse":
        cx, cy, rx, ry = float(a["cx"]), float(a["cy"]), float(a["rx"]), float(a["ry"])
        return f"M{cx - rx} {cy}A{rx} {ry} 0 1 0 {cx + rx} {cy}A{rx} {ry} 0 1 0 {cx - rx} {cy}Z"
    if tag == "rect":
        x, y, w, h = (float(a.get(k, 0)) for k in ("x", "y", "width", "height"))
        rx = float(a.get("rx", 0)); ry = float(a.get("ry", rx))
        if rx == 0:
            return f"M{x} {y}H{x + w}V{y + h}H{x}Z"
        return (f"M{x + rx} {y}H{x + w - rx}A{rx} {ry} 0 0 1 {x + w} {y + ry}V{y + h - ry}A{rx} {ry} 0 0 1 {x + w - rx} {y + h}"
                f"H{x + rx}A{rx} {ry} 0 0 1 {x} {y + h - ry}V{y + ry}A{rx} {ry} 0 0 1 {x + rx} {y}Z")
    raise ValueError(tag)

def glyphs(name):
    out = []
    for tag, a in elements(name):
        filled = a.get("fill") not in (None, "none")
        stroked = a.get("stroke") not in (None, "none")
        out.append({"d": to_path(tag, a), "fill": filled, "stroke": stroked, "width": float(a.get("strokeWidth", 1.5))})
    return out

def svg(name):
    parts = []
    for g in glyphs(name):
        fill = "currentColor" if g["fill"] else "none"
        stroke = "currentColor" if g["stroke"] else "none"
        parts.append(f'<path d="{g["d"]}" fill="{fill}" stroke="{stroke}" stroke-width="{g["width"]}" stroke-linecap="round" stroke-linejoin="round"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="96" height="96" color="black">{"".join(parts)}</svg>'

if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1]); out.mkdir(exist_ok=True)
    for name in sys.argv[2:]:
        (out / f"{name}.svg").write_text(svg(name))
