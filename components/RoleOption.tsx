import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, spacing } from '@/constants/theme';

type RoleOptionProps = {
  title: string;
  description: string;
  selected: boolean;
  /** Already on the account; shown as selected and can't be removed here. */
  locked?: boolean;
  onToggle: () => void;
};

export function RoleOption({ title, description, selected, locked = false, onToggle }: RoleOptionProps) {
  return (
    <Pressable
      accessibilityRole="checkbox"
      accessibilityState={{ checked: selected, disabled: locked }}
      onPress={onToggle}
      disabled={locked}
      style={[styles.card, selected && styles.cardSelected]}
    >
      <View style={[styles.box, selected && styles.boxSelected]}>
        {selected ? <Text style={styles.tick}>✓</Text> : null}
      </View>
      <View style={styles.textBlock}>
        <Text style={styles.title}>{title}</Text>
        <Text style={styles.description}>{description}</Text>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    flexDirection: 'row',
    gap: spacing.md,
    padding: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
    alignItems: 'center',
  },
  cardSelected: { borderColor: colors.primary, backgroundColor: '#f0fdfa' },
  box: {
    width: 24,
    height: 24,
    borderRadius: 6,
    borderWidth: 2,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  boxSelected: { borderColor: colors.primary, backgroundColor: colors.primary },
  tick: { color: colors.primaryText, fontWeight: '700' },
  textBlock: { flex: 1, gap: 2 },
  title: { fontSize: 16, fontWeight: '600', color: colors.text },
  description: { fontSize: 14, color: colors.muted },
});
