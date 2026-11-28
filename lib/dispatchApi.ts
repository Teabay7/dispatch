import { friendlyDispatchError, type RiderCancelReason } from '@/lib/dispatch';
import { supabase } from '@/lib/supabase';

type Result<T> = { data: T; error: null } | { data: null; error: string };

function fail<T>(message: string | undefined): Result<T> {
  return { data: null, error: friendlyDispatchError(message) };
}

export type Offer = {
  offer_id: string;
  order_id: string;
  distance_to_pickup_m: number;
  direction: string | null;
  area_name: string;
  trip_distance_m: number | null;
  price_kobo: number;
  seconds_left: number;
};

export type OrderRider = {
  rider_name: string;
  bike_make_model: string;
  bike_colour: string;
  plate_number: string;
  bank_name: string | null;
  account_number: string | null;
  account_name: string | null;
};

export type AssignedRiderLocation = {
  lat: number;
  lng: number;
  accuracy_m: number | null;
  updated_at: string;
  distance_to_pickup_m: number;
  distance_to_dropoff_m: number;
};

export type ContactDetails = {
  customer_name: string | null;
  customer_phone: string | null;
  receiver_name: string | null;
  receiver_phone: string | null;
};

// --- Rider -----------------------------------------------------------------

export async function getMyOffer(): Promise<Result<Offer | null>> {
  const { data, error } = await supabase.rpc('get_my_offer');
  if (error) return fail(error.message);
  return { data: (data?.[0] as Offer | undefined) ?? null, error: null };
}

export async function acceptOffer(offerId: string): Promise<Result<string>> {
  const { data, error } = await supabase.rpc('accept_offer', { p_offer_id: offerId });
  if (error || !data) return fail(error?.message);
  return { data, error: null };
}

export async function declineOffer(offerId: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('decline_offer', { p_offer_id: offerId });
  return error ? fail(error.message) : { data: true, error: null };
}

export async function getMyActiveJob(): Promise<Result<string | null>> {
  const { data, error } = await supabase.rpc('get_my_active_job');
  if (error) return fail(error.message);
  return { data: data ?? null, error: null };
}

export async function markArrived(orderId: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('mark_arrived_at_pickup', { p_order_id: orderId });
  return error ? fail(error.message) : { data: true, error: null };
}

export async function markPickedUp(orderId: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('mark_picked_up', { p_order_id: orderId });
  return error ? fail(error.message) : { data: true, error: null };
}

export async function riderCancelJob(orderId: string, reason: RiderCancelReason): Promise<Result<true>> {
  const { error } = await supabase.rpc('rider_cancel_job', { p_order_id: orderId, p_reason: reason });
  return error ? fail(error.message) : { data: true, error: null };
}

export async function getContactDetails(orderId: string): Promise<Result<ContactDetails | null>> {
  const { data, error } = await supabase.rpc('get_order_contact_details', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as ContactDetails | undefined) ?? null, error: null };
}

// --- Customer --------------------------------------------------------------

export async function retryDispatch(orderId: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('retry_dispatch', { p_order_id: orderId });
  return error ? fail(error.message) : { data: true, error: null };
}

export async function getOrderRider(orderId: string): Promise<Result<OrderRider | null>> {
  const { data, error } = await supabase.rpc('get_order_rider', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as OrderRider | undefined) ?? null, error: null };
}

export async function getAssignedRiderLocation(orderId: string): Promise<Result<AssignedRiderLocation | null>> {
  const { data, error } = await supabase.rpc('get_assigned_rider_location', { p_order_id: orderId });
  if (error) return fail(error.message);
  return { data: (data?.[0] as AssignedRiderLocation | undefined) ?? null, error: null };
}
