import { useCallback, useEffect, useState } from 'react';

import type { OrderBlockReason } from '@/lib/delivery';
import { getMyOrderBlock } from '@/lib/deliveryApi';

/** Whether the customer is blocked from ordering, and by which order. Reload on focus. */
export function useOrderBlock(enabled: boolean) {
  const [block, setBlock] = useState<{ reason: OrderBlockReason; order_id: string } | null>(null);

  const reload = useCallback(async () => {
    if (!enabled) {
      setBlock(null);
      return;
    }
    const result = await getMyOrderBlock();
    // On a network error keep the last answer; the server refuses new orders anyway.
    if (result.error === null) setBlock(result.data);
  }, [enabled]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { block, reload };
}
