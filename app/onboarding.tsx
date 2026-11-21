import { router } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button } from '@/components/Button';
import { RoleOption } from '@/components/RoleOption';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors } from '@/constants/theme';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';
import type { AppRole } from '@/types';

type SelectableRole = Extract<AppRole, 'customer' | 'rider'>;

export default function ProfileScreen() {
  const { session, profile, roles, refresh } = useSession();
  const existingRoles = new Set(roles.map((r) => r.role));

  const [fullName, setFullName] = useState(profile?.full_name ?? '');
  const [selected, setSelected] = useState<Set<SelectableRole>>(
    () => new Set((['customer', 'rider'] as const).filter((r) => existingRoles.has(r))),
  );
  const [nameError, setNameError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  function toggle(role: SelectableRole) {
    setFormError(null);
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(role)) next.delete(role);
      else next.add(role);
      return next;
    });
  }

  async function save() {
    const name = fullName.trim().replace(/\s+/g, ' ');
    if (name.length < 2) {
      setNameError('Enter your full name.');
      return;
    }
    if (selected.size === 0) {
      setFormError('Choose at least one way to use Dispatch.');
      return;
    }
    const userId = session?.user.id;
    if (!userId) return;

    setSaving(true);
    setNameError(null);
    setFormError(null);

    const { error: profileError } = await supabase
      .from('profiles')
      .update({ full_name: name })
      .eq('id', userId);

    const newRoles = [...selected].filter((r) => !existingRoles.has(r));
    const { error: rolesError } = newRoles.length
      ? await supabase.from('user_roles').insert(newRoles.map((role) => ({ user_id: userId, role })))
      : { error: null };

    if (profileError || rolesError) {
      setSaving(false);
      setFormError('We could not save your details. Check your connection and try again.');
      return;
    }

    // Riders go to the verification screen; it stays reachable while the session refreshes.
    if (selected.has('rider')) {
      router.replace('/rider-kyc');
    }
    await refresh();
    setSaving(false);
  }

  return (
    <Screen>
      <Text style={styles.title}>Tell us about you</Text>
      <TextField
        label="Full name"
        value={fullName}
        onChangeText={(text) => {
          setFullName(text);
          if (nameError) setNameError(null);
        }}
        placeholder="e.g. Adebayo Okafor"
        autoCapitalize="words"
        autoComplete="name"
        textContentType="name"
        error={nameError}
      />
      <Text style={styles.label}>How will you use Dispatch? You can choose both.</Text>
      <RoleOption
        title="Send packages"
        description="Order deliveries as a customer."
        selected={selected.has('customer')}
        locked={existingRoles.has('customer')}
        onToggle={() => toggle('customer')}
      />
      <RoleOption
        title="Deliver and earn"
        description="Ride with Dispatch. An admin approves every rider before they can go online."
        selected={selected.has('rider')}
        locked={existingRoles.has('rider')}
        onToggle={() => toggle('rider')}
      />
      {formError ? <Text style={styles.error}>{formError}</Text> : null}
      <Button title="Continue" onPress={save} loading={saving} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  label: { fontSize: 14, fontWeight: '600', color: colors.text },
  error: { color: colors.danger, fontSize: 14 },
});
