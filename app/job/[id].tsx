import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Alert, Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { RiderPaymentPanel } from '@/components/RiderPaymentPanel';
import { Screen } from '@/components/Screen';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import {
  jobStep,
  mapsUrl,
  nextJobAction,
  RIDER_CANCEL_REASONS,
  riderCanCancel,
  type JobStep,
  type RiderCancelReason,
} from '@/lib/dispatch';
import { riderDeliveryStep, type PaymentStatus, type RiderDeliveryStep } from '@/lib/delivery';
import { getContactDetails, markArrived, markPickedUp, riderCancelJob, type ContactDetails } from '@/lib/dispatchApi';
import { formatDistance, type OrderStatus } from '@/lib/orders';
import { formatNigerianPhone } from '@/lib/phone';
import { supabase } from '@/lib/supabase';

type Job = {
  id: string;
  status: OrderStatus;
  arrived_pickup_at: string | null;
  pickup_address: string;
  pickup_lat: number;
  pickup_lng: number;
  dropoff_address: string;
  dropoff_lat: number;
  dropoff_lng: number;
  package_description: string | null;
  price_kobo: number;
  distance_m: number | null;
  payment_status: PaymentStatus;
  customer_reported_paid_at: string | null;
  payment_reference: string | null;
};

const COLUMNS =
  'id, status, arrived_pickup_at, pickup_address, pickup_lat, pickup_lng, dropoff_address, dropoff_lat, dropoff_lng, package_description, price_kobo, distance_m, payment_status, customer_reported_paid_at, payment_reference';

export default function RiderJobScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [job, setJob] = useState<Job | null>(null);
  const [contact, setContact] = useState<ContactDetails | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [choosingReason, setChoosingReason] = useState(false);

  // RLS: a rider can read an order only while it is assigned to them.
  const reload = useCallback(async () => {
    if (!id) return;
    const { data } = await supabase.from('orders').select(COLUMNS).eq('id', id).maybeSingle();
    setJob(data ?? null);
    const step = data ? jobStep(data.status, data.arrived_pickup_at) : 'ended';
    if (step !== 'ended') {
      const c = await getContactDetails(id);
      setContact(c.error === null ? c.data : null);
    } else {
      setContact(null);
    }
    setLoaded(true);
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload]),
  );
  useEffect(() => {
    const timer = setInterval(reload, 15_000);
    return () => clearInterval(timer);
  }, [reload]);

  if (!loaded) {
    return (
      <Screen>
        <ActivityIndicator color={colors.primary} />
      </Screen>
    );
  }

  if (!job) {
    return (
      <Screen>
        <Text style={styles.body}>This job is no longer assigned to you.</Text>
        <Button title="Back to home" variant="secondary" onPress={() => router.replace('/')} />
      </Screen>
    );
  }

  const step = jobStep(job.status, job.arrived_pickup_at);
  const delivery = riderDeliveryStep(job.status, job.payment_status);
  const action = nextJobAction(step);

  async function doAction() {
    if (!job || !action) return;
    setBusy(true);
    setError(null);
    const result = action.kind === 'arrive' ? await markArrived(job.id) : await markPickedUp(job.id);
    setBusy(false);
    if (result.error !== null) setError(result.error);
    await reload();
  }

  function confirmCancel(reason: RiderCancelReason) {
    Alert.alert(
      'Cancel this job?',
      'This counts against your rider account. After several cancellations, Dispatch reviews your account. The order goes back to other riders.',
      [
        { text: 'Keep the job', style: 'cancel' },
        {
          text: 'Cancel job',
          style: 'destructive',
          onPress: async () => {
            if (!job) return;
            setBusy(true);
            setError(null);
            const result = await riderCancelJob(job.id, reason);
            setBusy(false);
            if (result.error !== null) {
              setError(result.error);
              return;
            }
            router.replace('/');
          },
        },
      ],
    );
  }

  function call(phone: string | null) {
    if (phone) Linking.openURL(`tel:+${phone.replace(/^\+/, '')}`);
  }

  return (
    <Screen>
      <View style={styles.card}>
        <Text style={styles.eyebrow}>Your job</Text>
        <Text style={styles.title}>{jobTitle(step, delivery, job.status)}</Text>
        <Steps step={step} delivery={delivery} />
        <Text style={styles.price}>{formatNaira(job.price_kobo)}</Text>
        {job.distance_m ? <Text style={styles.muted}>Trip {formatDistance(job.distance_m)}</Text> : null}
      </View>

      <View style={styles.card}>
        <Text style={styles.label}>Pickup</Text>
        <Text style={styles.body}>{job.pickup_address}</Text>
        <Pressable accessibilityRole="link" onPress={() => Linking.openURL(mapsUrl(job.pickup_lat, job.pickup_lng))}>
          <Text style={styles.link}>Open pickup in Maps</Text>
        </Pressable>
        <Text style={styles.label}>Drop-off</Text>
        <Text style={styles.body}>{job.dropoff_address}</Text>
        <Pressable accessibilityRole="link" onPress={() => Linking.openURL(mapsUrl(job.dropoff_lat, job.dropoff_lng))}>
          <Text style={styles.link}>Open drop-off in Maps</Text>
        </Pressable>
        {job.package_description ? (
          <>
            <Text style={styles.label}>Package</Text>
            <Text style={styles.body}>{job.package_description}</Text>
          </>
        ) : null}
      </View>

      {contact ? (
        <View style={styles.card}>
          <Text style={styles.label}>Customer</Text>
          <ContactLine name={contact.customer_name ?? 'Customer'} phone={contact.customer_phone} onCall={call} />
          <Text style={styles.label}>Receiver</Text>
          <ContactLine name={contact.receiver_name ?? 'Receiver'} phone={contact.receiver_phone} onCall={call} />
        </View>
      ) : null}

      {action ? <Button title={action.label} onPress={doAction} loading={busy} /> : null}
      <RiderPaymentPanel
        orderId={job.id}
        status={job.status}
        paymentStatus={job.payment_status}
        reportedPaidAt={job.customer_reported_paid_at}
        priceKobo={job.price_kobo}
        paymentReference={job.payment_reference}
        onChanged={reload}
      />
      {job.status === 'delivered' || job.status === 'completed' ? (
        <View style={styles.card}>
          <Text style={styles.body}>
            Delivered. You keep the full {formatNaira(job.price_kobo)}; this trip counts towards your commission cycle.
          </Text>
          <Button title="Back to home" onPress={() => router.replace('/')} />
        </View>
      ) : job.status === 'payment_failed' ? (
        <View style={styles.card}>
          <Text style={styles.body}>
            Marked unpaid. Take the package back to the pickup point. If the customer pays later, Dispatch will record it.
          </Text>
          <Button title="Back to home" onPress={() => router.replace('/')} />
        </View>
      ) : null}
      {error ? <Text style={styles.error}>{error}</Text> : null}

      {riderCanCancel(step) ? (
        choosingReason ? (
          <View style={styles.card}>
            <Text style={styles.label}>Why are you cancelling?</Text>
            {RIDER_CANCEL_REASONS.map((r) => (
              <Button key={r.code} title={r.label} variant="secondary" onPress={() => confirmCancel(r.code)} disabled={busy} />
            ))}
            <Button title="Back" variant="secondary" onPress={() => setChoosingReason(false)} />
          </View>
        ) : (
          <Button title="Cancel this job" variant="secondary" onPress={() => setChoosingReason(true)} disabled={busy} />
        )
      ) : step === 'picked_up' ? (
        <Text style={styles.muted}>After pickup, only Dispatch support can cancel this job.</Text>
      ) : null}
    </Screen>
  );
}

function jobTitle(step: JobStep, delivery: RiderDeliveryStep, status: OrderStatus): string {
  if (step === 'accepted') return 'Go to the pickup';
  if (step === 'arrived') return 'Collect the package';
  if (step === 'picked_up') {
    if (delivery === 'awaiting_payment') return 'Collect the payment';
    if (delivery === 'handover') return 'Hand over the package';
    return 'Deliver the package';
  }
  if (status === 'delivered' || status === 'completed') return 'Delivered';
  if (status === 'payment_failed') return 'Not delivered: unpaid';
  return 'Job ended';
}

function Steps({ step, delivery }: { step: JobStep; delivery: RiderDeliveryStep }) {
  const order = ['accepted', 'arrived', 'picked_up', 'at_dropoff', 'paid'] as const;
  const labels = { accepted: 'Accepted', arrived: 'At pickup', picked_up: 'Picked up', at_dropoff: 'At drop-off', paid: 'Paid' };
  const key =
    step === 'picked_up' && delivery === 'awaiting_payment'
      ? 'at_dropoff'
      : step === 'picked_up' && delivery === 'handover'
        ? 'paid'
        : step;
  const current = order.indexOf(key as (typeof order)[number]);
  return (
    <View style={styles.steps}>
      {order.map((s, i) => (
        <Text key={s} style={[styles.step, i <= current ? styles.stepDone : null]}>
          {i <= current ? '● ' : '○ '}
          {labels[s]}
        </Text>
      ))}
    </View>
  );
}

function ContactLine({ name, phone, onCall }: { name: string; phone: string | null; onCall: (p: string | null) => void }) {
  return (
    <View style={styles.contact}>
      <Text style={styles.body}>
        {name}
        {phone ? ` · ${formatNigerianPhone(phone)}` : ''}
      </Text>
      {phone ? (
        <Pressable accessibilityRole="button" onPress={() => onCall(phone)}>
          <Text style={styles.link}>Call</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.xs },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  price: { fontSize: 22, fontWeight: '700', color: colors.text, marginTop: spacing.xs },
  label: { fontSize: 12, fontWeight: '700', color: colors.muted, textTransform: 'uppercase', marginTop: spacing.sm },
  body: { fontSize: 15, color: colors.text },
  muted: { fontSize: 13, color: colors.muted },
  link: { fontSize: 15, fontWeight: '600', color: colors.primary },
  error: { fontSize: 14, color: colors.danger },
  steps: { flexDirection: 'row', gap: spacing.md, flexWrap: 'wrap' },
  step: { fontSize: 14, color: colors.muted },
  stepDone: { color: colors.success, fontWeight: '700' },
  contact: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: spacing.sm },
});
