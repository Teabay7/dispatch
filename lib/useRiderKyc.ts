import { useCallback, useEffect, useState } from 'react';

import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

export type RiderDetails = Pick<
  Database['public']['Tables']['rider_details']['Row'],
  | 'full_name'
  | 'bike_make_model'
  | 'bike_colour'
  | 'plate_number'
  | 'id_photo_path'
  | 'selfie_path'
  | 'kyc_status'
  | 'rejection_reason'
  | 'submitted_at'
>;

const COLUMNS =
  'full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path, kyc_status, rejection_reason, submitted_at';

/** The signed-in rider's own KYC row (null when they have not submitted yet). */
export function useRiderKyc(enabled = true) {
  const { session } = useSession();
  const userId = session?.user.id ?? null;
  const [details, setDetails] = useState<RiderDetails | null>(null);
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
      .from('rider_details')
      .select(COLUMNS)
      .eq('user_id', userId)
      .maybeSingle();
    if (queryError) {
      setError('We could not load your verification status. Check your connection and try again.');
    } else {
      setDetails(data);
    }
    setLoading(false);
  }, [userId, enabled]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { details, loading, error, reload };
}
