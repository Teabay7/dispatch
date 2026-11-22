import * as Location from 'expo-location';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Linking } from 'react-native';

import {
  friendlyOnlineError,
  isAccessRefused,
  LOCATION_WATCH,
  SEND_RULES,
  mapLocationAccess,
  shouldRequestPermission,
  shouldSendHeartbeat,
  shouldSendLocation,
  type AccessAction,
  type Fix,
  type LocationAccess,
  type PermissionInput,
  type Sent,
} from '@/lib/riderOnline';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';

export type OnlinePhase = 'loading' | 'offline' | 'going_online' | 'online' | 'going_offline';

/** How often the app checks whether a heartbeat is due. */
const HEARTBEAT_CHECK_MS = 30_000;
/** Give up on the first position fix after this long. */
const FIRST_FIX_TIMEOUT_MS = 20_000;

function toPermissionInput(p: Location.LocationPermissionResponse): PermissionInput {
  return {
    status: p.status as PermissionInput['status'],
    canAskAgain: p.canAskAgain,
    androidAccuracy: p.android?.accuracy ?? null,
  };
}

function toFix(location: Location.LocationObject): Fix {
  return {
    lat: location.coords.latitude,
    lng: location.coords.longitude,
    accuracyM: location.coords.accuracy ?? null,
    at: Date.now(),
  };
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ]);
}

/**
 * Online/offline for an approved rider with an active rider role, and sending their
 * location while online. Foreground only: updates stop when the app is not open,
 * and the server sets the rider offline once they go stale.
 *
 * `onAccessLost` runs when the server refuses (suspended, rejected, set offline),
 * so the caller can reload roles and KYC status.
 */
export function useRiderOnline(enabled: boolean, onAccessLost: () => void) {
  const { session } = useSession();
  const userId = session?.user.id ?? null;

  const [phase, setPhase] = useState<OnlinePhase>('loading');
  const [access, setAccess] = useState<Exclude<LocationAccess, 'ready'> | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lastSentAt, setLastSentAt] = useState<number | null>(null);
  const [sendFailing, setSendFailing] = useState(false);
  const [noFix, setNoFix] = useState(false);

  const watchRef = useRef<Location.LocationSubscription | null>(null);
  const heartbeatRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const lastSentRef = useRef<Sent | null>(null);
  const latestFixRef = useRef<Fix | null>(null);
  const sendingRef = useRef(false);
  const heartbeatRunningRef = useRef(false);
  const onlineRef = useRef(false);
  const onAccessLostRef = useRef(onAccessLost);
  onAccessLostRef.current = onAccessLost;

  const stopTracking = useCallback(() => {
    watchRef.current?.remove();
    watchRef.current = null;
    if (heartbeatRef.current) clearInterval(heartbeatRef.current);
    heartbeatRef.current = null;
    lastSentRef.current = null;
    latestFixRef.current = null;
    sendingRef.current = false;
    onlineRef.current = false;
    setLastSentAt(null);
    setSendFailing(false);
    setNoFix(false);
  }, []);

  /** The server refused us: stop everything and let the caller reload status. */
  const handleRefused = useCallback(
    (refusal: { code?: string | null; message?: string | null }) => {
      stopTracking();
      setPhase('offline');
      setError(friendlyOnlineError(refusal));
      onAccessLostRef.current();
    },
    [stopTracking],
  );

  const send = useCallback(
    async (fix: Fix): Promise<boolean> => {
      if (!userId || sendingRef.current) return false;
      sendingRef.current = true;
      const { error: sendError } = await supabase
        .from('rider_locations')
        .upsert({ rider_id: userId, lat: fix.lat, lng: fix.lng, accuracy_m: fix.accuracyM }, { onConflict: 'rider_id' });
      sendingRef.current = false;
      if (!onlineRef.current) return false; // went offline while sending

      if (sendError) {
        if (isAccessRefused(sendError)) {
          handleRefused(sendError);
        } else {
          setSendFailing(true); // no network: try again on the next fix or heartbeat
        }
        return false;
      }
      lastSentRef.current = { lat: fix.lat, lng: fix.lng, at: fix.at };
      setLastSentAt(fix.at);
      setSendFailing(false);
      return true;
    },
    [userId, handleRefused],
  );

  const heartbeat = useCallback(async () => {
    if (!onlineRef.current || heartbeatRunningRef.current) return;
    const last = lastSentRef.current;
    if (last && Date.now() - last.at < SEND_RULES.heartbeatMs) return; // not due yet
    heartbeatRunningRef.current = true;
    try {
      const servicesOn = await Location.hasServicesEnabledAsync().catch(() => true);
      if (!servicesOn) {
        setNoFix(true); // stop sending: the server sets the rider offline once stale
        return;
      }
      // A still rider gets no watch updates (distance filter), so fetch a fresh fix.
      let fix = latestFixRef.current;
      if (!fix || Date.now() - fix.at > SEND_RULES.minIntervalMs) {
        try {
          fix = toFix(
            await withTimeout(
              Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
              FIRST_FIX_TIMEOUT_MS,
            ),
          );
          latestFixRef.current = fix;
        } catch {
          setNoFix(true);
          return;
        }
      }
      setNoFix(false);
      if (shouldSendHeartbeat(lastSentRef.current, fix, Date.now())) await send(fix);
    } finally {
      heartbeatRunningRef.current = false;
    }
  }, [send]);

  const startTracking = useCallback(async () => {
    onlineRef.current = true;
    watchRef.current = await Location.watchPositionAsync(
      {
        accuracy: Location.Accuracy.Balanced,
        timeInterval: LOCATION_WATCH.timeIntervalMs,
        distanceInterval: LOCATION_WATCH.distanceIntervalM,
      },
      (location) => {
        const fix = toFix(location);
        latestFixRef.current = fix;
        setNoFix(false);
        if (shouldSendLocation(lastSentRef.current, fix)) send(fix);
      },
      () => setNoFix(true),
    );
    if (!onlineRef.current) {
      // Went offline while the watch was starting.
      watchRef.current.remove();
      watchRef.current = null;
      return;
    }
    heartbeatRef.current = setInterval(heartbeat, HEARTBEAT_CHECK_MS);
  }, [send, heartbeat]);

  /** Reads is_online from the server (the source of truth). */
  const loadServerState = useCallback(async (): Promise<boolean | null> => {
    if (!userId) return null;
    const { data, error: loadError } = await supabase
      .from('rider_details')
      .select('is_online')
      .eq('user_id', userId)
      .maybeSingle();
    if (loadError || !data) return null;
    return data.is_online;
  }, [userId]);

  /** Checks permission and location services, asking when the prompt can still appear. */
  const checkAccess = useCallback(async (): Promise<LocationAccess> => {
    let permission = await Location.getForegroundPermissionsAsync();
    if (shouldRequestPermission(toPermissionInput(permission))) {
      permission = await Location.requestForegroundPermissionsAsync();
    }
    const servicesOn = await Location.hasServicesEnabledAsync().catch(() => false);
    return mapLocationAccess(toPermissionInput(permission), servicesOn);
  }, []);

  const goOnline = useCallback(async () => {
    if (!userId) return;
    setError(null);
    setAccess(null);
    setPhase('going_online');

    let accessState: LocationAccess;
    try {
      accessState = await checkAccess();
    } catch {
      setPhase('offline');
      setError('We could not check your location settings. Try again.');
      return;
    }
    if (accessState !== 'ready') {
      setAccess(accessState);
      setPhase('offline');
      return;
    }

    let firstFix: Fix;
    try {
      firstFix = toFix(
        await withTimeout(
          Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
          FIRST_FIX_TIMEOUT_MS,
        ),
      );
    } catch {
      setPhase('offline');
      setError('We could not find your location. Move somewhere with a clearer view of the sky and try again.');
      return;
    }

    const { error: toggleError } = await supabase
      .from('rider_details')
      .update({ is_online: true })
      .eq('user_id', userId);
    if (toggleError) {
      setPhase('offline');
      setError(friendlyOnlineError(toggleError));
      // Refused by the server (not approved / suspended): reload the rider's status.
      if (toggleError.code === 'P0001' || isAccessRefused(toggleError)) onAccessLostRef.current();
      return;
    }

    onlineRef.current = true;
    latestFixRef.current = firstFix;
    const sent = await send(firstFix);
    if (!sent && !onlineRef.current) return; // refused: handleRefused already ran
    try {
      await startTracking();
    } catch {
      // Could not start the watch: do not stay online without sending.
      onlineRef.current = false;
      await supabase.from('rider_details').update({ is_online: false }).eq('user_id', userId);
      stopTracking();
      setPhase('offline');
      setError('We could not start sharing your location. Try again.');
      return;
    }
    setPhase('online');
  }, [userId, checkAccess, send, startTracking, stopTracking]);

  /** Stops sending first, then tells the server. Returns false if the server was not reached. */
  const goOffline = useCallback(async (): Promise<boolean> => {
    if (!userId) return true;
    stopTracking();
    setPhase('going_offline');
    setError(null);
    const { error: toggleError } = await supabase
      .from('rider_details')
      .update({ is_online: false })
      .eq('user_id', userId);
    setPhase('offline');
    if (toggleError) {
      setError(
        'We stopped sharing your location, but could not reach Dispatch. You will be set offline automatically in a few minutes.',
      );
      return false;
    }
    return true;
  }, [userId, stopTracking]);

  const fixAccess = useCallback(
    async (action: AccessAction) => {
      if (action === 'open_settings') {
        await Linking.openSettings();
        return;
      }
      if (action === 'enable_services') {
        try {
          await Location.enableNetworkProviderAsync();
        } catch {
          return; // the rider said no; keep the message on screen
        }
      }
      await goOnline();
    },
    [goOnline],
  );

  // Initial state from the server. If the server says online (e.g. the app was
  // restarted), resume sending only if location is still usable; otherwise go offline.
  useEffect(() => {
    if (!enabled || !userId) {
      stopTracking();
      setPhase('offline');
      return;
    }
    let cancelled = false;
    (async () => {
      setPhase('loading');
      const serverOnline = await loadServerState();
      if (cancelled) return;
      if (serverOnline) {
        await goOnline();
      } else {
        setPhase('offline');
      }
    })();
    return () => {
      cancelled = true;
      stopTracking();
    };
    // goOnline is intentionally not a dependency: run once per rider/enabled change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, userId, loadServerState, stopTracking]);

  // Foreground only: pause the heartbeat in the background (so we never claim
  // freshness without a live app), and re-check the server when coming back.
  useEffect(() => {
    if (!enabled) return;
    const subscription = AppState.addEventListener('change', async (state) => {
      if (state !== 'active') {
        if (heartbeatRef.current) clearInterval(heartbeatRef.current);
        heartbeatRef.current = null;
        return;
      }
      if (!onlineRef.current) return;
      const serverOnline = await loadServerState();
      if (serverOnline === false) {
        stopTracking();
        setPhase('offline');
        setError('You were set offline because Dispatch did not hear from your phone for a few minutes.');
        onAccessLostRef.current();
        return;
      }
      if (!heartbeatRef.current) heartbeatRef.current = setInterval(heartbeat, HEARTBEAT_CHECK_MS);
      try {
        const fix = toFix(
          await withTimeout(
            Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
            FIRST_FIX_TIMEOUT_MS,
          ),
        );
        latestFixRef.current = fix;
        await send(fix);
      } catch {
        setNoFix(true);
      }
    });
    return () => subscription.remove();
  }, [enabled, loadServerState, stopTracking, heartbeat, send]);

  return {
    phase,
    isOnline: phase === 'online',
    access,
    error,
    lastSentAt,
    sendFailing,
    noFix,
    goOnline,
    goOffline,
    fixAccess,
  };
}
