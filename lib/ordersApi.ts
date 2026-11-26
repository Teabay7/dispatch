import { FunctionsHttpError } from '@supabase/supabase-js';

import { friendlyOrderError, quoteRequestBody, type PlaceChoice } from '@/lib/orders';
import { supabase } from '@/lib/supabase';

export type Suggestion = { placeId: string; mainText: string; secondaryText: string };

export type Quote = {
  id: string;
  pickupAddress: string;
  dropoffAddress: string;
  distanceM: number;
  priceKobo: number;
  pricedWithFallback: boolean;
  expiresAt: string;
};

type Result<T> = { data: T; error: null } | { data: null; error: string };

/** The Edge Functions answer errors as { error: "..." }; show only known messages. */
async function functionError(error: unknown): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = (await error.context.json()) as { error?: string };
      return friendlyOrderError(body.error);
    } catch {
      return friendlyOrderError(null);
    }
  }
  return friendlyOrderError(null);
}

export async function searchPlaces(input: string, sessionToken: string): Promise<Result<Suggestion[]>> {
  const { data, error } = await supabase.functions.invoke<{ suggestions: Suggestion[] }>('places', {
    body: { input, sessionToken },
  });
  if (error || !data) return { data: null, error: await functionError(error) };
  return { data: data.suggestions, error: null };
}

export async function requestQuote(
  pickup: PlaceChoice,
  dropoff: PlaceChoice & { kind: 'place' },
  sessionToken: string,
): Promise<Result<Quote>> {
  const { data, error } = await supabase.functions.invoke<{ quote: Quote }>('quote-order', {
    body: quoteRequestBody(pickup, dropoff, sessionToken),
  });
  if (error || !data) return { data: null, error: await functionError(error) };
  return { data: data.quote, error: null };
}

/** Creates the order from the quote. The server copies every price and address from the quote. */
export async function createOrderFromQuote(input: {
  quoteId: string;
  packageDescription: string;
  receiverName: string;
  /** E.164, e.g. +2348031234567 */
  receiverPhone: string;
}): Promise<Result<string>> {
  const { data, error } = await supabase.rpc('create_order_from_quote', {
    p_quote_id: input.quoteId,
    p_package_description: input.packageDescription,
    p_receiver_name: input.receiverName,
    p_receiver_phone: input.receiverPhone,
  });
  if (error || !data) return { data: null, error: friendlyOrderError(error?.message) };
  return { data, error: null };
}

export async function cancelOrder(orderId: string): Promise<Result<true>> {
  const { error } = await supabase.rpc('cancel_order', { p_order_id: orderId });
  if (error) return { data: null, error: friendlyOrderError(error.message) };
  return { data: true, error: null };
}
