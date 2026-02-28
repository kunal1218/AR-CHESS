import type { ConfigContext, ExpoConfig } from 'expo/config';

const API_BASE_URL = process.env.EXPO_PUBLIC_API_BASE_URL ?? '';

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'AR Chess',
  slug: 'ar-chess-mobile',
  version: '0.1.0',
  orientation: 'portrait',
  icon: './assets/images/icon.png',
  scheme: 'archess',
  userInterfaceStyle: 'light',
  newArchEnabled: true,
  ios: {
    supportsTablet: false,
    bundleIdentifier: 'com.example.archess',
  },
  web: {
    output: 'static',
    favicon: './assets/images/favicon.png',
  },
  plugins: [
    'expo-router',
    [
      'expo-camera',
      {
        cameraPermission: 'Allow AR Chess to use your camera for board placement and gameplay.',
      },
    ],
    [
      'expo-splash-screen',
      {
        image: './assets/images/splash-icon.png',
        imageWidth: 200,
        resizeMode: 'contain',
        backgroundColor: '#f4efe6',
      },
    ],
  ],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
  extra: {
    apiBaseUrl: API_BASE_URL,
  },
});
