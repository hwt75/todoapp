import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { StatusPill } from './status-pill';

/**
 * The pill's own rendering rules, and the one addition spec 3-3 (D3) made to them: an optional
 * `override` that replaces the state-derived family and label without touching either when it
 * is absent. `commitment-row.test.tsx` already covers the pill through a row; this file is
 * where the pill's own contract — including the override this story adds — is checked directly.
 */

describe('a status pill with no override', () => {
  it('renders the state table’s own family and label, unchanged', () => {
    render(<StatusPill state="held" />);
    const pill = screen.getByText('Held');
    expect(pill).toHaveClass('pill-held');
    expect(pill).toHaveAttribute('aria-hidden', 'true');
  });

  it('renders every state exactly as STATE_PRESENTATION defines it', () => {
    render(<StatusPill state="missed" />);
    expect(screen.getByText('Missed')).toHaveClass('pill-failed');
  });
});

describe('a status pill with an override', () => {
  it('replaces both the family and the label', () => {
    render(<StatusPill state="not_yet" override={{ family: 'urgent', label: '1/3 · 3 days' }} />);

    // The state-derived rendering ("Not yet", pill-neutral) must not appear at all.
    expect(screen.queryByText('Not yet')).not.toBeInTheDocument();

    const pill = screen.getByText('1/3 · 3 days');
    expect(pill).toHaveClass('pill-urgent');
    expect(pill).not.toHaveClass('pill-neutral');
  });

  it('stays aria-hidden with an override, the same as without one', () => {
    render(<StatusPill state="not_yet" override={{ family: 'held', label: '3/3' }} />);
    expect(screen.getByText('3/3')).toHaveAttribute('aria-hidden', 'true');
  });

  it('can render every family through the override, not only the four states already use', () => {
    render(<StatusPill state="not_yet" override={{ family: 'held', label: '3/3' }} />);
    expect(screen.getByText('3/3')).toHaveClass('pill-held');
  });
});
