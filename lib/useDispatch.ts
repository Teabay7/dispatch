import { useCallback, useEffect, useState } from 'react';

import {
  getAssignedRiderLocation,
  getMyActiveJob,
  getMyOffer,
  getOrderRider,
  type AssignedRiderLocation,
  type Offer,
  type OrderRider,
} from '@/lib/dispatchApi';
import type { OrderStatus } from '@/lib/orders';

// Polling, not Realtime: offers and rider locations are only readable through
// functions, so a few small requests while the screen is open is the simple, safe path.
const OFFER_POLL_MS = 5_000;
const RIDER_POLL_MS = 8_000;
const JOB_POLL_MS = 15_000;

/** The rider's current offer, checked every 5 s while they are online. */
export function useMyOffer(enabled: boolean) {
  const [offer, setOffer] = useState<Offer | null>(null);
  const [fetchedAt, setFetchedAt] = useState(0);

  const reload = useCallback(async () => {
    if (!enabled) {
      setOffer(null);
      return;
    }
    const result = await getMyOffer();
    if (result.error === null) {
      setOffer(result.data);
      setFetchedAt(Date.now());
    }
  }, [enabled]);

  useEffect(() => {
    reload();
    if (!enabled) return;
    const timer = setInterval(reload, OFFER_POLL_MS);
    return () => clearInterval(timer);
  }, [enabled, reload]);

  return { offer, fetchedAt, reload, clear: () => setOffer(null) };
}

/** The rider's active job (accepted or picked up), if any. */
export function useActiveJob(enabled: boolean) {
  const [jobId, setJobId] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!enabled) {
      setJobId(null);
      return;
    }
    const result = await getMyActiveJob();
    if (result.error === null) setJobId(result.data);
  }, [enabled]);

  useEffect(() => {
    reload();
    if (!enabled) return;
    const timer = setInterval(reload, JOB_POLL_MS);
    return () => clearInterval(timer);
  }, [enabled, reload]);

  return { jobId, reload };
}

/** For the customer: the assigned rider and their location, while a rider has the order. */
export function useAssignedRider(orderId: string | undefined, status: OrderStatus | undefined) {
  const hasRider = status === 'accepted' || status === 'picked_up';
  const [rider, setRider] = useState<OrderRider | null>(null);
  const [location, setLocation] = useState<AssignedRiderLocation | null>(null);

  const reload = useCallback(async () => {
    if (!orderId || !hasRider) {
      setRider(null);
      setLocation(null);
      return;
    }
    const [r, l] = await Promise.all([getOrderRider(orderId), getAssignedRiderLocation(orderId)]);
    setRider(r.error === null ? r.data : null);
    setLocation(l.error === null ? l.data : null);
  }, [orderId, hasRider]);

  useEffect(() => {
    reload();
    if (!hasRider) return;
    const timer = setInterval(reload, RIDER_POLL_MS);
    return () => clearInterval(timer);
  }, [hasRider, reload]);

  return { rider, location, reload };
}
