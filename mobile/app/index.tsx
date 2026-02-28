import { router } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ChessboardBackground } from '@/src/components/chessboard-background';
import { PrimaryButton } from '@/src/components/primary-button';

export default function LandingScreen() {
  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <ChessboardBackground />
        <View style={styles.overlay} />
        <View style={styles.glow} />

        <View style={styles.content}>
          <View style={styles.copyBlock}>
            <Text style={styles.eyebrow}>Expo Go • iPhone first</Text>
            <Text style={styles.title}>AR Chess</Text>
            <Text style={styles.subtitle}>Place boards in rooms • Play together</Text>
          </View>

          <View style={styles.buttonGroup}>
            <PrimaryButton
              label="Join"
              onPress={() => router.push('/lobby?mode=join')}
              variant="solid"
            />
            <PrimaryButton
              label="Create"
              onPress={() => router.push('/lobby?mode=create')}
              variant="outline"
            />
          </View>

          <View style={styles.footerCard}>
            <Text style={styles.footerText}>
              Server connectivity is optional for now. The AR handoff starts after this flow later.
            </Text>
          </View>
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
    position: 'relative',
    backgroundColor: '#0e1319',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(10, 16, 23, 0.58)',
  },
  glow: {
    position: 'absolute',
    top: 72,
    alignSelf: 'center',
    width: 260,
    height: 260,
    borderRadius: 999,
    backgroundColor: 'rgba(211, 174, 108, 0.16)',
  },
  content: {
    flex: 1,
    justifyContent: 'center',
    paddingHorizontal: 24,
    gap: 28,
  },
  copyBlock: {
    gap: 12,
    alignItems: 'center',
  },
  eyebrow: {
    color: '#d8c8a5',
    fontSize: 12,
    letterSpacing: 2.2,
    textTransform: 'uppercase',
    fontWeight: '700',
  },
  title: {
    color: '#f8f3e7',
    fontSize: 52,
    fontWeight: '800',
    letterSpacing: -1.4,
  },
  subtitle: {
    color: '#d3dae2',
    fontSize: 17,
    lineHeight: 24,
    textAlign: 'center',
    maxWidth: 280,
  },
  buttonGroup: {
    gap: 14,
  },
  footerCard: {
    alignSelf: 'center',
    maxWidth: 320,
    borderRadius: 24,
    paddingHorizontal: 18,
    paddingVertical: 14,
    backgroundColor: 'rgba(248, 243, 231, 0.08)',
    borderWidth: 1,
    borderColor: 'rgba(248, 243, 231, 0.12)',
  },
  footerText: {
    color: '#c7d0d9',
    fontSize: 14,
    lineHeight: 20,
    textAlign: 'center',
  },
});
