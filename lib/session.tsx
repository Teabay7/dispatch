import type { Session } from '@supabase/supabase-js';
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';

import { supabase } from '@/lib/supabase';
import type { Profile, UserRole } from '@/types';

type SessionState = {
  /** True until we know whether the user is signed in, and have loaded their profile. */
  loading: boolean;
  session: Session | null;
  profile: Profile | null;
  roles: UserRole[];
  /** A user is onboarded once they have a name and at least one role. */
  isOnboarded: boolean;
  /** Set when the profile or roles could not be loaded (e.g. no network). */
  error: string | null;
  refresh: () => Promise<void>;
};

const SessionContext = createContext<SessionState | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [roles, setRoles] = useState<UserRole[]>([]);
  // Which user's profile/roles are currently loaded (null = none yet).
  const [loadedUserId, setLoadedUserId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthReady(true);
    });
    const { data } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id ?? null;

  const loadAccount = useCallback(async (id: string) => {
    setError(null);
    const [profileResult, rolesResult] = await Promise.all([
      supabase.from('profiles').select('id, phone, full_name').eq('id', id).maybeSingle(),
      supabase.from('user_roles').select('role, status').eq('user_id', id),
    ]);
    if (profileResult.error || rolesResult.error) {
      setError('We could not load your account. Check your connection and try again.');
    } else {
      setProfile(profileResult.data);
      setRoles(rolesResult.data);
    }
    setLoadedUserId(id);
  }, []);

  useEffect(() => {
    if (userId) {
      loadAccount(userId);
    } else {
      setProfile(null);
      setRoles([]);
      setError(null);
      setLoadedUserId(null);
    }
  }, [userId, loadAccount]);

  const refresh = useCallback(async () => {
    if (userId) await loadAccount(userId);
  }, [userId, loadAccount]);

  const hasName = !!profile?.full_name?.trim();
  const value: SessionState = {
    loading: !authReady || (!!userId && loadedUserId !== userId),
    session,
    profile,
    roles,
    isOnboarded: hasName && roles.length > 0,
    error,
    refresh,
  };

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionState {
  const value = useContext(SessionContext);
  if (!value) throw new Error('useSession must be used inside <SessionProvider>');
  return value;
}
