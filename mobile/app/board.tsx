import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { apiClient } from '@/src/api/client';
import type { AnchorRecord, BoardState } from '@/src/api/types';
import { SEED_BOARD_ID } from '@/src/config';
import { ActionButton } from '@/src/components/action-button';
import { ScreenShell } from '@/src/components/screen-shell';
import { getStoredSession } from '@/src/storage/session';

async function loadBoardData(nextRoomId: string) {
  const anchorsResponse = await apiClient.getRoomAnchors(nextRoomId);
  const board = SEED_BOARD_ID ? await apiClient.getBoard(SEED_BOARD_ID) : null;

  return {
    anchors: anchorsResponse.anchors,
    board,
    feedback: `Fetched ${anchorsResponse.anchors.length} anchor record${anchorsResponse.anchors.length === 1 ? '' : 's'} for room ${nextRoomId}.`,
  };
}

export default function BoardScreen() {
  const params = useLocalSearchParams<{ roomId?: string }>();
  const [roomId, setRoomId] = useState<string | null>(params.roomId ?? null);
  const [anchors, setAnchors] = useState<AnchorRecord[]>([]);
  const [board, setBoard] = useState<BoardState | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [feedback, setFeedback] = useState('Load a room to fetch anchor metadata from the server.');

  useEffect(() => {
    async function bootstrapBoard() {
      const storedSession = await getStoredSession();
      const resolvedRoomId = params.roomId ?? storedSession?.roomId ?? null;

      setRoomId(resolvedRoomId);
      if (!resolvedRoomId) {
        setAnchors([]);
        setBoard(null);
        setFeedback('No room is stored yet. Scan a room marker first.');
        return;
      }

      setIsLoading(true);
      try {
        const result = await loadBoardData(resolvedRoomId);
        setAnchors(result.anchors);
        setBoard(result.board);
        setFeedback(result.feedback);
      } catch (error) {
        setAnchors([]);
        setBoard(null);
        setFeedback(error instanceof Error ? error.message : 'Unable to load board data.');
      } finally {
        setIsLoading(false);
      }
    }

    void bootstrapBoard();
  }, [params.roomId]);

  async function refreshBoard(nextRoomId = roomId) {
    if (!nextRoomId) {
      setFeedback('Scan a room marker before opening the board.');
      return;
    }

    setIsLoading(true);
    try {
      const result = await loadBoardData(nextRoomId);
      setAnchors(result.anchors);
      setBoard(result.board);
      setFeedback(result.feedback);
    } catch (error) {
      setAnchors([]);
      setBoard(null);
      setFeedback(error instanceof Error ? error.message : 'Unable to load board data.');
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <ScreenShell
      eyebrow="Board setup"
      title="Board-ready state"
      subtitle="Expo Go stops at scan, API calls, and anchor metadata. AR rendering and Cloud Anchor placement remain TODO work for a later native-ready phase.">
      <View style={styles.summaryCard}>
        <Text style={styles.sectionLabel}>Resolved room_id</Text>
        <Text style={styles.roomValue}>{roomId ?? 'No room selected'}</Text>
        <Text style={styles.helperText}>
          {roomId
            ? 'This screen fetches anchor metadata from the backend without touching ARCore or native anchor APIs.'
            : 'Open Scan Room Marker first, confirm a QR code, then return here.'}
        </Text>
      </View>

      <View style={styles.metricGrid}>
        <View style={styles.metricCard}>
          <Text style={styles.sectionLabel}>Anchors</Text>
          <Text style={styles.metricValue}>{anchors.length}</Text>
          <Text style={styles.helperText}>GET /v1/rooms/{'{room_id}'}/anchors</Text>
        </View>
        <View style={styles.metricCard}>
          <Text style={styles.sectionLabel}>Board FEN</Text>
          <Text style={styles.metricValue}>{board ? 'Loaded' : 'Optional'}</Text>
          <Text style={styles.helperText}>
            {SEED_BOARD_ID ? `Seed board ${SEED_BOARD_ID}` : 'Set EXPO_PUBLIC_SEED_BOARD_ID to fetch one.'}
          </Text>
        </View>
      </View>

      <View style={styles.anchorList}>
        {anchors.length > 0 ? (
          anchors.map((anchor) => (
            <View key={anchor.id} style={styles.anchorCard}>
              <Text style={styles.anchorId}>{anchor.cloud_anchor_id}</Text>
              <Text style={styles.anchorMeta}>
                {anchor.active ? 'Active anchor' : 'Inactive anchor'} • pos({anchor.pose.pos.x},{' '}
                {anchor.pose.pos.y}, {anchor.pose.pos.z})
              </Text>
            </View>
          ))
        ) : (
          <View style={styles.todoCard}>
            <Text style={styles.todoTitle}>AR TODO</Text>
            <Text style={styles.todoBody}>
              Spatial visualization is intentionally stubbed in Expo Go. This screen exists only to
              verify room resolution, anchor retrieval, and optional board fetches.
            </Text>
          </View>
        )}
      </View>

      {board ? (
        <View style={styles.fenCard}>
          <Text style={styles.sectionLabel}>Seed board</Text>
          <Text style={styles.fenValue}>{board.fen}</Text>
          <Text style={styles.helperText}>Version {board.version}</Text>
        </View>
      ) : null}

      <ActionButton
        label={isLoading ? 'Refreshing...' : 'Refresh Board Data'}
        caption="Re-fetch anchors and the optional seed board from the backend."
        onPress={() => {
          void refreshBoard();
        }}
        disabled={isLoading}
      />

      <View style={styles.feedbackCard}>
        <Text style={styles.sectionLabel}>Status</Text>
        <Text style={styles.feedbackText}>{feedback}</Text>
      </View>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  summaryCard: {
    borderRadius: 28,
    backgroundColor: '#153248',
    padding: 22,
    gap: 8,
  },
  sectionLabel: {
    color: '#7b6e61',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.1,
    textTransform: 'uppercase',
  },
  roomValue: {
    color: '#f8f4ed',
    fontSize: 24,
    fontWeight: '700',
  },
  helperText: {
    color: '#6b6258',
    fontSize: 14,
    lineHeight: 21,
  },
  metricGrid: {
    flexDirection: 'row',
    gap: 14,
  },
  metricCard: {
    flex: 1,
    borderRadius: 24,
    backgroundColor: '#fffaf2',
    padding: 18,
    gap: 8,
    borderWidth: 1,
    borderColor: '#eadfce',
  },
  metricValue: {
    color: '#1d1b18',
    fontSize: 26,
    fontWeight: '700',
  },
  anchorList: {
    gap: 12,
  },
  anchorCard: {
    borderRadius: 20,
    backgroundColor: '#edf4f8',
    padding: 18,
    gap: 6,
  },
  anchorId: {
    color: '#173146',
    fontSize: 16,
    fontWeight: '700',
  },
  anchorMeta: {
    color: '#395163',
    fontSize: 14,
    lineHeight: 20,
  },
  todoCard: {
    borderRadius: 24,
    backgroundColor: '#f9dcc2',
    padding: 20,
    gap: 8,
  },
  todoTitle: {
    color: '#6e2f14',
    fontSize: 16,
    fontWeight: '700',
  },
  todoBody: {
    color: '#6e2f14',
    fontSize: 15,
    lineHeight: 22,
  },
  fenCard: {
    borderRadius: 24,
    backgroundColor: '#fffaf2',
    padding: 20,
    gap: 8,
    borderWidth: 1,
    borderColor: '#eadfce',
  },
  fenValue: {
    color: '#1d1b18',
    fontSize: 16,
    lineHeight: 24,
    fontWeight: '600',
  },
  feedbackCard: {
    borderRadius: 24,
    backgroundColor: '#ebf3ef',
    padding: 18,
    gap: 8,
  },
  feedbackText: {
    color: '#244034',
    fontSize: 15,
    lineHeight: 22,
  },
});
