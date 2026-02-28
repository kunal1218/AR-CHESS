import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <Stack>
        <Stack.Screen
          name="index"
          options={{
            headerShown: false,
            contentStyle: { backgroundColor: '#0e1319' },
          }}
        />
        <Stack.Screen
          name="lobby"
          options={{
            headerShown: false,
            headerShadowVisible: false,
            contentStyle: { backgroundColor: '#0e1319' },
          }}
        />
      </Stack>
    </SafeAreaProvider>
  );
}
