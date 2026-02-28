import { router, useLocalSearchParams } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ChessboardBackground } from '@/src/components/chessboard-background';
import { PrimaryButton } from '@/src/components/primary-button';

function formatMode(mode?: string | string[]) {
  const rawMode = Array.isArray(mode) ? mode[0] : mode;

  if (rawMode === 'create') {
    return 'Create';
  }

  return 'Join';
}

export default function LobbyScreen() {
  const { mode } = useLocalSearchParams<{ mode?: string }>();
  const selectedMode = formatMode(mode);

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <ChessboardBackground />
        <View style={styles.overlay} />

        <View style={styles.card}>
          <Text style={styles.label}>{selectedMode} selected</Text>
          <Text style={styles.title}>Lobby / Loading</Text>
          <Text style={styles.todo}>AR experience opens next (TODO)</Text>
          <Text style={styles.helper}>
            This screen is intentionally server-optional. It keeps the Join/Create flow ready while
            AR and networking are added later.
          </Text>

          <PrimaryButton label="Back" onPress={() => router.replace('/')} variant="solid" />
        </View>
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
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(8, 12, 18, 0.66)',
  },
  card: {
    borderRadius: 30,
    paddingHorizontal: 24,
    paddingVertical: 28,
    backgroundColor: 'rgba(17, 25, 34, 0.84)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.12)',
    gap: 14,
  },
  label: {
    color: '#d8c8a5',
    fontSize: 12,
    letterSpacing: 2,
    textTransform: 'uppercase',
    fontWeight: '700',
  },
  title: {
    color: '#f8f3e7',
    fontSize: 34,
    fontWeight: '800',
    letterSpacing: -0.8,
  },
  todo: {
    color: '#ffffff',
    fontSize: 20,
    fontWeight: '700',
    lineHeight: 28,
  },
  helper: {
    color: '#cdd5dd',
    fontSize: 15,
    lineHeight: 22,
    marginBottom: 8,
  },
});
