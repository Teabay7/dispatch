import { useCallback, useEffect, useState } from 'react';

import {
  activePayments,
  commissionCardState,
  type CompanyAccount,
  type CycleRow,
  type EntryRow,
} from '@/lib/commission';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';

const DEFAULT_TRIPS_PER_CYCLE = 4;

/**
 * The signed-in rider's commission: current cycles, recent ledger entries (RLS only
 * returns their own), the cycle length, and the company account to pay into.
 * Keeps the last loaded data while reloading, so home does not flicker on focus.
 */
export function useRiderCommission(enabled = true) {
  const { session } = useSession();
  const userId = session?.user.id ?? null;
  const [cycles, setCycles] = useState<CycleRow[]>([]);
  const [entries, setEntries] = useState<EntryRow[]>([]);
  const [tripsPerCycle, setTripsPerCycle] = useState(DEFAULT_TRIPS_PER_CYCLE);
  const [company, setCompany] = useState<CompanyAccount | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!userId || !enabled) return;
    setError(null);
    const [cyclesRes, entriesRes, settingsRes, companyRes] = await Promise.all([
      supabase
        .from('commission_cycles')
        .select('id, cycle_no, trips_required, trip_count, status, reference_code, due_at')
        .eq('rider_id', userId)
        .in('status', ['open', 'due']),
      supabase
        .from('commission_entries')
        .select('id, type, amount_kobo, balance_after_kobo, paid_at, created_at, reverses_entry_id')
        .eq('rider_id', userId)
        .order('entry_no', { ascending: false })
        .limit(50),
      supabase.from('app_settings').select('commission_trips_per_cycle').maybeSingle(),
      supabase.rpc('get_company_payment_account').maybeSingle(),
    ]);
    if (cyclesRes.error || entriesRes.error || settingsRes.error) {
      setError('We could not load your commission. Check your connection and try again.');
      return;
    }
    setCycles(cyclesRes.data ?? []);
    setEntries(entriesRes.data ?? []);
    setTripsPerCycle(settingsRes.data?.commission_trips_per_cycle ?? DEFAULT_TRIPS_PER_CYCLE);
    // The account is only needed to pay; a failure here just hides it.
    setCompany(companyRes.error ? null : (companyRes.data ?? null));
    setLoaded(true);
  }, [userId, enabled]);

  useEffect(() => {
    reload();
  }, [reload]);

  const state = commissionCardState(cycles, entries, tripsPerCycle);
  return {
    state,
    isDue: state.kind === 'due',
    company,
    recentPayments: activePayments(entries).slice(0, 3),
    loaded,
    error,
    reload,
  };
}
