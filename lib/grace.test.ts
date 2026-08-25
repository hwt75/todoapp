import { describe, expect, it } from 'vitest';
import {
  GRACE_DAY_COPY,
  classifyGraceDaySpend,
  formatGraceAllowance,
  toGraceDayRow,
} from './grace';

describe('toGraceDayRow', () => {
  it('sends exactly owner_id and for_day, nothing derived is ever included', () => {
    // Unlike appeal.toRow, there is no idempotency_key or settlement_id/penalty_id/deadline
    // to omit — grace_day_validate() derives nothing onto the row itself, it only validates
    // and lets the insert through or refuses it.
    expect(toGraceDayRow({ forDay: '2026-08-18' }, 'owner-1')).toEqual({
      owner_id: 'owner-1',
      for_day: '2026-08-18',
    });
  });
});

describe('classifyGraceDaySpend', () => {
  it('reads a clean insert (no error) as spent', () => {
    expect(classifyGraceDaySpend(null)).toEqual({ kind: 'spent' });
  });

  it('reads a 23505 as already-spent — either this attempt’s own retry or a second attempt, and both mean the same thing here', () => {
    // Unlike appeal (which needs idempotency-key reconciliation), grace_day has exactly one
    // possible owner for a given for_day, so there is nothing to disambiguate.
    expect(classifyGraceDaySpend({ code: '23505', message: 'duplicate key' })).toEqual({
      kind: 'already-spent',
    });
  });

  it('passes the trigger’s own raised message straight through on a rejection', () => {
    expect(
      classifyGraceDaySpend({
        code: 'P0001',
        message: 'Both Grace Days for this month have already been spent. They do not carry over.',
      }),
    ).toEqual({
      kind: 'refused',
      reason: 'Both Grace Days for this month have already been spent. They do not carry over.',
    });
  });

  it('falls back to the generic message when the server carries no SQLSTATE at all', () => {
    expect(classifyGraceDaySpend({ message: 'network down' })).toEqual({
      kind: 'refused',
      reason: GRACE_DAY_COPY.unreachable,
    });
  });

  it('never throws on a rejection with no message', () => {
    expect(classifyGraceDaySpend({ code: 'P0001' })).toEqual({
      kind: 'refused',
      reason: GRACE_DAY_COPY.failed,
    });
  });
});

describe('formatGraceAllowance', () => {
  it('always states the count, never leaving the control silent about how many remain', () => {
    expect(formatGraceAllowance(2)).toBe('2 Grace Days remaining this month.');
  });

  it('uses the singular for exactly one', () => {
    expect(formatGraceAllowance(1)).toBe('1 Grace Day remaining this month.');
  });

  it('says none remain rather than a bare 0', () => {
    expect(formatGraceAllowance(0)).toBe('No Grace Days remaining this month.');
  });

  it('never reads negative, even if the server briefly disagrees on the exact count', () => {
    expect(formatGraceAllowance(-1)).toBe('No Grace Days remaining this month.');
  });
});
