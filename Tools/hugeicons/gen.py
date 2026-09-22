"""Writes Klik/Support/HugeIconGlyphs.swift from the icons Klik draws:
    HUGEICONS=/path/to/package python3 Tools/hugeicons/gen.py Klik/Support/HugeIconGlyphs.swift
Add a name to NAMES and an alias in Icon.swift to use a new icon."""
import pathlib, re, sys
from extract import glyphs
NAMES = """DashboardSquare01 Archive02 CheckList Album02 PaintBoard TextCreation Clipboard ClipboardPaste Clock01 Clock04
Pin PinOff PlusSign PlusSignCircle Folder01 Folder02 FolderAdd Search01 CancelCircle Cancel01 Delete02 ColorPicker
ArchiveArrowDown Inbox Camera01 Computer FullScreen AppWindowMac SquareArrowVertical ScanText Settings01
ArrowDown01 ArrowLeft01 ArrowRight01 ArrowUp01 ArrowUpDouble Tick02 CheckmarkCircle02 PencilEdit02 View Copy01 File01
Link01 Timer01 Stop ArrowUp02 ArrowUpRight01 LinkSquare02 Download04 AspectRatio InformationCircle Hashtag
TextAlignLeft TextFont Globe02 Image01 LeftToRightListBullet LeftToRightListNumber Zap Circle Progress03 Fire EqualSign
Sunrise Sun03 Sun01 Sun02 Sunset MoonStar Alert02 Bell ArrowExpand01 TextBold TextItalic TextStrikethrough
Heading01 Heading02 Heading03 LeftToRightBlockQuote CodeSquare SourceCode TaskDone01 Calendar03 Ruler Lock LockOpen Function
Keyboard Sparkles Note01 NoteAdd Sent""".split()
out = ['// Generated from @hugeicons/core-free-icons 4.3.5 (MIT, https://hugeicons.com) by',
       '// Tools/hugeicons/gen.py. Each entry is the icon\'s 24×24 paths: "S" strokes,',
       '// "F" fills, "B" both.',
       'nonisolated enum HugeIconGlyphs {',
       '    static let all: [String: [String]] = [']
for n in sorted(set(NAMES)):
    parts = []
    for g in glyphs(n):
        kind = "B" if g["fill"] and g["stroke"] else "F" if g["fill"] else "S"
        d = re.sub(r"\s+", " ", g["d"]).strip()
        parts.append(f'"{kind}{d}"')
    out.append(f'        "{n}": [{", ".join(parts)}],')
out += ['    ]', '}', '']
pathlib.Path(sys.argv[1]).write_text("\n".join(out))
print(len(set(NAMES)), "icons")
