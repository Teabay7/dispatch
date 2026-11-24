import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { colors, spacing } from '@/constants/theme';
import type { PlaceChoice } from '@/lib/orders';
import { searchPlaces, type Suggestion } from '@/lib/ordersApi';

type PlaceSearchFieldProps = {
  label: string;
  placeholder: string;
  value: PlaceChoice | null;
  onChange: (place: PlaceChoice | null) => void;
  sessionToken: string;
  error?: string | null;
  /** Shows "Use my current location" (pickup only). */
  onUseCurrentLocation?: () => void;
  locating?: boolean;
  disabled?: boolean;
};

const MIN_CHARS = 3;
const DEBOUNCE_MS = 400;

export function PlaceSearchField({
  label,
  placeholder,
  value,
  onChange,
  sessionToken,
  error,
  onUseCurrentLocation,
  locating = false,
  disabled = false,
}: PlaceSearchFieldProps) {
  const [text, setText] = useState('');
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const latestQuery = useRef('');

  // Debounced search; only the newest answer is shown.
  useEffect(() => {
    const query = text.trim();
    latestQuery.current = query;
    if (value || query.length < MIN_CHARS) {
      setSuggestions([]);
      setSearching(false);
      return;
    }
    setSearching(true);
    const timer = setTimeout(async () => {
      const result = await searchPlaces(query, sessionToken);
      if (latestQuery.current !== query) return;
      setSearching(false);
      setSearchError(result.error);
      setSuggestions(result.data ?? []);
    }, DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [text, value, sessionToken]);

  function choose(s: Suggestion) {
    onChange({ kind: 'place', placeId: s.placeId, label: s.secondaryText ? `${s.mainText}, ${s.secondaryText}` : s.mainText });
    setText('');
    setSuggestions([]);
  }

  return (
    <View style={styles.container}>
      <Text style={styles.label}>{label}</Text>

      {value ? (
        <View style={[styles.chosen, !!error && styles.inputError]}>
          <Text style={styles.chosenText}>{value.label}</Text>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Change ${label.toLowerCase()}`}
            onPress={() => onChange(null)}
            disabled={disabled}
          >
            <Text style={styles.change}>Change</Text>
          </Pressable>
        </View>
      ) : (
        <>
          <TextInput
            value={text}
            onChangeText={setText}
            placeholder={placeholder}
            placeholderTextColor={colors.muted}
            autoCorrect={false}
            editable={!disabled}
            style={[styles.input, !!error && styles.inputError]}
          />
          {onUseCurrentLocation ? (
            <Pressable
              accessibilityRole="button"
              onPress={onUseCurrentLocation}
              disabled={disabled || locating}
              style={styles.locationButton}
            >
              {locating ? <ActivityIndicator color={colors.primary} /> : null}
              <Text style={styles.locationText}>{locating ? 'Finding you…' : 'Use my current location'}</Text>
            </Pressable>
          ) : null}
          {searching ? <ActivityIndicator color={colors.primary} /> : null}
          {suggestions.map((s) => (
            <Pressable key={s.placeId} accessibilityRole="button" onPress={() => choose(s)} style={styles.suggestion}>
              <Text style={styles.mainText}>{s.mainText}</Text>
              {s.secondaryText ? <Text style={styles.secondaryText}>{s.secondaryText}</Text> : null}
            </Pressable>
          ))}
          {searchError ? <Text style={styles.error}>{searchError}</Text> : null}
        </>
      )}
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: spacing.xs },
  label: { fontSize: 14, fontWeight: '600', color: colors.text },
  input: {
    minHeight: 50,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    paddingHorizontal: spacing.md,
    fontSize: 18,
    color: colors.text,
  },
  inputError: { borderColor: colors.danger },
  chosen: {
    minHeight: 50,
    borderWidth: 1,
    borderColor: colors.primary,
    borderRadius: 10,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  chosenText: { flex: 1, fontSize: 16, color: colors.text },
  change: { fontSize: 15, fontWeight: '600', color: colors.primary },
  locationButton: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, paddingVertical: spacing.xs },
  locationText: { fontSize: 15, fontWeight: '600', color: colors.primary },
  suggestion: { paddingVertical: spacing.sm, borderBottomWidth: 1, borderColor: colors.border },
  mainText: { fontSize: 16, color: colors.text },
  secondaryText: { fontSize: 13, color: colors.muted },
  error: { color: colors.danger, fontSize: 14 },
});
