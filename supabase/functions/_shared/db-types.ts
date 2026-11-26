// Types for the database layer (kept apart so tests don't load supabase-js).
import type { ServiceArea } from './google.ts';

export type QuoteInput = {
  customerId: string;
  pickup: { address: string; lat: number; lng: number; placeId: string | null };
  dropoff: { address: string; lat: number; lng: number; placeId: string | null };
  distanceM: number;
  distanceSource: 'routes' | 'straight_line_fallback';
};

export type QuoteRow = {
  id: string;
  pickup_address: string;
  dropoff_address: string;
  distance_m: number;
  distance_source: 'routes' | 'straight_line_fallback';
  price_kobo: number;
  expires_at: string;
};

export interface Db {
  useQuota(userId: string, kind: 'quote' | 'place_search', googleCalls: number): Promise<void>;
  serviceArea(): Promise<ServiceArea | null>;
  createQuote(input: QuoteInput): Promise<QuoteRow>;
}
