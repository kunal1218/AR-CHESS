import { useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { applyLegalMove, generateLegalMoves, parseFenState } from '../core/index.js';
import { resolveCloudAnchors, submitHostedAnchor } from './anchors.js';

const STARTING_FEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const FILES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

const PIECE_LABELS = {
  wp: 'WP',
  wn: 'WN',
  wb: 'WB',
  wr: 'WR',
  wq: 'WQ',
  wk: 'WK',
  bp: 'BP',
  bn: 'BN',
  bb: 'BB',
  br: 'BR',
  bq: 'BQ',
  bk: 'BK',
};

function getSquareName(file, rank) {
  return `${FILES[file]}${rank + 1}`;
}

function pickPreferredMove(moves, destinationSquare) {
  const destinationMoves = moves.filter((uci) => uci.slice(2, 4) === destinationSquare);
  if (destinationMoves.length === 0) {
    return null;
  }

  const queenPromotion = destinationMoves.find((uci) => uci.endsWith('q'));
  return queenPromotion ?? destinationMoves[0];
}

export function ARChessboard({
  initialFen = STARTING_FEN,
  fen: controlledFen,
  onMove,
  cloudAnchorIds = [],
  onFenChange,
  onAnchorHosted,
  anchorResolver,
  submitHostedAnchorFn = submitHostedAnchor,
}) {
  const [internalFen, setInternalFen] = useState(initialFen);
  const [selectedSquare, setSelectedSquare] = useState(null);
  const [legalTargets, setLegalTargets] = useState([]);
  const [placementMode, setPlacementMode] = useState('resolving');
  const [anchorState, setAnchorState] = useState(null);
  const [status, setStatus] = useState('Resolving cloud anchors...');
  const fen = controlledFen ?? internalFen;

  useEffect(() => {
    setInternalFen(initialFen);
    setSelectedSquare(null);
    setLegalTargets([]);
  }, [initialFen]);

  useEffect(() => {
    let isCancelled = false;

    async function resolveAnchors() {
      if (!cloudAnchorIds.length) {
        setPlacementMode('manual');
        setStatus('No cloud anchors provided. Place board manually and host a new anchor.');
        return;
      }

      setPlacementMode('resolving');
      setStatus(`Resolving ${cloudAnchorIds.length} cloud anchor candidate(s)...`);
      const resolved = await resolveCloudAnchors(cloudAnchorIds, anchorResolver);

      if (isCancelled) {
        return;
      }

      if (resolved) {
        setAnchorState(resolved);
        setPlacementMode('anchored');
        setStatus(`Placed board using cloud anchor ${resolved.cloud_anchor_id}.`);
      } else {
        setPlacementMode('manual');
        setStatus('Cloud anchor resolve failed. Use manual placement and host a new anchor.');
      }
    }

    void resolveAnchors();
    return () => {
      isCancelled = true;
    };
  }, [anchorResolver, cloudAnchorIds]);

  const parsed = useMemo(() => parseFenState(fen), [fen]);
  const legalTargetSet = useMemo(() => new Set(legalTargets), [legalTargets]);

  async function handleManualPlacement() {
    const pose = {
      pos: { x: 0, y: 0, z: -1 },
      rot: { x: 0, y: 0, z: 0, w: 1 },
    };
    const hostedAnchorId = `hosted-${Date.now()}`;
    const hosted = await submitHostedAnchorFn(hostedAnchorId, pose);
    setAnchorState({ cloud_anchor_id: hosted.cloud_anchor_id, pose: hosted.pose });
    setPlacementMode('anchored');
    setStatus(`Manual placement active. Hosted anchor ${hosted.cloud_anchor_id}.`);
    onAnchorHosted?.(hosted);
  }

  function handleSquarePress(square) {
    if (placementMode !== 'anchored') {
      return;
    }

    if (selectedSquare) {
      if (selectedSquare === square) {
        setSelectedSquare(null);
        setLegalTargets([]);
        return;
      }

      const candidateMoves = generateLegalMoves(fen, selectedSquare);
      const chosenMove = pickPreferredMove(candidateMoves, square);
      if (chosenMove) {
        if (onMove) {
          onMove(chosenMove);
          setStatus(`Move requested: ${chosenMove}`);
          setSelectedSquare(null);
          setLegalTargets([]);
          return;
        }

        const result = applyLegalMove(fen, chosenMove);
        if (result.legal) {
          setInternalFen(result.fen);
          onFenChange?.(result.fen, result.uci);
          setStatus(`Move played: ${result.uci}`);
        } else {
          setStatus(result.reason ?? 'Illegal move.');
        }
        setSelectedSquare(null);
        setLegalTargets([]);
        return;
      }
    }

    const movesFromSquare = generateLegalMoves(fen, square);
    if (movesFromSquare.length > 0) {
      setSelectedSquare(square);
      setLegalTargets(Array.from(new Set(movesFromSquare.map((uci) => uci.slice(2, 4)))));
    } else {
      setSelectedSquare(null);
      setLegalTargets([]);
    }
  }

  const boardTranslation = anchorState
    ? {
        transform: [
          { translateX: anchorState.pose.pos.x * 140 },
          { translateY: -anchorState.pose.pos.z * 120 },
        ],
      }
    : undefined;

  return (
    <View style={styles.container}>
      <View style={styles.statusCard}>
        <Text style={styles.statusHeading}>Anchor State</Text>
        <Text style={styles.statusText}>{status}</Text>
        <Text style={styles.statusMeta}>
          {anchorState
            ? `Anchor: ${anchorState.cloud_anchor_id}`
            : 'No active anchor. Waiting for resolve or manual placement.'}
        </Text>
      </View>

      {placementMode !== 'anchored' ? (
        <Pressable onPress={() => void handleManualPlacement()} style={styles.manualButton}>
          <Text style={styles.manualButtonText}>Place Board Manually + Host Anchor</Text>
        </Pressable>
      ) : null}

      <View style={styles.scene}>
        <View style={[styles.board, boardTranslation, placementMode !== 'anchored' ? styles.boardDisabled : null]}>
          {Array.from({ length: 8 }, (_, visualRank) => 7 - visualRank).map((rank) => (
            <View key={`rank-${rank}`} style={styles.row}>
              {Array.from({ length: 8 }, (_, file) => {
                const square = getSquareName(file, rank);
                const index = rank * 8 + file;
                const piece = parsed.board[index];
                const pieceLabel = piece ? PIECE_LABELS[`${piece.color}${piece.type}`] : '';
                const isSelected = selectedSquare === square;
                const isLegalTarget = legalTargetSet.has(square);
                const isDark = (file + rank) % 2 === 1;

                return (
                  <Pressable
                    key={square}
                    onPress={() => handleSquarePress(square)}
                    style={[
                      styles.square,
                      isDark ? styles.darkSquare : styles.lightSquare,
                      isSelected ? styles.selectedSquare : null,
                      isLegalTarget ? styles.legalSquare : null,
                    ]}>
                    <Text style={styles.piece}>{pieceLabel}</Text>
                    <Text style={styles.squareLabel}>{square}</Text>
                  </Pressable>
                );
              })}
            </View>
          ))}
        </View>
      </View>

      <View style={styles.infoCard}>
        <Text style={styles.turnLabel}>Turn: {parsed.activeColor === 'w' ? 'White' : 'Black'}</Text>
        <Text style={styles.fenLabel}>FEN</Text>
        <Text style={styles.fenValue}>{fen}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 14,
  },
  statusCard: {
    borderRadius: 18,
    padding: 14,
    backgroundColor: '#f5f0e7',
    borderWidth: 1,
    borderColor: '#dccfbf',
    gap: 4,
  },
  statusHeading: {
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    color: '#65594c',
    letterSpacing: 1,
  },
  statusText: {
    fontSize: 14,
    color: '#2e2924',
    lineHeight: 20,
  },
  statusMeta: {
    fontSize: 12,
    color: '#6f655a',
  },
  manualButton: {
    borderRadius: 16,
    paddingVertical: 12,
    paddingHorizontal: 14,
    backgroundColor: '#1c3f52',
  },
  manualButtonText: {
    color: '#f6f3ee',
    fontSize: 14,
    fontWeight: '700',
    textAlign: 'center',
  },
  scene: {
    borderRadius: 20,
    minHeight: 380,
    padding: 16,
    backgroundColor: '#dae8ee',
    borderWidth: 1,
    borderColor: '#b8d0da',
    justifyContent: 'center',
    alignItems: 'center',
  },
  board: {
    width: 320,
    height: 320,
    borderRadius: 14,
    borderWidth: 2,
    borderColor: '#2b3f4a',
    overflow: 'hidden',
  },
  boardDisabled: {
    opacity: 0.45,
  },
  row: {
    flexDirection: 'row',
    flex: 1,
  },
  square: {
    flex: 1,
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 4,
  },
  lightSquare: {
    backgroundColor: '#f3ebda',
  },
  darkSquare: {
    backgroundColor: '#b68e5f',
  },
  selectedSquare: {
    borderWidth: 2,
    borderColor: '#1b5a80',
  },
  legalSquare: {
    backgroundColor: '#8dc4dd',
  },
  piece: {
    marginTop: 8,
    fontSize: 14,
    fontWeight: '700',
    color: '#111',
  },
  squareLabel: {
    fontSize: 9,
    marginBottom: 4,
    color: '#2f2b27',
  },
  infoCard: {
    borderRadius: 18,
    padding: 14,
    backgroundColor: '#edf3e6',
    borderWidth: 1,
    borderColor: '#d4e1c6',
    gap: 6,
  },
  turnLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#294129',
  },
  fenLabel: {
    fontSize: 11,
    fontWeight: '700',
    textTransform: 'uppercase',
    color: '#52654f',
    letterSpacing: 1,
  },
  fenValue: {
    fontSize: 12,
    lineHeight: 18,
    color: '#294129',
  },
});
