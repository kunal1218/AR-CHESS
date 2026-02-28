import { ARChessboard, type ARChessboardProps } from 'ar-client';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View, type GestureResponderEvent, type LayoutChangeEvent } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { PrimaryButton } from '@/src/components/primary-button';
import { useGameRuntime } from '@/src/integration/use-game-runtime';

const BOARD_SIZE = 252;

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function normalizeMode(raw?: string | string[]): 'join' | 'create' {
  const resolved = Array.isArray(raw) ? raw[0] : raw;
  return resolved === 'create' ? 'create' : 'join';
}

export default function GameScreen() {
  const { mode: modeParam } = useLocalSearchParams<{ mode?: string }>();
  const mode = normalizeMode(modeParam);
  const [permission, requestPermission] = useCameraPermissions();
  const [placementMode, setPlacementMode] = useState(true);
  const [boardPlaced, setBoardPlaced] = useState(false);
  const [surfaceSize, setSurfaceSize] = useState({ width: 0, height: 0 });
  const [boardCenter, setBoardCenter] = useState({ xRatio: 0.5, yRatio: 0.64 });
  const { snapshot, events, dispatch, isBootstrapping, error } = useGameRuntime(mode);
  const latestEvent = events[0];

  const headline = mode === 'create' ? 'Create Room Game' : 'Join Room Game';
  const canRenderBoard = permission?.granted && surfaceSize.width > 0 && surfaceSize.height > 0;

  function handleSurfaceLayout(event: LayoutChangeEvent) {
    const { width, height } = event.nativeEvent.layout;
    setSurfaceSize({ width, height });
  }

  function handleSceneTap(event: GestureResponderEvent) {
    if (!placementMode || !surfaceSize.width || !surfaceSize.height) {
      return;
    }

    const { locationX, locationY } = event.nativeEvent;
    setBoardCenter({
      xRatio: clamp(locationX / surfaceSize.width, 0.2, 0.8),
      yRatio: clamp(locationY / surfaceSize.height, 0.2, 0.86),
    });
    setBoardPlaced(true);
    setPlacementMode(false);
  }

  const maxLeft = Math.max(8, surfaceSize.width - BOARD_SIZE - 8);
  const maxTop = Math.max(100, surfaceSize.height - BOARD_SIZE - 140);
  const boardLeft = clamp(surfaceSize.width * boardCenter.xRatio - BOARD_SIZE / 2, 8, maxLeft);
  const boardTop = clamp(surfaceSize.height * boardCenter.yRatio - BOARD_SIZE / 2, 100, maxTop);

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container} onLayout={handleSurfaceLayout}>
        {permission?.granted ? <CameraView style={StyleSheet.absoluteFill} facing="back" /> : null}
        <View style={styles.overlay} />

        <View style={styles.headerCard}>
          <Text style={styles.modeLabel}>{headline}</Text>
          <Text style={styles.title}>AR Camera Mode</Text>
          <Text style={styles.subtitle}>
            Camera feed is live. Tap scene to place the board, then tap pieces to play legal moves.
          </Text>
          <Text style={styles.meta}>
            {isBootstrapping
              ? 'Bootstrapping room + anchors + board...'
              : `Room ${snapshot.roomId ?? 'n/a'} • Board ${snapshot.boardId} • v${snapshot.version}`}
          </Text>
          {latestEvent ? <Text style={styles.meta}>Latest event: {latestEvent.type}</Text> : null}
          {error ? <Text style={styles.error}>{error}</Text> : null}
        </View>

        {permission?.granted ? null : (
          <View style={styles.permissionCard}>
            <Text style={styles.permissionTitle}>Camera permission required</Text>
            <Text style={styles.permissionBody}>
              AR mode needs live camera access. Allow camera permissions, then place the board in your scene.
            </Text>
            <PrimaryButton
              label="Enable Camera"
              onPress={() => {
                void requestPermission();
              }}
              variant="solid"
            />
          </View>
        )}

        {permission?.granted && placementMode ? (
          <Pressable onPress={handleSceneTap} style={styles.placementLayer}>
            <View style={styles.placementHint}>
              <Text style={styles.placementHintTitle}>Tap to place board</Text>
              <Text style={styles.placementHintBody}>Aim at the floor/table and tap where board center should be.</Text>
            </View>
          </Pressable>
        ) : null}

        {canRenderBoard && boardPlaced ? (
          <View style={[styles.boardLayer, { left: boardLeft, top: boardTop }]}>
            <ARChessboard
              visualMode="overlay"
              boardSize={BOARD_SIZE}
              useAnchorTransform={false}
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
        ) : null}

        <View style={styles.bottomPanel}>
          <View style={styles.runtimeRow}>
            <Text style={styles.runtimeLine}>Turn: {snapshot.activeColor === 'w' ? 'White' : 'Black'}</Text>
            <Text style={styles.runtimeLine}>Check: {snapshot.inCheck ? 'Yes' : 'No'}</Text>
            <Text style={styles.runtimeLine}>
              Eval: {snapshot.evaluation ? `${snapshot.evaluation.centipawns} cp` : 'Pending'}
            </Text>
          </View>

          <PrimaryButton
            label={placementMode ? 'Tap Scene To Place' : 'Reposition Board'}
            onPress={() => setPlacementMode(true)}
            variant="outline"
          />
          <PrimaryButton label="Back to Lobby" onPress={() => router.replace(`/lobby?mode=${mode}`)} variant="solid" />
        </View>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#000000',
  },
  container: {
    flex: 1,
    backgroundColor: '#000000',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(7, 10, 14, 0.34)',
  },
  headerCard: {
    marginTop: 10,
    marginHorizontal: 16,
    borderRadius: 26,
    paddingHorizontal: 16,
    paddingVertical: 14,
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
    fontSize: 28,
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
  permissionCard: {
    marginTop: 14,
    marginHorizontal: 16,
    borderRadius: 22,
    paddingHorizontal: 16,
    paddingVertical: 16,
    backgroundColor: 'rgba(17, 25, 34, 0.92)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.15)',
    gap: 10,
  },
  permissionTitle: {
    color: '#f8f3e7',
    fontSize: 17,
    fontWeight: '700',
  },
  permissionBody: {
    color: '#d0d8e0',
    fontSize: 14,
    lineHeight: 21,
  },
  placementLayer: {
    position: 'absolute',
    top: 120,
    left: 0,
    right: 0,
    bottom: 130,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: 20,
  },
  placementHint: {
    borderRadius: 18,
    backgroundColor: 'rgba(10, 15, 22, 0.78)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.2)',
    paddingHorizontal: 16,
    paddingVertical: 14,
    gap: 6,
    maxWidth: 320,
  },
  placementHintTitle: {
    color: '#f8f3e7',
    fontSize: 16,
    fontWeight: '700',
    textAlign: 'center',
  },
  placementHintBody: {
    color: '#d0d8e0',
    fontSize: 13,
    lineHeight: 19,
    textAlign: 'center',
  },
  boardLayer: {
    position: 'absolute',
  },
  bottomPanel: {
    marginTop: 'auto',
    marginBottom: 12,
    marginHorizontal: 16,
    borderRadius: 20,
    padding: 12,
    backgroundColor: 'rgba(12, 18, 25, 0.78)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.16)',
    gap: 10,
  },
  runtimeRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 12,
    flexWrap: 'wrap',
  },
  runtimeLine: {
    color: '#d0d8e0',
    fontSize: 14,
    lineHeight: 18,
  },
});
