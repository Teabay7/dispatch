// Delivery handover and payment helpers that don't touch React Native (unit tested
// with node:test). The server decides everything; these only choose what to show.
import type { OrderStatus } from './orders.ts';

export type PaymentStatus = 'unpaid' | 'awaiting_payment' | 'paid' | 'failed';

/** Where a picked-up job stands for the rider. */
export type RiderDeliveryStep = 'to_dropoff' | 'awaiting_payment' | 'handover' | 'ended';

export function riderDeliveryStep(status: OrderStatus, payment: PaymentStatus): RiderDeliveryStep {
  if (status !== 'picked_up') return 'ended';
  if (payment === 'awaiting_payment') return 'awaiting_payment';
  if (payment === 'paid') return 'handover';
  if (payment === 'unpaid') return 'to_dropoff';
  return 'ended';
}

/** What the customer's payment card shows. */
export type CustomerPaymentView = 'none' | 'pay_now' | 'reported' | 'paid_handover' | 'delivered' | 'refused';

export function customerPaymentView(
  status: OrderStatus,
  payment: PaymentStatus,
  reportedPaidAt: string | null,
): CustomerPaymentView {
  if (status === 'picked_up' && payment === 'awaiting_payment') return reportedPaidAt ? 'reported' : 'pay_now';
  if (status === 'picked_up' && payment === 'paid') return 'paid_handover';
  if ((status === 'delivered' || status === 'completed') && payment === 'paid') return 'delivered';
  if (status === 'payment_failed') return 'refused';
  return 'none';
}

/** Whole seconds until a time, never negative; null when there is no time yet. */
export function secondsUntil(iso: string | null, now: number): number | null {
  if (!iso) return null;
  return Math.max(0, Math.ceil((Date.parse(iso) - now) / 1000));
}

/** "4:05" style countdown. */
export function formatWait(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** "14:05" in the phone's time zone. */
export function formatClock(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** The PIN field keeps digits only, at most 4. */
export function normalizePin(text: string): string {
  return text.replace(/\D/g, '').slice(0, 4);
}

export function pinError(pin: string): string | null {
  return /^[0-9]{4}$/.test(pin) ? null : 'Enter the 4-digit PIN from the receiver';
}

export type PinResult = 'delivered' | 'wrong_pin' | 'locked';

export function pinResultMessage(result: PinResult, attemptsLeft: number | null): string | null {
  if (result === 'delivered') return null;
  if (result === 'locked') return 'Too many wrong PINs. Handover is locked: contact Dispatch support.';
  const left = attemptsLeft ?? 0;
  return left === 1 ? 'Wrong PIN. 1 try left.' : `Wrong PIN. ${left} tries left.`;
}

export type DisputeRole = 'customer' | 'rider';
export type DisputeReason = 'paid_not_confirmed' | 'payment_not_received' | 'wrong_amount' | 'other';

const REASONS: Record<DisputeRole, { code: DisputeReason; label: string }[]> = {
  customer: [
    { code: 'paid_not_confirmed', label: "I paid, but the rider hasn't confirmed" },
    { code: 'wrong_amount', label: 'There is a problem with the amount' },
    { code: 'other', label: 'Something else' },
  ],
  rider: [
    { code: 'payment_not_received', label: "The money hasn't arrived in my bank" },
    { code: 'wrong_amount', label: 'The amount is wrong' },
    { code: 'other', label: 'Something else' },
  ],
};

export function disputeReasons(role: DisputeRole) {
  return REASONS[role];
}

/** Matches the server: at most 500 characters, no phone or account numbers. */
export function disputeDetailsError(details: string): string | null {
  if (details.trim().length > 500) return 'Keep the details shorter';
  if (/[0-9]{7,}/.test(details.replace(/[\s.-]/g, ''))) return "Don't include phone or account numbers";
  return null;
}

export type DisputeSummary = {
  can_raise: boolean;
  dispute_status: 'open' | 'resolved' | 'withdrawn' | null;
  raised_as: DisputeRole | null;
  outcome: 'paid' | 'not_paid' | null;
};

/** One line about the latest dispute on an order, from the viewer's side. */
export function disputeLine(d: DisputeSummary | null, viewer: DisputeRole): string | null {
  if (!d || !d.dispute_status) return null;
  if (d.dispute_status === 'open') {
    return d.raised_as === viewer
      ? 'You reported a payment problem. Dispatch will contact you.'
      : `The ${d.raised_as} reported a payment problem. Dispatch will contact you.`;
  }
  if (d.dispute_status === 'withdrawn') return 'The payment problem was closed because the payment was confirmed.';
  return d.outcome === 'paid'
    ? 'Dispatch resolved the payment problem: the payment was confirmed.'
    : 'Dispatch resolved the payment problem: the order was not paid.';
}

export type OrderBlockReason = 'rider_dispute' | 'unpaid_delivery';

export function orderBlockMessage(reason: OrderBlockReason): string {
  return reason === 'rider_dispute'
    ? 'Your rider reported a payment problem on an order. You can order again once Dispatch resolves it.'
    : 'You have a delivered order that is not paid. Settle it before placing a new one.';
}

// Server messages that are safe to show as they are.
const SAFE_MESSAGES = [
  'Job not found',
  'Order not found',
  "We can't see your current location. Turn on location, keep the app open and try again",
  'You are not at the drop-off yet. Move closer and try again',
  'You can mark arrival at the drop-off only once, after pickup',
  'You can confirm payment only at the drop-off, while payment is due',
  'You can mark an order unpaid only while payment is due',
  'The customer says they have paid. Report a problem instead, and Dispatch will decide',
  'Give the customer more time to pay before marking the order unpaid',
  'Confirm the payment before handing over',
  'Ask Dispatch support to complete this delivery',
  'Payment is not due on this order',
  'The delivery PIN shows after the rider confirms your payment',
  'There is no receipt until the payment is confirmed',
  'Choose a reason',
  'Keep the details shorter',
  'Do not put phone or account numbers in the details',
  'A problem is already open on this order. Dispatch will contact you',
  "You can't report a payment problem on this order now",
];

export function friendlyDeliveryError(message: string | null | undefined): string {
  if (message) {
    const known = SAFE_MESSAGES.find((m) => message.includes(m));
    if (known) return `${known}.`;
  }
  return 'Something went wrong. Check your connection and try again.';
}
