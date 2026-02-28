import { API_BASE_URL, API_BASE_URL_HINT } from '@/src/config';

import type {
  BoardState,
  OpenApiDocument,
  RoomAnchorsResponse,
  RoomScanRequest,
  RoomScanResponse,
} from './types';

class ApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
  }
}

async function request<TResponse>(
  path: string,
  init?: RequestInit,
): Promise<TResponse> {
  if (!API_BASE_URL) {
    throw new ApiError(`API base URL is not configured. ${API_BASE_URL_HINT}`);
  }

  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...init,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...init?.headers,
    },
  });

  const contentType = response.headers.get('content-type') ?? '';
  const isJson = contentType.includes('application/json');
  const payload = isJson ? await response.json() : await response.text();

  if (!response.ok) {
    const detail =
      typeof payload === 'object' && payload && 'detail' in payload
        ? String(payload.detail)
        : typeof payload === 'string'
          ? payload
          : `Request failed with status ${response.status}.`;

    throw new ApiError(detail, response.status);
  }

  return payload as TResponse;
}

export const apiClient = {
  pingServer() {
    return request<OpenApiDocument>('/openapi.json', {
      method: 'GET',
    });
  },
  scanRoom(markerId: string) {
    const body: RoomScanRequest = { marker_id: markerId };
    return request<RoomScanResponse>('/v1/rooms/scan', {
      method: 'POST',
      body: JSON.stringify(body),
    });
  },
  getRoomAnchors(roomId: string) {
    return request<RoomAnchorsResponse>(`/v1/rooms/${roomId}/anchors`, {
      method: 'GET',
    });
  },
  getBoard(boardId: string) {
    return request<BoardState>(`/v1/boards/${boardId}`, {
      method: 'GET',
    });
  },
};
