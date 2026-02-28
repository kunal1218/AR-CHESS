import { ARChessboard, type ARChessboardProps } from 'ar-client';
import { router, useLocalSearchParams } from 'expo-router';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ChessboardBackground } from '@/src/components/chessboard-background';
import { PrimaryButton } from '@/src/components/primary-button';
import { useGameRuntime } from '@/src/integration/use-game-runtime';

function normalizeMode(raw?: string | string[]): 'join' | 'create' {
  const resolved = Array.isArray(raw) ? raw[0] : raw;
  return resolved === 'create' ? 'create' : 'join';
}

export default function GameScreen() {
  const { mode: modeParam } = useLocalSearchParams<{ mode?: string }>();
  const mode = normalizeMode(modeParam);
  const { snapshot, events, dispatch, isBootstrapping, error } = useGameRuntime(mode);

  const headline = mode === 'create' ? 'Create Room Game' : 'Join Room Game';

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <ChessboardBackground />
        <View style={styles.overlay} />

        <ScrollView contentContainerStyle={styles.content}>
          <View style={styles.headerCard}>
            <Text style={styles.modeLabel}>{headline}</Text>
            <Text style={styles.title}>AR + Engine Sandbox</Text>
            <Text style={styles.subtitle}>
              Host UI remains in Expo shell. Game runtime, legal engine, events, and eval run underneath.
            </Text>
            <Text style={styles.meta}>
              {isBootstrapping
                ? 'Bootstrapping room + anchors + board...'
                : `Room ${snapshot.roomId ?? 'n/a'} • Board ${snapshot.boardId} • v${snapshot.version}`}
            </Text>
            {error ? <Text style={styles.error}>{error}</Text> : null}
          </View>

          <View style={styles.boardCard}>
            <ARChessboard
              fen={snapshot.fen}
              cloudAnchorIds={snapshot.anchorIds}
              onMove={(uci: string) => {
                void dispatch({ type: 'move', uci });
              }}
              onAnchorHosted={(
                hosted: Parameters<NonNullable<ARChessboardProps['onAnchorHosted']>>[0]
              ) => {
                void dispatch({ type: 'anchorHosted', cloudAnchorId: hosted.cloud_anchor_id });
              }}
            />
          </View>

          <View style={styles.runtimeCard}>
            <Text style={styles.cardTitle}>Runtime state</Text>
            <Text style={styles.runtimeLine}>Turn: {snapshot.activeColor === 'w' ? 'White' : 'Black'}</Text>
            <Text style={styles.runtimeLine}>In check: {snapshot.inCheck ? 'Yes' : 'No'}</Text>
            <Text style={styles.runtimeLine}>
              Eval: {snapshot.evaluation ? `${snapshot.evaluation.centipawns} cp (${snapshot.evaluation.source})` : 'Pending'}
            </Text>
            <Text style={styles.runtimeLine}>Anchors: {snapshot.anchorIds.length}</Text>
          </View>

          <View style={styles.runtimeCard}>
            <Text style={styles.cardTitle}>Game events</Text>
            {events.length === 0 ? (
              <Text style={styles.runtimeLine}>No events yet.</Text>
            ) : (
              events.map((event) => (
                <Text key={`${event.id}-${event.type}`} style={styles.eventLine}>
                  {event.type} @ {event.timestamp}
                </Text>
              ))
            )}
          </View>

          <PrimaryButton label="Back to Lobby" onPress={() => router.replace(`/lobby?mode=${mode}`)} variant="outline" />
        </ScrollView>
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
    backgroundColor: '#0e1319',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(8, 12, 18, 0.72)',
  },
  content: {
    paddingHorizontal: 20,
    paddingTop: 22,
    paddingBottom: 30,
    gap: 16,
  },
  headerCard: {
    borderRadius: 26,
    paddingHorizontal: 20,
    paddingVertical: 20,
    gap: 8,
    backgroundColor: 'rgba(17, 25, 34, 0.88)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.14)',
  },
  modeLabel: {
    color: '#d8c8a5',
    fontSize: 12,
    letterSpacing: 2,
    textTransform: 'uppercase',
    fontWeight: '700',
  },
  title: {
    color: '#f8f3e7',
    fontSize: 30,
    fontWeight: '800',
    letterSpacing: -0.5,
  },
  subtitle: {
    color: '#cdd5dd',
    fontSize: 14,
    lineHeight: 21,
  },
  meta: {
    color: '#e7dbc4',
    fontSize: 13,
    lineHeight: 19,
  },
  error: {
    color: '#ffb7b7',
    fontSize: 13,
    lineHeight: 19,
  },
  boardCard: {
    borderRadius: 26,
    padding: 14,
    backgroundColor: 'rgba(248, 243, 231, 0.92)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.9)',
  },
  runtimeCard: {
    borderRadius: 20,
    paddingHorizontal: 16,
    paddingVertical: 14,
    backgroundColor: 'rgba(17, 25, 34, 0.84)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.12)',
    gap: 5,
  },
  cardTitle: {
    color: '#f8f3e7',
    fontSize: 14,
    fontWeight: '700',
    marginBottom: 4,
  },
  runtimeLine: {
    color: '#d0d8e0',
    fontSize: 13,
    lineHeight: 20,
  },
  eventLine: {
    color: '#bdc7d0',
    fontSize: 12,
    lineHeight: 18,
  },
});
