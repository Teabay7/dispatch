import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { ActiveOrdersCard } from '@/components/ActiveOrdersCard';
import { BankAccountCard } from '@/components/BankAccountCard';
import { Button } from '@/components/Button';
import { CommissionCard } from '@/components/CommissionCard';
import { KycStatusCard } from '@/components/KycStatusCard';
import { OnlineCard } from '@/components/OnlineCard';
import { Screen } from '@/components/Screen';
import { colors, spacing } from '@/constants/theme';
import { kycCardState } from '@/lib/kyc';
import { formatNigerianPhone } from '@/lib/phone';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';
import { useRiderBankAccount } from '@/lib/useRiderBankAccount';
import { useRiderCommission } from '@/lib/useRiderCommission';
import { useActiveOrders } from '@/lib/useOrders';
import { useRiderKyc } from '@/lib/useRiderKyc';
import { useRiderOnline } from '@/lib/useRiderOnline';
import type { AppRole } from '@/types';

const ROLE_LABELS: Record<AppRole, string> = {
  customer: 'Customer',
  rider: 'Rider',
  admin: 'Admin',
};

// Placeholder home until ordering (customer) and the rider dashboard are built.
export default function HomeScreen() {
  const { session, profile, roles, refresh } = useSession();
  const riderRole = roles.find((r) => r.role === 'rider');
  const kyc = useRiderKyc(!!riderRole);
  const bank = useRiderBankAccount(!!riderRole);
  const commission = useRiderCommission(!!riderRole);
  const isCustomer = roles.some((r) => r.role === 'customer' && r.status === 'active');
  const activeOrders = useActiveOrders(isCustomer);
  const [signingOut, setSigningOut] = useState(false);
  const [addingRider, setAddingRider] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const kycState = riderRole ? kycCardState(riderRole.status, kyc.details?.kyc_status ?? null) : null;
  // Only an approved rider with an active rider role, a verified bank account and no
  // commission due gets the online toggle. Uses the last loaded status, so a reload
  // on focus does not stop and restart tracking.
  const verifiedRider = kycState === 'approved' && bank.hasVerified;
  const canGoOnline = verifiedRider && commission.loaded && !commission.isDue;
  const reloadKycAfterRefusal = kyc.reload;
  const reloadBankAfterRefusal = bank.reload;
  const reloadCommissionAfterRefusal = commission.reload;
  const onAccessLost = useCallback(() => {
    // The server refused (suspended, rejected, account revoked, commission due, set
    // offline): show the current status.
    refresh();
    reloadKycAfterRefusal();
    reloadBankAfterRefusal();
    reloadCommissionAfterRefusal();
  }, [refresh, reloadKycAfterRefusal, reloadBankAfterRefusal, reloadCommissionAfterRefusal]);
  const online = useRiderOnline(canGoOnline, onAccessLost);

  // Coming back from the KYC or bank form: show the new status.
  const reloadKyc = kyc.reload;
  const reloadBank = bank.reload;
  const reloadCommission = commission.reload;
  const reloadOrders = activeOrders.reload;
  useFocusEffect(
    useCallback(() => {
      reloadKyc();
      reloadBank();
      reloadCommission();
      reloadOrders();
    }, [reloadKyc, reloadBank, reloadCommission, reloadOrders]),
  );

  async function becomeRider() {
    const userId = session?.user.id;
    if (!userId) return;
    setAddingRider(true);
    setError(null);
    const { error: insertError } = await supabase.from('user_roles').insert({ user_id: userId, role: 'rider' });
    if (insertError) {
      setAddingRider(false);
      setError('We could not add the rider role. Check your connection and try again.');
      return;
    }
    await refresh();
    setAddingRider(false);
    router.push('/rider-kyc');
  }

  async function signOut() {
    setSigningOut(true);
    // Stop sharing location first (best effort; the server also expires stale riders).
    if (online.isOnline) await online.goOffline();
    await supabase.auth.signOut();
    // The root layout returns the user to sign-in when the session ends.
  }

  return (
    <Screen>
      <Text style={styles.title}>Hello, {profile?.full_name}</Text>
      {profile?.phone ? <Text style={styles.muted}>{formatNigerianPhone(profile.phone)}</Text> : null}

      {isCustomer ? (
        <ActiveOrdersCard
          orders={activeOrders.orders}
          error={activeOrders.error}
          onNewOrder={() => router.push('/order/new')}
          onOpenOrder={(id) => router.push({ pathname: '/order/[id]', params: { id } })}
        />
      ) : null}

      {verifiedRider && commission.isDue ? (
        <>
          <CommissionCard state={commission.state} company={commission.company} recentPayments={commission.recentPayments} />
          <BankAccountCard state={bank.state} onOpenForm={() => router.push('/rider-bank')} />
        </>
      ) : verifiedRider && !commission.loaded ? (
        commission.error ? (
          <View style={styles.card}>
            <Text style={styles.errorText}>{commission.error}</Text>
            <Button title="Try again" variant="secondary" onPress={commission.reload} />
          </View>
        ) : (
          <ActivityIndicator color={colors.primary} />
        )
      ) : canGoOnline ? (
        <>
          <OnlineCard
            phase={online.phase}
            access={online.access}
            error={online.error}
            lastSentAt={online.lastSentAt}
            sendFailing={online.sendFailing}
            noFix={online.noFix}
            onToggle={(value) => (value ? online.goOnline() : online.goOffline())}
            onFixAccess={online.fixAccess}
          />
          <CommissionCard state={commission.state} company={commission.company} recentPayments={commission.recentPayments} />
          <BankAccountCard state={bank.state} onOpenForm={() => router.push('/rider-bank')} />
        </>
      ) : kycState === 'approved' ? (
        !bank.loaded ? (
          bank.error ? (
            <View style={styles.card}>
              <Text style={styles.errorText}>{bank.error}</Text>
              <Button title="Try again" variant="secondary" onPress={bank.reload} />
            </View>
          ) : (
            <ActivityIndicator color={colors.primary} />
          )
        ) : (
          <BankAccountCard state={bank.state} onOpenForm={() => router.push('/rider-bank')} />
        )
      ) : riderRole ? (
        kyc.loading ? (
          <ActivityIndicator color={colors.primary} />
        ) : kyc.error ? (
          <View style={styles.card}>
            <Text style={styles.errorText}>{kyc.error}</Text>
            <Button title="Try again" variant="secondary" onPress={kyc.reload} />
          </View>
        ) : (
          <>
            <KycStatusCard
              state={kycState ?? 'not_started'}
              rejectionReason={kyc.details?.rejection_reason ?? null}
              submittedAt={kyc.details?.submitted_at ?? null}
              canOrder={roles.some((r) => r.role === 'customer' && r.status === 'active')}
              onOpenForm={() => router.push('/rider-kyc')}
            />
            {/* The bank account can be added (and reviewed) while KYC is under review. */}
            {kycState === 'pending' && bank.loaded ? (
              <BankAccountCard state={bank.state} onOpenForm={() => router.push('/rider-bank')} />
            ) : null}
          </>
        )
      ) : null}

      <View style={styles.card}>
        <Text style={styles.cardTitle}>Your roles</Text>
        {roles.map((r) => (
          <View key={r.role} style={styles.roleRow}>
            <Text style={styles.body}>{ROLE_LABELS[r.role]}</Text>
            <Text style={[styles.badge, r.status === 'suspended' ? styles.suspended : styles.active]}>
              {r.status === 'suspended' ? 'Suspended' : 'Active'}
            </Text>
          </View>
        ))}
      </View>

      {!riderRole ? (
        <Button title="Become a rider" variant="secondary" onPress={becomeRider} loading={addingRider} />
      ) : null}
      {error ? <Text style={styles.errorText}>{error}</Text> : null}

      <View style={styles.spacer} />
      <Button title="Sign out" variant="secondary" onPress={signOut} loading={signingOut} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  muted: { fontSize: 16, color: colors.muted },
  body: { fontSize: 16, color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  cardTitle: { fontSize: 14, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  roleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  badge: { fontSize: 13, fontWeight: '600', paddingHorizontal: spacing.sm, paddingVertical: 2, borderRadius: 6 },
  active: { color: colors.success, backgroundColor: '#dcfce7' },
  suspended: { color: colors.danger, backgroundColor: '#fee2e2' },
  errorText: { fontSize: 14, color: colors.danger },
  spacer: { flex: 1 },
});
