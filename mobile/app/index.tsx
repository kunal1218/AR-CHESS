import { router } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ChessboardBackground } from '@/src/components/chessboard-background';
import { PrimaryButton } from '@/src/components/primary-button';
import { API_BASE_URL, hasApiBaseUrl } from '@/src/config';

type PingState = {
  status: 'idle' | 'loading' | 'success' | 'error';
  messages: string[];
};

export default function LandingScreen() {
  const [pingState, setPingState] = useState<PingState>({
    status: 'idle',
    messages: [],
  });

  async function handlePing() {
    if (!hasApiBaseUrl()) {
      setPingState({
        status: 'error',
        messages: ['Set EXPO_PUBLIC_API_BASE_URL to your Railway backend URL first.'],
      });
      return;
    }

    setPingState({
      status: 'loading',
      messages: [],
    });

    try {
      const response = await fetch(`${API_BASE_URL}/health/ping`);
      const payload = (await response.json()) as {
        messages?: string[];
        checks?: {
          postgres?: {
            ok: boolean;
            message: string;
          };
        };
      };

      if (!response.ok) {
        const fallback = payload.checks?.postgres?.message ?? 'Health ping failed.';
        throw new Error(fallback);
      }

      setPingState({
        status: 'success',
        messages: payload.messages ?? ['Server ping successful', 'Postgres ping successful'],
      });
    } catch (error) {
      setPingState({
        status: 'error',
        messages: [error instanceof Error ? error.message : 'Unable to reach the backend.'],
      });
    }
  }

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <ChessboardBackground />
        <View style={styles.overlay} />
        <View style={styles.glow} />

        <View style={styles.content}>
          <View style={styles.copyBlock}>
            <Text style={styles.eyebrow}>Expo Go • iPhone first</Text>
            <Text style={styles.title}>AR Chess</Text>
            <Text style={styles.subtitle}>Place boards in rooms • Play together</Text>
          </View>

          <View style={styles.buttonGroup}>
            <PrimaryButton
              label="Join"
              onPress={() => router.push('/lobby?mode=join')}
              variant="solid"
            />
            <PrimaryButton
              label="Create"
              onPress={() => router.push('/lobby?mode=create')}
              variant="outline"
            />
            <PrimaryButton
              label={pingState.status === 'loading' ? 'Pinging...' : 'Ping Server + Postgres'}
              onPress={() => {
                void handlePing();
              }}
              variant="ghost"
            />
          </View>

          {pingState.status !== 'idle' ? (
            <View
              style={[
                styles.pingCard,
                pingState.status === 'error' ? styles.pingCardError : null,
              ]}>
              {pingState.status === 'loading' ? (
                <View style={styles.loadingRow}>
                  <ActivityIndicator color="#f3e4be" />
                  <Text style={styles.pingHeading}>Checking Railway server and Postgres...</Text>
                </View>
              ) : (
                <>
                  <Text style={styles.pingHeading}>
                    {pingState.status === 'success'
                      ? 'Health checks completed'
                      : 'Health checks failed'}
                  </Text>
                  <View style={styles.messageList}>
                    {pingState.messages.map((message) => (
                      <Text key={message} style={styles.pingMessage}>
                        • {message}
                      </Text>
                    ))}
                  </View>
                </>
              )}
            </View>
          ) : null}

          <View style={styles.footerCard}>
            <Text style={styles.footerText}>
              Join/Create and the game sandbox still work without the server. The ping button is
              only for Railway health verification.
            </Text>
          </View>
        </View>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#0e1319',
  },
  container: {
    flex: 1,
    position: 'relative',
    backgroundColor: '#0e1319',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(10, 16, 23, 0.58)',
  },
  glow: {
    position: 'absolute',
    top: 72,
    alignSelf: 'center',
    width: 260,
    height: 260,
    borderRadius: 999,
    backgroundColor: 'rgba(211, 174, 108, 0.16)',
  },
  content: {
    flex: 1,
    justifyContent: 'center',
    paddingHorizontal: 24,
    gap: 28,
  },
  copyBlock: {
    gap: 12,
    alignItems: 'center',
  },
  eyebrow: {
    color: '#d8c8a5',
    fontSize: 12,
    letterSpacing: 2.2,
    textTransform: 'uppercase',
    fontWeight: '700',
  },
  title: {
    color: '#f8f3e7',
    fontSize: 52,
    fontWeight: '800',
    letterSpacing: -1.4,
  },
  subtitle: {
    color: '#d3dae2',
    fontSize: 17,
    lineHeight: 24,
    textAlign: 'center',
    maxWidth: 280,
  },
  buttonGroup: {
    gap: 14,
  },
  footerCard: {
    alignSelf: 'center',
    maxWidth: 320,
    borderRadius: 24,
    paddingHorizontal: 18,
    paddingVertical: 14,
    backgroundColor: 'rgba(248, 243, 231, 0.08)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.12)',
  },
  pingCard: {
    borderRadius: 24,
    paddingHorizontal: 18,
    paddingVertical: 16,
    backgroundColor: 'rgba(14, 39, 28, 0.84)',
    borderWidth: 1,
    borderColor: 'rgba(116, 214, 157, 0.22)',
    gap: 10,
  },
  pingCardError: {
    backgroundColor: 'rgba(56, 18, 25, 0.84)',
    borderColor: 'rgba(221, 121, 121, 0.22)',
  },
  loadingRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  pingHeading: {
    color: '#f8f3e7',
    fontSize: 15,
    fontWeight: '700',
  },
  messageList: {
    gap: 6,
  },
  pingMessage: {
    color: '#d7e4da',
    fontSize: 14,
    lineHeight: 20,
  },
  footerText: {
    color: '#c7d0d9',
    fontSize: 14,
    lineHeight: 20,
    textAlign: 'center',
  },
});
