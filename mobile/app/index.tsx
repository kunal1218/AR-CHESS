import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { RefreshControl, StyleSheet, Text, View } from 'react-native';

import { apiClient } from '@/src/api/client';
import { APP_ENV, API_BASE_URL, API_BASE_URL_HINT, SHOULD_WARN_LOCALHOST } from '@/src/config';
import { ActionButton } from '@/src/components/action-button';
import { ScreenShell } from '@/src/components/screen-shell';
import { getStoredSession, type StoredRoomSession } from '@/src/storage/session';

type PingState = {
  tone: 'idle' | 'success' | 'error';
  message: string;
};

export default function HomeScreen() {
  const router = useRouter();
  const [session, setSession] = useState<StoredRoomSession | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isPinging, setIsPinging] = useState(false);
  const [pingState, setPingState] = useState<PingState>({
    tone: 'idle',
    message: 'Use Dev: Ping Server to verify the phone can reach FastAPI over your LAN.',
  });

  useEffect(() => {
    void refreshSession();
  }, []);

  async function refreshSession() {
    setIsRefreshing(true);
    setSession(await getStoredSession());
    setIsRefreshing(false);
  }

  async function handlePing() {
    setIsPinging(true);
    try {
      const response = await apiClient.pingServer();
      setPingState({
        tone: 'success',
        message: `Connected to ${response.info?.title ?? 'the FastAPI server'} via ${API_BASE_URL}.`,
      });
    } catch (error) {
      setPingState({
        tone: 'error',
        message: error instanceof Error ? error.message : 'Unable to reach the server.',
      });
    } finally {
      setIsPinging(false);
    }
  }

  return (
    <ScreenShell
      eyebrow="Expo Go"
      title="AR Chess"
      subtitle="iPhone-first managed client for room scan, backend ping, and board setup. AR rendering stays stubbed until the native strategy is ready."
      refreshControl={<RefreshControl refreshing={isRefreshing} onRefresh={refreshSession} />}>
      <View style={styles.heroCard}>
        <Text style={styles.heroLabel}>Active environment</Text>
        <Text style={styles.heroValue}>{APP_ENV}</Text>
        <Text style={styles.heroMeta}>API base URL</Text>
        <Text style={styles.heroUrl}>{API_BASE_URL || 'Not configured yet'}</Text>
      </View>

      {SHOULD_WARN_LOCALHOST ? (
        <View style={styles.warningCard}>
          <Text style={styles.warningTitle}>Localhost will not work from an iPhone.</Text>
          <Text style={styles.warningBody}>{API_BASE_URL_HINT}</Text>
        </View>
      ) : null}

      <View style={styles.sessionCard}>
        <Text style={styles.sectionLabel}>Last scanned room</Text>
        <Text style={styles.sessionValue}>{session?.roomId ?? 'No room stored yet'}</Text>
        <Text style={styles.sessionMeta}>
          {session?.markerId
            ? `Marker ${session.markerId}`
            : 'Scan a QR marker to resolve the room id through the server.'}
        </Text>
      </View>

      <View style={styles.actions}>
        <ActionButton
          label="Scan Room Marker"
          caption="Open the camera, read a QR marker, and POST /v1/rooms/scan."
          onPress={() => router.push('/scan')}
        />
        <ActionButton
          label="Open Board"
          caption="Load the stored room id, fetch anchors, and show board-ready state."
          onPress={() => router.push('/board')}
          variant="secondary"
        />
        <ActionButton
          label={isPinging ? 'Pinging Server...' : 'Dev: Ping Server'}
          caption="Calls GET /openapi.json so you can verify LAN connectivity from Expo Go."
          onPress={handlePing}
          disabled={isPinging}
        />
      </View>

      <View style={[styles.statusCard, pingState.tone === 'error' ? styles.statusError : null]}>
        <Text style={styles.sectionLabel}>Server status</Text>
        <Text style={styles.statusMessage}>{pingState.message}</Text>
      </View>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  heroCard: {
    borderRadius: 28,
    backgroundColor: '#153248',
    padding: 24,
    gap: 6,
  },
  heroLabel: {
    color: '#d6e5f3',
    fontSize: 12,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
  },
  heroValue: {
    color: '#f8f4ed',
    fontSize: 30,
    fontWeight: '700',
  },
  heroMeta: {
    color: '#9fc2de',
    fontSize: 13,
    marginTop: 8,
  },
  heroUrl: {
    color: '#f8f4ed',
    fontSize: 16,
    fontWeight: '600',
  },
  warningCard: {
    borderRadius: 22,
    backgroundColor: '#f9dcc2',
    padding: 18,
    gap: 8,
  },
  warningTitle: {
    color: '#6e2f14',
    fontSize: 16,
    fontWeight: '700',
  },
  warningBody: {
    color: '#6e2f14',
    fontSize: 14,
    lineHeight: 21,
  },
  sessionCard: {
    borderRadius: 24,
    backgroundColor: '#fffaf2',
    padding: 20,
    gap: 6,
    borderWidth: 1,
    borderColor: '#eadfce',
  },
  sectionLabel: {
    color: '#7b6e61',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.1,
    textTransform: 'uppercase',
  },
  sessionValue: {
    color: '#1d1b18',
    fontSize: 24,
    fontWeight: '700',
  },
  sessionMeta: {
    color: '#6f665d',
    fontSize: 15,
    lineHeight: 22,
  },
  actions: {
    gap: 14,
  },
  statusCard: {
    borderRadius: 24,
    backgroundColor: '#ebf3ef',
    padding: 20,
    gap: 8,
  },
  statusError: {
    backgroundColor: '#f7e7e6',
  },
  statusMessage: {
    color: '#244034',
    fontSize: 15,
    lineHeight: 22,
  },
});
