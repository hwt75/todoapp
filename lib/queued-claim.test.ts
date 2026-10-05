import { describe, expect, it } from 'vitest';
import type { QueuedClaim } from './declaration-write';
import { QUEUED_CLAIM_COPY, queuedTimedClaims } from './queued-claim';

/** A tap at a local wall-clock time, as the queue stores it: an ISO instant. */
function tap(commitmentId: string, local: string, timed = true): QueuedClaim {
  return {
    idempotencyKey: `${commitmentId}-${local}`,
    ownerId: 'u1',
    commitmentId,
    answer: 'held',
    answeredAt: new Date(`${local}+07:00`).toISOString(),
    timed,
  };
}

describe('queuedTimedClaims (Epic 6 retrospective item 48)', () => {
  it('keeps a claim tapped today as today’s', () => {
    const { today, stranded } = queuedTimedClaims([tap('p1', '2026-10-05T20:10:00')], '2026-10-05');
    expect([...today]).toEqual(['p1']);
    expect(stranded.size).toBe(0);
  });

  it('calls a claim from a day that has closed stranded, and names that day', () => {
    // 20:10 yesterday, still on the device after midnight. It will land on yesterday.
    const { today, stranded } = queuedTimedClaims([tap('p1', '2026-10-04T20:10:00')], '2026-10-05');
    expect(today.size).toBe(0);
    expect(stranded.get('p1')).toBe('2026-10-04');
  });

  it('decides the day in the product’s zone, not the device’s', () => {
    // 23:59 local is 16:59 UTC the same day; 00:01 local is 17:01 UTC the day before.
    const late = queuedTimedClaims([tap('p1', '2026-10-04T23:59:00')], '2026-10-05');
    expect(late.stranded.get('p1')).toBe('2026-10-04');
    const early = queuedTimedClaims([tap('p1', '2026-10-05T00:01:00')], '2026-10-05');
    expect([...early.today]).toEqual(['p1']);
  });

  it('ignores the morning gate’s untimed answers, which answer for yesterday by design', () => {
    const { today, stranded } = queuedTimedClaims(
      [tap('g1', '2026-10-05T07:30:00', false)],
      '2026-10-05',
    );
    expect(today.size).toBe(0);
    expect(stranded.size).toBe(0);
  });

  it('names the latest closed day when several are stranded', () => {
    const { stranded } = queuedTimedClaims(
      [tap('p1', '2026-10-02T20:10:00'), tap('p1', '2026-10-04T20:10:00')],
      '2026-10-05',
    );
    expect(stranded.get('p1')).toBe('2026-10-04');
  });
});

describe('QUEUED_CLAIM_COPY', () => {
  it('says the stranded day plainly, why it cannot be proven, and the one remedy', () => {
    const sentence = QUEUED_CLAIM_COPY.stranded('2026-10-04');
    expect(sentence).toContain('Oct 4, 2026');
    expect(sentence).toContain('no photo can prove it now');
    expect(sentence).toContain('Grace Day');
    // Conditional: a Grace Day only reaches a day that failed.
    expect(sentence).toContain('If the day fails');
  });

  it('keeps the queued sentence the screen has always said', () => {
    expect(QUEUED_CLAIM_COPY.queued).toContain('dated when you tapped');
  });
});
