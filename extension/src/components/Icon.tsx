// A few line icons in the spirit of SF Symbols, drawn on a 24px grid.

const paths = {
  crop: 'M6 2v14a2 2 0 0 0 2 2h14 M2 6h14a2 2 0 0 1 2 2v14',
  convert: 'M4 9h13l-4-4 M20 15H7l4 4',
  resize: 'M15 3h6v6 M9 21H3v-6 M21 3l-7 7 M3 21l7-7',
  rotateLeft: 'M3 4v5h5 M3.5 9A9 9 0 1 1 6 18',
  rotateRight: 'M21 4v5h-5 M20.5 9A9 9 0 1 0 18 18',
  flipH: 'M12 3v18 M8 7l-5 5 5 5V7z M16 7l5 5-5 5V7z',
  flipV: 'M3 12h18 M7 8l5-5 5 5H7z M7 16l5 5 5-5H7z',
  photo: 'M3 5h18v14H3z M3 16l5-5 4 4 3-3 6 6 M15.5 8.5h.01',
  check: 'M12 2l2.4 2.2 3.2-.4.9 3.1 2.8 1.6-1.2 3 1.2 3-2.8 1.6-.9 3.1-3.2-.4L12 22l-2.4-2.2-3.2.4-.9-3.1L2.7 15.5l1.2-3-1.2-3 2.8-1.6.9-3.1 3.2.4z M8.5 12l2.5 2.5 4.5-5',
  checkCircle: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z M8 12l3 3 5-6',
  warning: 'M12 3L2 20h20z M12 10v4 M12 17h.01',
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z M12 11v6 M12 7.5h.01',
  minus: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z M8 12h8',
  download: 'M12 3v12 M7 10l5 5 5-5 M4 20h16',
  folder: 'M3 6h6l2 2h10v11H3z',
  undo: 'M9 14L4 9l5-5 M4 9h11a5 5 0 0 1 0 10h-3',
  pencil: 'M4 20h4L19 9l-4-4L4 16z M13.5 6.5l4 4',
  play: 'M7 4.5v15l13-7.5z',
  pause: 'M7 4h3.5v16H7z M13.5 4H17v16h-3.5z',
  arrowRight: 'M4 12h16 M14 6l6 6-6 6',
} as const;

export type IconName = keyof typeof paths;

export function Icon({ name, label }: { name: IconName; label?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
      role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true}>
      <path d={paths[name]} />
    </svg>
  );
}
