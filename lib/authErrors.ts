import { isAuthError } from '@supabase/supabase-js';

/** Turns a Supabase Auth error into a short message a user can act on. */
export function friendlyAuthError(error: unknown): string {
  if (!isAuthError(error)) {
    return 'Something went wrong. Check your connection and try again.';
  }

  switch (error.code) {
    case 'over_sms_send_rate_limit':
    case 'over_request_rate_limit':
      return 'Too many attempts. Please wait a minute and try again.';
    case 'otp_expired':
      return 'That code is wrong or has expired. Check it or request a new one.';
    case 'phone_provider_disabled':
    case 'sms_send_failed':
    case 'hook_timeout':
    case 'hook_timeout_after_retry':
    case 'hook_payload_invalid_content_type':
    case 'unexpected_failure':
      return 'We could not send the code right now. Please try again shortly.';
    default:
      if (error.status === 0 || error.name === 'AuthRetryableFetchError') {
        return 'No connection. Check your internet and try again.';
      }
      return 'Something went wrong. Please try again.';
  }
}
