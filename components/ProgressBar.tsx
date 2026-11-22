import { StyleSheet, View } from 'react-native';

import { colors } from '@/constants/theme';

/** A thin bar; `progress` is between 0 and 1. */
export function ProgressBar({ progress }: { progress: number }) {
  const percent = Math.round(Math.min(1, Math.max(0, progress)) * 100);
  return (
    <View
      style={styles.track}
      accessibilityRole="progressbar"
      accessibilityValue={{ min: 0, max: 100, now: percent }}
    >
      <View style={[styles.fill, { width: `${percent}%` }]} />
    </View>
  );
}

const styles = StyleSheet.create({
  track: { height: 6, borderRadius: 3, backgroundColor: colors.surface, overflow: 'hidden' },
  fill: { height: '100%', backgroundColor: colors.primary },
});
