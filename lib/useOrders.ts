import { useCallback, useEffect, useState } from 'react';

import { ACTIVE_STATUSES, isActiveStatus, type OrderStatus } from '@/lib/orders';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';

export type OrderSummary = {
  id: string;
  status: OrderStatus;
  price_kobo: number;
  distance_m: number | null;
  priced_with_fallback: boolean | null;
  pickup_address: string;
  dropoff_address: string;
  package_description: string | null;
  created_at: string;
};

export type OrderContact = { receiver_name: string; receiver_phone: string };

const ORDER_COLUMNS =
  'id, status, price_kobo, distance_m, priced_with_fallback, pickup_address, dropoff_address, package_description, created_at';

const POLL_MS = 8_000;

/** The customer's orders that have not ended, newest first (RLS: only their own). */
export function useActiveOrders(enabled: boolean) {
  const { session } = useSession();
  const userId = session?.user.id ?? null;
  const [orders, setOrders] = useState<OrderSummary[]>([]);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!enabled || !userId) return;
    const { data, error: queryError } = await supabase
      .from('orders')
      .select(ORDER_COLUMNS)
      .eq('customer_id', userId)
      .in('status', ACTIVE_STATUSES)
      .order('created_at', { ascending: false });
    if (queryError) {
      setError('We could not load your orders. Check your connection and try again.');
      return;
    }
    setError(null);
    setOrders(data ?? []);
  }, [enabled, userId]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { orders, error, reload };
}

/** One order and its receiver, refreshed every 15 s while it is active. */
export function useOrder(orderId: string | undefined) {
  const [order, setOrder] = useState<OrderSummary | null>(null);
  const [contact, setContact] = useState<OrderContact | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!orderId) return;
    const [orderRes, contactRes] = await Promise.all([
      supabase.from('orders').select(ORDER_COLUMNS).eq('id', orderId).maybeSingle(),
      supabase.from('order_contacts').select('receiver_name, receiver_phone').eq('order_id', orderId).maybeSingle(),
    ]);
    if (orderRes.error) {
      setError('We could not load this order. Check your connection and try again.');
    } else {
      setError(null);
      setOrder(orderRes.data);
      setContact(contactRes.data ?? null);
    }
    setLoaded(true);
  }, [orderId]);

  useEffect(() => {
    reload();
  }, [reload]);

  // Polling (no Realtime): check every 8 s while the order is active.
  const active = order ? isActiveStatus(order.status) : false;
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(reload, POLL_MS);
    return () => clearInterval(timer);
  }, [active, reload]);

  return { order, contact, loaded, error, reload };
}
