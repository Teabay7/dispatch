import { useState } from 'react';
import { FlatList, Modal, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { BANKS, OTHER_BANK } from '@/lib/bankAccount';

type BankPickerProps = {
  value: string;
  onChange: (bank: string) => void;
  error?: string | null;
  disabled?: boolean;
};

const OPTIONS: string[] = [...BANKS, OTHER_BANK];

export function BankPicker({ value, onChange, error, disabled = false }: BankPickerProps) {
  const [open, setOpen] = useState(false);

  function choose(bank: string) {
    onChange(bank);
    setOpen(false);
  }

  return (
    <View style={styles.container}>
      <Text style={styles.label}>Bank</Text>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={value ? `Bank: ${value}. Change bank` : 'Choose your bank'}
        onPress={() => setOpen(true)}
        disabled={disabled}
        style={[styles.field, !!error && styles.fieldError]}
      >
        <Text style={value ? styles.value : styles.placeholder}>{value || 'Choose your bank'}</Text>
        <Text style={styles.chevron}>▾</Text>
      </Pressable>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      <Modal visible={open} animationType="slide" onRequestClose={() => setOpen(false)}>
        <View style={styles.sheet}>
          <Text style={styles.sheetTitle}>Choose your bank</Text>
          <FlatList
            data={OPTIONS}
            keyExtractor={(item) => item}
            renderItem={({ item }) => (
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ selected: item === value }}
                onPress={() => choose(item)}
                style={[styles.option, item === value && styles.optionSelected]}
              >
                <Text style={styles.optionText}>{item === OTHER_BANK ? 'Other (type the name)' : item}</Text>
              </Pressable>
            )}
          />
          <Button title="Cancel" variant="secondary" onPress={() => setOpen(false)} />
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: spacing.xs },
  label: { fontSize: 14, fontWeight: '600', color: colors.text },
  field: {
    minHeight: 50,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    paddingHorizontal: spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  fieldError: { borderColor: colors.danger },
  value: { fontSize: 18, color: colors.text },
  placeholder: { fontSize: 18, color: colors.muted },
  chevron: { fontSize: 18, color: colors.muted },
  error: { color: colors.danger, fontSize: 14 },
  sheet: { flex: 1, padding: spacing.lg, paddingTop: spacing.xl, gap: spacing.md, backgroundColor: colors.background },
  sheetTitle: { fontSize: 22, fontWeight: '700', color: colors.text },
  option: { paddingVertical: spacing.md, paddingHorizontal: spacing.sm, borderBottomWidth: 1, borderColor: colors.border },
  optionSelected: { backgroundColor: '#f0fdfa' },
  optionText: { fontSize: 17, color: colors.text },
});
