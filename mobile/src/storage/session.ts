import AsyncStorage from '@react-native-async-storage/async-storage';

const STORAGE_KEY = 'ar-chess/session';

export type StoredRoomSession = {
  markerId: string;
  roomId: string;
  updatedAt: string;
};

export async function getStoredSession(): Promise<StoredRoomSession | null> {
  const rawValue = await AsyncStorage.getItem(STORAGE_KEY);
  if (!rawValue) {
    return null;
  }

  try {
    return JSON.parse(rawValue) as StoredRoomSession;
  } catch {
    await AsyncStorage.removeItem(STORAGE_KEY);
    return null;
  }
}

export async function saveStoredSession(session: Pick<StoredRoomSession, 'markerId' | 'roomId'>) {
  const nextSession: StoredRoomSession = {
    ...session,
    updatedAt: new Date().toISOString(),
  };

  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(nextSession));
  return nextSession;
}
