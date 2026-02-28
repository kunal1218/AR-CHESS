import * as React from 'react';

export type Pose = {
  pos: { x: number; y: number; z: number };
  rot: { x: number; y: number; z: number; w: number };
};

export type AnchorRecord = {
  id: string;
  cloud_anchor_id: string;
  pose: Pose;
  active: boolean;
};

export type ApiClient = {
  scanRoom(markerId: string): Promise<{ room_id: string }>;
  getAnchors(roomId: string): Promise<{ anchors: AnchorRecord[] }>;
  getBoard(boardId: string): Promise<{ board_id: string; fen: string; version: number }>;
  postMove(
    boardId: string,
    uci: string,
    expectedVersion: number
  ): Promise<{ fen: string; version: number; legal: boolean; reason?: string }>;
};

export type EvalResult = {
  source: string;
  centipawns: number;
  mateIn: number | null;
  pv: string[];
};

export type Evaluator = {
  name: string;
  evaluate(fen: string): Promise<EvalResult>;
};

export type GameSnapshot = {
  boardId: string;
  roomId: string | null;
  fen: string;
  version: number;
  selectedSquare: string | null;
  legalMovesFromSelection: string[];
  anchorIds: string[];
  placementMode: 'resolving' | 'manual' | 'anchored';
  evaluation: EvalResult | null;
  activeColor: 'w' | 'b';
  inCheck: boolean;
};

export type GameEvent = {
  id: number;
  type: string;
  timestamp: string;
  payload: Record<string, unknown>;
};

export type GameCommand =
  | { type: 'bootstrap'; markerId?: string; boardId?: string }
  | { type: 'selectSquare'; square: string | null }
  | { type: 'move'; uci: string }
  | { type: 'syncRemoteMove'; fen: string; version: number }
  | { type: 'setAnchors'; cloudAnchorIds: string[] }
  | { type: 'anchorHosted'; cloudAnchorId: string };

export type GameRuntime = {
  getSnapshot(): GameSnapshot;
  subscribe(listener: (event: GameEvent, snapshot: GameSnapshot) => void): () => void;
  dispatch(command: GameCommand): Promise<{ ok: boolean; reason?: string }>;
};

export function createGameRuntime(options?: {
  api?: ApiClient;
  evaluator?: Evaluator;
  boardId?: string;
  initialFen?: string;
}): GameRuntime;

export function createStubApi(): ApiClient & {
  seedBoard(boardId: string, fen?: string, version?: number): void;
  seedAnchors(roomId: string, anchors: AnchorRecord[]): void;
};

export function createStockfishStubEvaluator(): Evaluator;
export function createCustomEvaluator(evaluate: (fen: string) => Promise<EvalResult>): Evaluator;

export function isLegalMove(fen: string, uci: string): boolean;
export function generateLegalMoves(fen: string, square?: string | null): string[];
export function isInCheck(fen: string, color?: 'w' | 'b' | null): boolean;
export function parseFen(fen: string): unknown;
export function serializeFen(state: unknown): string;
export function parseFenState(fen: string): { activeColor: 'w' | 'b'; board: Array<unknown> };
export function applyLegalMove(
  fen: string,
  uci: string
): { legal: true; fen: string; uci: string } | { legal: false; fen: string; reason: string };

export function resolveCloudAnchors(
  cloudAnchorIds: string[],
  resolver?: (cloudAnchorId: string) => Promise<{ cloud_anchor_id: string; pose: Pose } | null>
): Promise<{ cloud_anchor_id: string; pose: Pose } | null>;

export function submitHostedAnchor(
  cloud_anchor_id: string,
  pose: Pose
): Promise<{
  accepted: true;
  cloud_anchor_id: string;
  pose: Pose;
  submitted_at: string;
  notes: string;
}>;

export type ARChessboardProps = {
  initialFen?: string;
  fen?: string;
  onMove?: (uci: string) => void;
  cloudAnchorIds?: string[];
  onFenChange?: (fen: string, uci: string) => void;
  onAnchorHosted?: (hosted: {
    cloud_anchor_id: string;
    pose: Pose;
    accepted: true;
    submitted_at: string;
    notes: string;
  }) => void;
  anchorResolver?: (cloudAnchorId: string) => Promise<{ cloud_anchor_id: string; pose: Pose } | null>;
  submitHostedAnchorFn?: (
    cloud_anchor_id: string,
    pose: Pose
  ) => Promise<{
    accepted: true;
    cloud_anchor_id: string;
    pose: Pose;
    submitted_at: string;
    notes: string;
  }>;
};

export const ARChessboard: React.ComponentType<ARChessboardProps>;
