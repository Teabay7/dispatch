import { useCallback, useEffect, useState } from 'react';

import { bankCardState, type BankAccountRow } from '@/lib/bankAccount';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';

const COLUMNS = 'id, bank_name, account_number, account_name, status, reason, created_at';

/**
 * The signed-in rider's own bank accounts (RLS only returns their rows).
 * Keeps the last loaded accounts while reloading, so the home screen does not
 * flicker (or stop location sharing) on every focus.
 */
export function useRiderBankAccount(enabled = true) {
  const { session } = useSession();
  const userId = session?.user.id ?? null;
  const [accounts, setAccounts] = useState<BankAccountRow[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(enabled);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!userId || !enabled) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    const { data, error: queryError } = await supabase
      .from('rider_bank_accounts')
      .select(COLUMNS)
      .eq('rider_id', userId)
      .order('created_at', { ascending: false })
      .limit(20);
    if (queryError) {
      setError('We could not load your bank account. Check your connection and try again.');
    } else {
      setAccounts(data ?? []);
      setLoaded(true);
    }
    setLoading(false);
  }, [userId, enabled]);

  useEffect(() => {
    reload();
  }, [reload]);

  const state = bankCardState(accounts);
  return { accounts, state, hasVerified: state.kind === 'verified', loaded, loading, error, reload };
}
