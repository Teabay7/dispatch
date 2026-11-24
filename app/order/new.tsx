import * as Location from 'expo-location';
import { Redirect, router } from 'expo-router';
import { useEffect, useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button } from '@/components/Button';
import { PaymentNotice } from '@/components/PaymentNotice';
import { PlaceSearchField } from '@/components/PlaceSearchField';
import { QuoteCard } from '@/components/QuoteCard';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors } from '@/constants/theme';
import {
  hasErrors,
  isQuoteExpired,
  newSessionToken,
  quoteMinutesLeft,
  validateOrderForm,
  validatePlaces,
  type OrderFormErrors,
  type OrderFormValues,
  type PlaceChoice,
} from '@/lib/orders';
import { createOrderFromQuote, requestQuote, type Quote } from '@/lib/ordersApi';
import { normalizeNigerianPhone } from '@/lib/phone';
import { useSession } from '@/lib/session';

export default function NewOrderScreen() {
  const { roles } = useSession();
  const isCustomer = roles.some((r) => r.role === 'customer' && r.status === 'active');

  const [sessionToken, setSessionToken] = useState(() => newSessionToken());
  const [values, setValues] = useState<OrderFormValues>({
    pickup: null,
    dropoff: null,
    packageDescription: '',
    receiverName: '',
    receiverPhone: '',
  });
  const [errors, setErrors] = useState<OrderFormErrors>({});
  const [quote, setQuote] = useState<Quote | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [busy, setBusy] = useState<'quote' | 'confirm' | null>(null);
  const [locating, setLocating] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  // Keep the "price held for N minutes" line current.
  useEffect(() => {
    if (!quote) return;
    const timer = setInterval(() => setNow(Date.now()), 15_000);
    return () => clearInterval(timer);
  }, [quote]);

  if (!isCustomer) return <Redirect href="/" />;

  function update<K extends keyof OrderFormValues>(field: K, value: OrderFormValues[K]) {
    setValues((v) => ({ ...v, [field]: value }));
    if (errors[field]) setErrors((e) => ({ ...e, [field]: undefined }));
    setFormError(null);
    // A different place means a different price.
    if (field === 'pickup' || field === 'dropoff') setQuote(null);
  }

  async function useCurrentLocation() {
    setLocating(true);
    setFormError(null);
    try {
      const permission = await Location.requestForegroundPermissionsAsync();
      if (permission.status !== 'granted') {
        setFormError('Allow location access to use your current location, or search for the pickup place.');
        return;
      }
      const position = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.High });
      const place: PlaceChoice = {
        kind: 'current',
        lat: position.coords.latitude,
        lng: position.coords.longitude,
        label: 'Your current location',
      };
      update('pickup', place);
    } catch {
      setFormError('We could not get your location. Check that location is on, or search for the pickup place.');
    } finally {
      setLocating(false);
    }
  }

  async function getPrice() {
    const placeErrors = validatePlaces(values);
    setErrors(placeErrors);
    if (hasErrors(placeErrors) || !values.pickup || values.dropoff?.kind !== 'place') return;
    setBusy('quote');
    setFormError(null);
    const result = await requestQuote(values.pickup, values.dropoff, sessionToken);
    setBusy(null);
    // The search session ends with the place lookups; start a new one for any changes.
    setSessionToken(newSessionToken());
    if (result.error !== null) {
      setFormError(result.error);
      return;
    }
    setNow(Date.now());
    setQuote(result.data);
  }

  async function confirm() {
    const fieldErrors = validateOrderForm(values);
    setErrors(fieldErrors);
    if (hasErrors(fieldErrors) || !quote) return;
    if (isQuoteExpired(quote.expiresAt, Date.now())) {
      setFormError('This price has expired. Get a new price.');
      setQuote(null);
      return;
    }
    setBusy('confirm');
    setFormError(null);
    const result = await createOrderFromQuote({
      quoteId: quote.id,
      packageDescription: values.packageDescription.trim(),
      receiverName: values.receiverName.trim(),
      receiverPhone: normalizeNigerianPhone(values.receiverPhone) ?? '',
    });
    setBusy(null);
    if (result.error !== null) {
      setFormError(result.error);
      if (/expired|already been used/.test(result.error)) setQuote(null);
      return;
    }
    router.replace({ pathname: '/order/[id]', params: { id: result.data } });
  }

  const minutesLeft = quote ? quoteMinutesLeft(quote.expiresAt, now) : 0;

  return (
    <Screen>
      <Text style={styles.title}>Send a package</Text>
      <Text style={styles.body}>Dispatch delivers within Ede for now.</Text>

      <PlaceSearchField
        label="Pickup"
        placeholder="Search for the pickup place"
        value={values.pickup}
        onChange={(p) => update('pickup', p)}
        sessionToken={sessionToken}
        error={errors.pickup}
        onUseCurrentLocation={useCurrentLocation}
        locating={locating}
        disabled={busy !== null}
      />
      <PlaceSearchField
        label="Drop-off"
        placeholder="Search for the drop-off place"
        value={values.dropoff}
        onChange={(p) => update('dropoff', p)}
        sessionToken={sessionToken}
        error={errors.dropoff}
        disabled={busy !== null}
      />

      <TextField
        label="What are you sending?"
        value={values.packageDescription}
        onChangeText={(t) => update('packageDescription', t)}
        placeholder="e.g. Small box of documents"
        maxLength={200}
        error={errors.packageDescription}
      />
      <TextField
        label="Receiver's name"
        value={values.receiverName}
        onChangeText={(t) => update('receiverName', t)}
        autoCapitalize="words"
        maxLength={100}
        error={errors.receiverName}
      />
      <TextField
        label="Receiver's phone number"
        value={values.receiverPhone}
        onChangeText={(t) => update('receiverPhone', t)}
        placeholder="0803 123 4567"
        keyboardType="phone-pad"
        error={errors.receiverPhone}
      />

      {quote ? (
        <>
          <QuoteCard quote={quote} minutesLeft={minutesLeft} />
          <Button
            title={minutesLeft > 0 ? 'Confirm order' : 'Get a new price'}
            onPress={minutesLeft > 0 ? confirm : getPrice}
            loading={busy !== null}
          />
        </>
      ) : (
        <>
          <PaymentNotice />
          <Button title="Get price" onPress={getPrice} loading={busy === 'quote'} />
        </>
      )}
      {formError ? <Text style={styles.error}>{formError}</Text> : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.muted },
  error: { color: colors.danger, fontSize: 14 },
});
