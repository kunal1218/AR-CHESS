export type RoomScanRequest = {
  marker_id: string;
};

export type RoomScanResponse = {
  room_id: string;
};

export type PoseVector = {
  x: number;
  y: number;
  z: number;
};

export type RotationQuaternion = {
  x: number;
  y: number;
  z: number;
  w: number;
};

export type AnchorRecord = {
  id: string;
  cloud_anchor_id: string;
  pose: {
    pos: PoseVector;
    rot: RotationQuaternion;
  };
  active: boolean;
};

export type RoomAnchorsResponse = {
  anchors: AnchorRecord[];
};

export type BoardState = {
  board_id: string;
  fen: string;
  version: number;
};

export type OpenApiDocument = {
  openapi: string;
  info?: {
    title?: string;
    version?: string;
  };
  paths?: Record<string, unknown>;
};
