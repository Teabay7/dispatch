// Nigerian mobile numbers: 10 digits after +234, starting 70, 71, 80, 81, 90 or 91.
const NATIONAL_MOBILE = /^[789][01]\d{8}$/;

/**
 * Turns what a user types (0803 123 4567, 8031234567, 234..., +234...) into
 * E.164 form (+2348031234567). Returns null if it is not a Nigerian mobile number.
 */
export function normalizeNigerianPhone(input: string): string | null {
  const compact = input.replace(/[\s\-().]/g, '');
  let national: string;

  if (/^\+234\d+$/.test(compact)) {
    national = compact.slice(4);
  } else if (/^234\d+$/.test(compact)) {
    national = compact.slice(3);
  } else if (/^\d+$/.test(compact)) {
    national = compact;
  } else {
    return null;
  }

  // Handles both the local form (0803...) and "+234 0803..." typed by mistake.
  if (national.length === 11 && national.startsWith('0')) {
    national = national.slice(1);
  }

  return NATIONAL_MOBILE.test(national) ? `+234${national}` : null;
}

/** "+2348031234567" or "2348031234567" -> "+234 803 123 4567" for display. */
export function formatNigerianPhone(phone: string): string {
  const national = phone.replace(/^\+?234/, '');
  if (national.length !== 10) return phone;
  return `+234 ${national.slice(0, 3)} ${national.slice(3, 6)} ${national.slice(6)}`;
}
