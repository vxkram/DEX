import type { ComponentChildren } from 'preact';
import type { Note, Verdict } from '@/lib/image/planner';
import { verdictLabel } from '@/lib/image/planner';
import { Icon } from './Icon';

export function SectionHeader({ children }: { children: ComponentChildren }) {
  return <h3 class="section-header">{children}</h3>;
}

export function Segmented<T extends string>({ value, options, onChange, label }: {
  value: T;
  options: { value: T; title: string; disabled?: boolean; help?: string }[];
  onChange: (value: T) => void;
  label: string;
}) {
  return (
    <div class="segmented" role="group" aria-label={label}>
      {options.map((o) => (
        <button type="button" key={o.value} aria-pressed={o.value === value} disabled={o.disabled} title={o.help}
          onClick={() => onChange(o.value)}>
          {o.title}
        </button>
      ))}
    </div>
  );
}

export function Toggle({ checked, onChange, children }: { checked: boolean; onChange: (on: boolean) => void; children: ComponentChildren }) {
  return (
    <label class="toggle">
      <span>{children}</span>
      <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.currentTarget.checked)} />
    </label>
  );
}

const verdictIcon = { noReencode: 'check', lossless: 'checkCircle', lossy: 'warning' } as const;

export function VerdictBadge({ verdict }: { verdict: Verdict }) {
  return (
    <span class={`verdict ${verdict}`}>
      <Icon name={verdictIcon[verdict]} />
      {verdictLabel[verdict]}
    </span>
  );
}

export function Notes({ notes }: { notes: Note[] }) {
  return (
    <ul class="notes">
      {notes.map((note) => (
        <li key={note.text} class={note.isLoss ? 'loss' : ''}>
          <Icon name={note.isLoss ? 'minus' : 'info'} />
          <span>{note.text}</span>
        </li>
      ))}
    </ul>
  );
}
