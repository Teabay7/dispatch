// Rider commission helpers that don't touch React Native (unit tested with node:test).
// All amounts are integer kobo from the server; the app never calculates what is owed,
// it only formats what the ledger says.

export type CycleStatus = 'open' | 'due' | 'paid';

export type CycleRow = {
  id: string;
  cycle_no: number;
  trips_required: number;
  trip_count: number;
  status: CycleStatus;
  reference_code: string;
  due_at: string | null;
};

export type EntryRow = {
  id: string;
  type: 'commission' | 'payment' | 'reversal';
  amount_kobo: number;
  balance_after_kobo: number;
  paid_at: string | null;
  created_at: string;
  reverses_entry_id: string | null;
};

export type CompanyAccount = {
  bank_name: string | null;
  account_number: string | null;
  account_name: string | null;
};

export type CommissionCardState =
  | {
      kind: 'open';
      tripCount: number;
      tripsRequired: number;
      /** Positive = owed, negative = credit. */
      balanceKobo: number;
    }
  | {
      kind: 'due';
      tripsRequired: number;
      referenceCode: string;
      /** What must be paid to go online again: the whole balance. */
      owedKobo: number;
      /** Payments recorded since the cycle became due (partial payments). */
      receivedSinceDueKobo: number;
    };

/** "₦1,080" or "₦277.50". Negative amounts get a minus sign. */
export function formatNaira(kobo: number): string {
  const sign = kobo < 0 ? '-' : '';
  const abs = Math.abs(Math.trunc(kobo));
  const naira = Math.floor(abs / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const rest = abs % 100;
  return `${sign}₦${naira}${rest ? `.${rest.toString().padStart(2, '0')}` : ''}`;
}

export function owedLine(balanceKobo: number): string {
  if (balanceKobo > 0) return `${formatNaira(balanceKobo)} owed`;
  if (balanceKobo < 0) return `${formatNaira(-balanceKobo)} credit`;
  return 'Nothing owed';
}

export function tripsLine(tripCount: number, tripsRequired: number): string {
  return `${tripCount} of ${tripsRequired} trip${tripsRequired === 1 ? '' : 's'}`;
}

/** Payments that still count: not reversed. Newest first, as the entries are. */
export function activePayments(entries: EntryRow[]): EntryRow[] {
  const reversed = new Set(entries.filter((e) => e.reverses_entry_id).map((e) => e.reverses_entry_id));
  return entries.filter((e) => e.type === 'payment' && !reversed.has(e.id));
}

/**
 * What the home card shows. A due cycle wins (the rider is blocked); otherwise the
 * open cycle, or "0 of N trips" before the first counted trip.
 * Entries are the rider's newest entries first; the first one carries the balance.
 */
export function commissionCardState(
  cycles: CycleRow[],
  entries: EntryRow[],
  tripsPerCycle: number,
): CommissionCardState {
  const balanceKobo = entries[0]?.balance_after_kobo ?? 0;
  const due = cycles.find((c) => c.status === 'due');
  if (due) {
    const dueAt = due.due_at ?? '';
    const receivedSinceDueKobo = activePayments(entries)
      .filter((p) => p.created_at >= dueAt)
      .reduce((sum, p) => sum - p.amount_kobo, 0);
    return {
      kind: 'due',
      tripsRequired: due.trips_required,
      referenceCode: due.reference_code,
      owedKobo: balanceKobo,
      receivedSinceDueKobo,
    };
  }
  const open = cycles.find((c) => c.status === 'open');
  return {
    kind: 'open',
    tripCount: open?.trip_count ?? 0,
    tripsRequired: open?.trips_required ?? tripsPerCycle,
    balanceKobo,
  };
}

export function hasCompanyAccount(account: CompanyAccount | null): account is {
  bank_name: string;
  account_number: string;
  account_name: string;
} {
  return !!account?.bank_name && !!account.account_number && !!account.account_name;
}
