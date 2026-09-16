type Props = { className?: string };

const stroke = {
  fill: "none",
  strokeWidth: 1.6,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export const Watch = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <path d="M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6-10-6-10-6Z" />
    <circle cx="12" cy="12" r="2.5" />
  </svg>
);

export const Control = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <path d="M7 9l3 3-3 3" />
    <path d="M13 15h4" />
  </svg>
);

export const Phone = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <rect x="6" y="2.5" width="12" height="19" rx="2.5" />
    <path d="M10.5 18.6h3" />
  </svg>
);

export const Reload = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <path d="M20 11a8 8 0 1 0-2.3 6" />
    <path d="M20 4v7h-7" />
  </svg>
);

export const Pop = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <path d="M14 4h6v6" />
    <path d="M20 4l-9 9" />
    <path d="M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5" />
  </svg>
);

export const Send = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke} strokeWidth={1.8}>
    <path d="M5 12h13" />
    <path d="M13 6l6 6-6 6" />
  </svg>
);

export const Plus = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke} strokeWidth={1.8}>
    <path d="M12 5v14" />
    <path d="M5 12h14" />
  </svg>
);

export const X = ({ className }: Props) => (
  <svg viewBox="0 0 24 24" className={className} stroke="currentColor" {...stroke}>
    <path d="M6 6l12 12" />
    <path d="M18 6L6 18" />
  </svg>
);

/** herdr's own status marks, drawn rather than borrowed from the glyph table */
export function StatusGlyph({ status, className }: Props & { status?: string }) {
  const color =
    status === "working" ? "var(--color-accent)"
    : status === "blocked" ? "var(--color-warn)"
    : status === "done" ? "var(--color-ok)"
    : "#525a68";

  if (status === "done")
    return (
      <svg viewBox="0 0 24 24" className={className} fill="none" stroke={color} strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 12.5l5 5L20 6.5" />
      </svg>
    );
  if (status === "working")
    return (
      <svg viewBox="0 0 24 24" className={className} fill="none">
        <circle cx="12" cy="12" r="8.5" stroke={color} strokeWidth={2.2} />
        <path d="M12 3.5a8.5 8.5 0 0 1 0 17z" fill={color} />
      </svg>
    );
  if (status === "blocked")
    return (
      <svg viewBox="0 0 24 24" className={className} fill="none">
        <circle cx="12" cy="12" r="8.5" stroke={color} strokeWidth={2.2} />
        <path d="M12 8v5" stroke={color} strokeWidth={2.2} strokeLinecap="round" />
        <circle cx="12" cy="16.4" r="1.2" fill={color} />
      </svg>
    );
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none">
      <circle cx="12" cy="12" r="8.5" stroke={color} strokeWidth={2.2} />
    </svg>
  );
}
