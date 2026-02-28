import Constants from 'expo-constants';

type AppEnv = 'development' | 'production';

type ExpoExtra = {
  apiBaseUrl?: string;
  appEnv?: string;
  seedBoardId?: string;
};

function normalizeValue(value?: string | null): string {
  return value?.trim().replace(/\/+$/, '') ?? '';
}

function extractHost(candidate?: string | null): string {
  if (!candidate) {
    return '';
  }

  const withoutProtocol = candidate.replace(/^https?:\/\//, '');
  const withoutPath = withoutProtocol.split('/')[0] ?? '';
  return withoutPath.split(':')[0] ?? '';
}

function inferLanBaseUrl() {
  const expoHost = extractHost(Constants.expoConfig?.hostUri);
  const expoGoHost = extractHost(Constants.expoGoConfig?.debuggerHost);
  const host = expoHost || expoGoHost;

  return host ? `http://${host}:8000` : '';
}

const extra = (Constants.expoConfig?.extra ?? {}) as ExpoExtra;
const configuredBaseUrl = normalizeValue(
  process.env.EXPO_PUBLIC_API_BASE_URL ?? extra.apiBaseUrl ?? inferLanBaseUrl()
);

export const API_BASE_URL = configuredBaseUrl;
export const APP_ENV: AppEnv =
  (process.env.EXPO_PUBLIC_APP_ENV ?? extra.appEnv) === 'production'
    ? 'production'
    : 'development';
export const SEED_BOARD_ID = normalizeValue(process.env.EXPO_PUBLIC_SEED_BOARD_ID ?? extra.seedBoardId);
export const SHOULD_WARN_LOCALHOST = /localhost|127\.0\.0\.1/.test(API_BASE_URL);
export const API_BASE_URL_HINT =
  'Set EXPO_PUBLIC_API_BASE_URL to your Mac LAN IP, for example http://192.168.1.20:8000, then restart Expo so your iPhone can reach the server over Wi-Fi.';
