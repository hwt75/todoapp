import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { Tabbar } from './tabbar';

describe('the tab bar', () => {
  it('offers the two screens that are not the current one', () => {
    render(<Tabbar active="today" onSelect={vi.fn()} />);

    expect(screen.getByRole('button', { name: 'Ledger' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Settings' })).toBeInTheDocument();
  });

  // The current screen is not a control at all. A disabled button would say "not now"
  // where the truth is "you are already here", and it would also mean every screen
  // offered its own name back to a screen reader as something pressable.
  it('renders the current screen as a marker rather than a button', () => {
    render(<Tabbar active="settings" onSelect={vi.fn()} />);

    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();
    expect(screen.getByText('Settings')).toHaveAttribute('aria-current', 'page');
  });

  // The reason this component exists: the Ledger's only other entry point is the debt
  // block, which renders nothing at all when nothing is owed.
  it('reports the screen that was chosen', async () => {
    const onSelect = vi.fn();
    render(<Tabbar active="today" onSelect={onSelect} />);

    await userEvent.click(screen.getByRole('button', { name: 'Ledger' }));

    expect(onSelect).toHaveBeenCalledWith('ledger');
  });

  it('gets back to Today from another screen', async () => {
    const onSelect = vi.fn();
    render(<Tabbar active="ledger" onSelect={onSelect} />);

    await userEvent.click(screen.getByRole('button', { name: 'Today' }));

    expect(onSelect).toHaveBeenCalledWith('today');
  });
});
