// Rider bank account helpers that don't touch React Native (unit tested with node:test).
// Account numbers are personal financial data: never log them, never put them in
// error messages; show them masked unless the rider is looking at their own form.

/** Banks riders in Ede commonly use. "Other" lets a rider type a bank that is not listed. */
export const BANKS = [
  'Access Bank',
  'Ecobank',
  'Fidelity Bank',
  'First Bank',
  'FCMB',
  'GTBank',
  'Jaiz Bank',
  'Keystone Bank',
  'Kuda',
  'Moniepoint',
  'OPay',
  'PalmPay',
  'Polaris Bank',
  'Providus Bank',
  'Stanbic IBTC',
  'Sterling Bank',
  'UBA',
  'Union Bank',
  'Unity Bank',
  'Wema Bank (ALAT)',
  'Zenith Bank',
] as const;

export const OTHER_BANK = 'Other';

export type BankFormValues = {
  /** A name from BANKS, or OTHER_BANK. */
  bank: string;
  /** Typed bank name when bank is OTHER_BANK. */
  otherBank: string;
  accountNumber: string;
  accountName: string;
};

export type BankFormErrors = Partial<Record<'bank' | 'accountNumber' | 'accountName', string>>;

/** Spaces are allowed while typing ("0123 456 789"); the server removes them too. */
export function cleanAccountNumber(value: string): string {
  return value.replace(/\s+/g, '');
}

export function cleanName(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

/** The bank name sent to the server. */
export function chosenBankName(values: Pick<BankFormValues, 'bank' | 'otherBank'>): string {
  return values.bank === OTHER_BANK ? cleanName(values.otherBank) : values.bank;
}

export function validateBankForm(values: BankFormValues): BankFormErrors {
  const errors: BankFormErrors = {};
  const bank = chosenBankName(values);
  if (!bank) errors.bank = values.bank === OTHER_BANK ? 'Type the name of your bank.' : 'Choose your bank.';
  else if (bank.length > 100) errors.bank = 'The bank name is too long.';
  if (!/^[0-9]{10}$/.test(cleanAccountNumber(values.accountNumber))) {
    errors.accountNumber = 'Enter your 10-digit account number.';
  }
  const name = cleanName(values.accountName);
  if (name.length < 2) errors.accountName = 'Enter the account name exactly as your bank shows it.';
  else if (name.length > 100) errors.accountName = 'The account name is too long.';
  return errors;
}

/** "******6789": enough for the rider to recognise their account. */
export function maskAccountNumber(accountNumber: string): string {
  const digits = cleanAccountNumber(accountNumber);
  if (digits.length <= 4) return digits;
  return '*'.repeat(digits.length - 4) + digits.slice(-4);
}

export type BankAccountStatus = 'pending' | 'verified' | 'rejected' | 'withdrawn' | 'replaced' | 'revoked';

export type BankAccountRow = {
  id: string;
  bank_name: string;
  account_number: string;
  account_name: string;
  status: BankAccountStatus;
  reason: string | null;
  created_at: string;
};

export type BankCardState =
  | { kind: 'none' }
  | { kind: 'pending'; pending: BankAccountRow }
  | { kind: 'rejected'; latest: BankAccountRow }
  | { kind: 'revoked'; latest: BankAccountRow }
  | { kind: 'verified'; verified: BankAccountRow; pending: BankAccountRow | null; rejectedChange: BankAccountRow | null };

/**
 * What the home screen shows, from the rider's own accounts (newest first).
 * A verified account always wins; otherwise the newest meaningful row decides.
 */
export function bankCardState(accounts: BankAccountRow[]): BankCardState {
  const verified = accounts.find((a) => a.status === 'verified') ?? null;
  const pending = accounts.find((a) => a.status === 'pending') ?? null;
  // Newest row that is not "withdrawn" (a rider's own replaced submission).
  const latest = accounts.find((a) => a.status !== 'withdrawn') ?? null;

  if (verified) {
    const rejectedChange =
      !pending && latest?.status === 'rejected' && latest.created_at > verified.created_at ? latest : null;
    return { kind: 'verified', verified, pending, rejectedChange };
  }
  if (pending) return { kind: 'pending', pending };
  if (latest?.status === 'rejected') return { kind: 'rejected', latest };
  if (latest?.status === 'revoked') return { kind: 'revoked', latest };
  return { kind: 'none' };
}

// Messages raised by submit_rider_bank_account that are safe to show as they are.
const SAFE_SERVER_MESSAGES = [
  'An active rider role is required to add a bank account',
  'Submit your rider verification before adding a bank account',
  'Choose your bank',
  'The account number must be exactly 10 digits',
  'Enter the account name as your bank shows it',
  'This is already your verified bank account',
  'This bank account is already registered to another rider',
];

/** Server errors turned into text a rider can act on. Never echoes unknown text. */
export function friendlyBankError(message: string | undefined): string {
  if (message) {
    if (message.includes('already registered to another rider')) {
      return 'This bank account is already registered to another rider. Use an account in your own name, or contact Dispatch support.';
    }
    const known = SAFE_SERVER_MESSAGES.find((m) => message.includes(m));
    if (known) return `${known}.`;
  }
  return 'We could not save your bank account. Check your connection and try again.';
}
