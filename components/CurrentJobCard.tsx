import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';

type CurrentJobCardProps = {
  onOpen: () => void;
};

export function CurrentJobCard({ onOpen }: CurrentJobCardProps) {
  return (
    <View style={styles.card}>
      <Text style={styles.eyebrow}>Current job</Text>
      <Text style={styles.title}>You have a delivery in progress</Text>
      <Text style={styles.body}>You won't get new requests until this job is finished.</Text>
      <Button title="Open job" onPress={onOpen} />
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: '#ecfdf5', borderWidth: 1, borderColor: colors.success, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.success, textTransform: 'uppercase' },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
});
