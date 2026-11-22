import { ActivityIndicator, StyleSheet, Switch, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { locationAccessMessage, type AccessAction, type LocationAccess } from '@/lib/riderOnline';
import type { OnlinePhase } from '@/lib/useRiderOnline';

type OnlineCardProps = {
  phase: OnlinePhase;
  access: Exclude<LocationAccess, 'ready'> | null;
  error: string | null;
  lastSentAt: number | null;
  sendFailing: boolean;
  noFix: boolean;
  onToggle: (online: boolean) => void;
  onFixAccess: (action: AccessAction) => void;
};

export function OnlineCard({
  phase,
  access,
  error,
  lastSentAt,
  sendFailing,
  noFix,
  onToggle,
  onFixAccess,
}: OnlineCardProps) {
  const online = phase === 'online';
  const busy = phase === 'loading' || phase === 'going_online' || phase === 'going_offline';
  const accessHelp = access ? locationAccessMessage(access) : null;

  return (
    <View style={[styles.card, online ? styles.onlineCard : null]}>
      <View style={styles.row}>
        <View style={styles.titleBlock}>
          <Text style={styles.eyebrow}>Rider status</Text>
          <Text style={styles.title}>{online ? 'You are online' : 'You are offline'}</Text>
        </View>
        {busy ? (
          <ActivityIndicator color={colors.primary} />
        ) : (
          <Switch
            value={online}
            onValueChange={onToggle}
            accessibilityLabel={online ? 'Go offline' : 'Go online'}
            trackColor={{ true: colors.success }}
          />
        )}
      </View>

      {online ? (
        <>
          <Text style={styles.body}>
            {lastSentAt ? `Sharing your location · last sent ${formatTime(lastSentAt)}` : 'Sharing your location…'}
          </Text>
          <View style={styles.notice}>
            <Text style={styles.noticeText}>
              Keep Dispatch open while you are online. If you close it, lock your phone or switch apps, Dispatch stops
              sharing your location and sets you offline after a few minutes.
            </Text>
          </View>
        </>
      ) : (
        <Text style={styles.body}>
          Go online to receive deliveries. Dispatch shares your location only while you are online, and only with
          Dispatch.
        </Text>
      )}

      {online && sendFailing ? (
        <Text style={styles.warning}>No connection. We will keep trying; you may be set offline if it lasts.</Text>
      ) : null}
      {online && noFix && !sendFailing ? (
        <Text style={styles.warning}>
          We cannot get your location. Check that location is on, or you will be set offline in a few minutes.
        </Text>
      ) : null}

      {accessHelp ? (
        <View style={styles.help}>
          <Text style={styles.errorText}>{accessHelp.message}</Text>
          <Button title={accessHelp.actionLabel} variant="secondary" onPress={() => onFixAccess(accessHelp.action)} />
        </View>
      ) : null}
      {error ? <Text style={styles.errorText}>{error}</Text> : null}
    </View>
  );
}

function formatTime(ms: number): string {
  return new Date(ms).toLocaleTimeString('en-NG', { hour: 'numeric', minute: '2-digit' });
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  onlineCard: { borderWidth: 1, borderColor: colors.success },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  titleBlock: { flex: 1, gap: spacing.xs },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  notice: { backgroundColor: '#fef9c3', borderRadius: 8, padding: spacing.sm },
  noticeText: { fontSize: 14, color: '#713f12' },
  warning: { fontSize: 14, color: '#b45309' },
  help: { gap: spacing.sm },
  errorText: { fontSize: 14, color: colors.danger },
});
