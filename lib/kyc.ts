// Rider KYC helpers that don't touch React Native (unit tested with node:test).
import type { Database } from '@/types/database';

export type KycStatus = Database['public']['Enums']['kyc_status'];
export type RoleStatus = Database['public']['Enums']['role_status'];
export type PhotoKind = 'id-front' | 'selfie';

export const KYC_BUCKET = 'rider-kyc';

export type KycFormValues = {
  fullName: string;
  bikeMakeModel: string;
  bikeColour: string;
  plateNumber: string;
};

export type KycFormErrors = Partial<Record<keyof KycFormValues, string>>;

/** Required fields only. The plate format is deliberately not checked. */
export function validateKycForm(values: KycFormValues): KycFormErrors {
  const errors: KycFormErrors = {};
  if (values.fullName.trim().length < 2) errors.fullName = 'Enter your full name as it appears on your ID.';
  if (!values.bikeMakeModel.trim()) errors.bikeMakeModel = 'Enter your bike make and model.';
  if (!values.bikeColour.trim()) errors.bikeColour = 'Enter your bike colour.';
  if (!values.plateNumber.trim()) errors.plateNumber = 'Enter your plate number.';
  return errors;
}

export function hasErrors(errors: KycFormErrors): boolean {
  return Object.keys(errors).length > 0;
}

/** Collapse spaces and trim; plates are also uppercased. */
export function cleanText(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

export function cleanPlate(value: string): string {
  return cleanText(value).toUpperCase();
}

/**
 * Storage path for a KYC photo: "<userId>/<kind>-<timestamp>-<random>.jpg".
 * The first folder must be the user's id (storage policies check it), and
 * every upload gets a new name so a retry never overwrites another file.
 */
export function buildKycPhotoPath(userId: string, kind: PhotoKind, now: Date, random: string): string {
  const safeRandom = random.replace(/[^a-z0-9]/gi, '').slice(0, 12) || '0';
  return `${userId}/${kind}-${now.getTime()}-${safeRandom}.jpg`;
}

export type KycCardState = 'not_started' | 'pending' | 'approved' | 'rejected' | 'suspended';

/** What the home screen shows a rider. A suspended rider role overrides KYC status. */
export function kycCardState(riderRoleStatus: RoleStatus, kycStatus: KycStatus | null): KycCardState {
  if (riderRoleStatus === 'suspended') return 'suspended';
  if (kycStatus === null) return 'not_started';
  return kycStatus;
}

/** The rider may open the KYC form to submit or resubmit. */
export function canEditKyc(state: KycCardState): boolean {
  return state === 'not_started' || state === 'rejected';
}

/** Database errors from the KYC rules, turned into something a rider can act on. */
export function friendlyKycError(message: string | undefined): string {
  if (!message) return 'We could not submit your details. Check your connection and try again.';
  if (message.includes('active rider role')) return 'Your rider account is suspended, so you cannot submit verification.';
  if (message.includes('rider_details_plate_number_unique')) {
    return 'This plate number is already registered to another rider. If the bike is now yours, contact Dispatch support.';
  }
  if (message.includes('own uploaded files')) return 'One of your photos did not upload. Please retake it and try again.';
  if (message.includes('locked') || message.includes('only be changed when resubmitting')) {
    return 'Your details are under review and cannot be changed right now.';
  }
  return 'We could not submit your details. Please try again.';
}
