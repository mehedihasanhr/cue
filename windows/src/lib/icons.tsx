// A few line icons, drawn here rather than pulled from a package.

type Props = { size?: number };
const base = (size: number) => ({
  width: size,
  height: size,
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.7,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
});

export const AreaIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3" /></svg>
);
export const WindowIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><rect x="3" y="4.5" width="18" height="15" rx="2" /><path d="M3 9h18" /></svg>
);
export const ScreenIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><rect x="3" y="4" width="18" height="12" rx="2" /><path d="M8 20h8M12 16v4" /></svg>
);
export const TextIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><path d="M4 7V5h16v2M12 5v14M9 19h6" /></svg>
);
export const FolderIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></svg>
);
export const GearIcon = ({ size = 18 }: Props) => (
  <svg {...base(size)}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></svg>
);
export const PencilIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z" /></svg>
);
export const CopyIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" /></svg>
);
export const TrashIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3" /></svg>
);
export const RevealIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /><path d="M12 11v5M9.5 13.5 12 16l2.5-2.5" /></svg>
);
export const PinIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><path d="M9 4h6l-1 6 4 3v2H6v-2l4-3zM12 15v6" /></svg>
);
export const SearchIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4.2-4.2" /></svg>
);
export const FloatIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><rect x="7" y="7" width="13" height="10" rx="1.5" /><path d="M4 14V5.5A1.5 1.5 0 0 1 5.5 4H15" /></svg>
);
export const LinkIcon = ({ size = 16 }: Props) => (
  <svg {...base(size)}><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" /></svg>
);
