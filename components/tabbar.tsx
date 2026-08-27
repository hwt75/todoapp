'use client';

/** The three screens the tab bar switches between. */
export type Tab = 'today' | 'ledger' | 'settings';

const TABS: ReadonlyArray<{ tab: Tab; label: string }> = [
  { tab: 'today', label: 'Today' },
  { tab: 'ledger', label: 'Ledger' },
  { tab: 'settings', label: 'Settings' },
];

/**
 * Today, the Ledger and Settings, and the way between them.
 *
 * It exists because of a hole rather than a preference: the Ledger was reachable only by
 * pressing the debt block, and the debt block renders nothing at all when nothing is owed
 * (`components/debt-block.tsx`). On a clean day there was no route into the Ledger from
 * anywhere in the app.
 *
 * The current screen renders as a `span`, not a disabled button. There is nothing to
 * press — pressing it would do nothing, and a disabled control says "not now" when the
 * truth is "you are already here". It carries `aria-current="page"` so that is what a
 * screen reader is told, and it is marked visually by the one tonal step rather than by a
 * colour: the four state families each mean exactly one thing and "you are here" is not
 * one of them.
 *
 * Rendered by `app/page.tsx` and only on these three screens — never over the Morning
 * Gate or the Silence intervention, which block the app by being the only thing on it,
 * and never on a sub-screen reached from Today, which has its own way back.
 */
export function Tabbar({ active, onSelect }: { active: Tab; onSelect: (tab: Tab) => void }) {
  return (
    <nav className="tabbar" aria-label="Screens">
      {TABS.map(({ tab, label }) =>
        tab === active ? (
          <span key={tab} aria-current="page">
            {label}
          </span>
        ) : (
          <button key={tab} type="button" onClick={() => onSelect(tab)}>
            {label}
          </button>
        ),
      )}
    </nav>
  );
}
