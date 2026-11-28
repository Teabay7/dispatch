import {
  friendlyDeliveryError,
  type DisputeReason,
  type DisputeSummary,
  type OrderBlockReason,
  type PinResult,
} from '@/lib/delivery';
import type { OrderStatus } from '@/lib/orders';
import { supabase } from '@/lib/supabase';

type Result<T> = { data: T; error: null } | { data: null; error: string };

function fail<T>(message: string | undefined): Result<T> {
  return { data: null, error: friendlyDeliveryError(message) };
}

async function call(fn: string, args: Record<string, unknown>): Promise<Result<true>> {
  const { error } = await supabase.rpc(fn as never, args as never);
  return error ? fail(error.message) : { data: true, error: null };
}

export type JobPaymentInfo = {
  refuse_available_at: string | null;
  pin_attempts_left: number;
  pin_locked: boolean;
  open_dispute_raised_as: 'customer' | 'rider' | null;
  can_raise_dispute: boolean;
};

export type Receipt = {
  order_status: OrderStatus;
  price_kobo: number;
  payment_reference: string;
  payment_confirmed_at: string | null;
  payment_confirmed_by: 'rider' | 'admin' | null;
  delivered_at: string | null;
  rider_name: string;
  plate_number: string;
  bank_name: string | null;
  account_masked: string | null;
  account_name: string | null;
};

// --- Rider -----------------------------------------------------------------

export function markArrivedAtDropoff(orderId: string) {
  return call('mark_arrived_at_dropoff', { p_order_id: orderId });
}

export function confirmPaymentReceived(orderId: string) {
  return call('confirm_payment_received', { p_order_id: orderId });
}

export function markPaymentRefused(orderId: string) {
  return call('mark_payment_refused', { p_order_id: orderId });
}

export async function completeDelivery(
  orderId: string,
  pin: string,
): Promise<Result<{ result: PinResult; attempts_left: number | null }>> {
  const { data, error } = await supabase.rpc('complete_delivery', { p_order_id: orderId, p_pin: pin });
  const row = data?.[0];
  if (error || !row) return fail(error?.message);
  return { data: { result: row.result as PinResult, attempts_left: row.attempts_left }, error: null };
}

export async function getJobPaymentInfo(orderId: string): Promise<Result<JobPaymentInfo | null>> {
  const { data, error } = await supabase.rpc('get_job_payment_info', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as JobPaymentInfo | undefined) ?? null, error: null };
}

// --- Customer --------------------------------------------------------------

export function reportPaymentSent(orderId: string) {
  return call('report_payment_sent', { p_order_id: orderId });
}

export async function getDeliveryPin(orderId: string): Promise<Result<string | null>> {
  const { data, error } = await supabase.rpc('get_delivery_pin', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: data ?? null, error: null };
}

export async function getOrderReceipt(orderId: string): Promise<Result<Receipt | null>> {
  const { data, error } = await supabase.rpc('get_order_receipt', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as Receipt | undefined) ?? null, error: null };
}

export async function getMyOrderBlock(): Promise<Result<{ reason: OrderBlockReason; order_id: string } | null>> {
  const { data, error } = await supabase.rpc('get_my_order_block');
  if (error) return fail(error.message);
  const row = data?.[0];
  return { data: row ? { reason: row.reason as OrderBlockReason, order_id: row.order_id } : null, error: null };
}

// --- Both ------------------------------------------------------------------

export async function raisePaymentDispute(orderId: string, reason: DisputeReason, details: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('raise_payment_dispute', {
    p_order_id: orderId,
    p_reason: reason,
    p_details: details.trim() === '' ? undefined : details.trim(),
  } as never);
  return error ? fail(error.message) : { data: true, error: null };
}

export async function getOrderDispute(orderId: string): Promise<Result<DisputeSummary | null>> {
  const { data, error } = await supabase.rpc('get_order_dispute', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as DisputeSummary | undefined) ?? null, error: null };
}
