import { CameraView, type BarcodeScanningResult, useCameraPermissions } from 'expo-camera';
import { router } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { apiClient } from '@/src/api/client';
import { ActionButton } from '@/src/components/action-button';
import { ScreenShell } from '@/src/components/screen-shell';
import { saveStoredSession } from '@/src/storage/session';

export default function ScanScreen() {
  const [permission, requestPermission] = useCameraPermissions();
  const [markerId, setMarkerId] = useState('');
  const [isLocked, setIsLocked] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [feedback, setFeedback] = useState<string>('Point the camera at a QR marker to capture marker_id.');

  function handleBarcodeScanned(result: BarcodeScanningResult) {
    if (isLocked) {
      return;
    }

    const nextMarkerId = result.data.trim();
    if (!nextMarkerId) {
      return;
    }

    setMarkerId(nextMarkerId);
    setIsLocked(true);
    setFeedback(`Captured marker ${nextMarkerId}. Confirm to resolve the room id.`);
  }

  async function handleConfirm() {
    if (!markerId) {
      return;
    }

    setIsSubmitting(true);
    try {
      const response = await apiClient.scanRoom(markerId);
      await saveStoredSession({
        markerId,
        roomId: response.room_id,
      });
      router.replace({
        pathname: '/board',
        params: { roomId: response.room_id },
      });
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : 'Unable to resolve the scanned marker.');
    } finally {
      setIsSubmitting(false);
    }
  }

  function handleRescan() {
    setMarkerId('');
    setIsLocked(false);
    setFeedback('Camera unlocked. Scan the next QR marker when ready.');
  }

  return (
    <ScreenShell
      eyebrow="Room scan"
      title="Scan a room marker"
      subtitle="QR scanning is wired for Expo Go. AprilTag recognition and AR placement remain TODO items for the future native AR phase.">
      <View style={styles.cameraFrame}>
        {permission?.granted ? (
          <CameraView
            style={styles.camera}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
            onBarcodeScanned={isLocked ? undefined : handleBarcodeScanned}
          />
        ) : (
          <View style={styles.permissionState}>
            <Text style={styles.permissionTitle}>Camera permission required</Text>
            <Text style={styles.permissionBody}>
              Expo Go needs camera access on your iPhone before it can read room markers.
            </Text>
            <ActionButton
              label="Grant Camera Access"
              caption="Requests the standard iOS camera permission."
              onPress={() => {
                void requestPermission();
              }}
            />
          </View>
        )}
      </View>

      <View style={styles.scanCard}>
        <Text style={styles.sectionLabel}>Scanned marker_id</Text>
        <TextInput
          value={markerId}
          onChangeText={(nextValue) => {
            setMarkerId(nextValue);
            setIsLocked(Boolean(nextValue));
          }}
          autoCapitalize="characters"
          autoCorrect={false}
          placeholder="ROOK-ROOM-001"
          placeholderTextColor="#9b9185"
          style={styles.input}
        />
        <Text style={styles.feedback}>{feedback}</Text>
      </View>

      <View style={styles.actions}>
        <ActionButton
          label={isSubmitting ? 'Resolving Room...' : 'Confirm'}
          caption="POST the marker to /v1/rooms/scan and store the returned room id."
          onPress={handleConfirm}
          disabled={!markerId || isSubmitting}
        />
        <ActionButton
          label="Scan Again"
          caption="Unlock the camera and clear the current marker selection."
          onPress={handleRescan}
          variant="secondary"
        />
      </View>

      <Pressable onPress={handleRescan} style={styles.quickReset}>
        <Text style={styles.quickResetText}>Clear marker and unlock camera</Text>
      </Pressable>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  cameraFrame: {
    overflow: 'hidden',
    borderRadius: 30,
    minHeight: 340,
    backgroundColor: '#153248',
  },
  camera: {
    flex: 1,
    minHeight: 340,
  },
  permissionState: {
    padding: 24,
    gap: 12,
    justifyContent: 'center',
    minHeight: 340,
  },
  permissionTitle: {
    color: '#f8f4ed',
    fontSize: 22,
    fontWeight: '700',
  },
  permissionBody: {
    color: '#d3e4f4',
    fontSize: 15,
    lineHeight: 22,
  },
  scanCard: {
    borderRadius: 24,
    backgroundColor: '#fffaf2',
    padding: 20,
    gap: 10,
    borderWidth: 1,
    borderColor: '#eadfce',
  },
  sectionLabel: {
    color: '#7b6e61',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.1,
    textTransform: 'uppercase',
  },
  input: {
    borderRadius: 18,
    borderWidth: 1,
    borderColor: '#d6c9b9',
    backgroundColor: '#f9f4ec',
    paddingHorizontal: 16,
    paddingVertical: 14,
    color: '#1d1b18',
    fontSize: 16,
    fontWeight: '600',
  },
  feedback: {
    color: '#62594f',
    fontSize: 15,
    lineHeight: 22,
  },
  actions: {
    gap: 14,
  },
  quickReset: {
    alignSelf: 'center',
    paddingVertical: 8,
  },
  quickResetText: {
    color: '#6a5d52',
    fontSize: 14,
    fontWeight: '600',
  },
});
