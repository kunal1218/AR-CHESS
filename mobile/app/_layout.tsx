import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <StatusBar style="dark" />
      <Stack>
        <Stack.Screen
          name="index"
          options={{
            title: 'AR Chess',
            headerShadowVisible: false,
            headerStyle: { backgroundColor: '#f4efe6' },
            headerTitleStyle: { color: '#153248', fontSize: 20, fontWeight: '700' },
            contentStyle: { backgroundColor: '#f4efe6' },
          }}
        />
        <Stack.Screen
          name="scan"
          options={{
            title: 'Scan Room Marker',
            headerShadowVisible: false,
            headerStyle: { backgroundColor: '#f4efe6' },
            headerTitleStyle: { color: '#153248', fontSize: 18, fontWeight: '600' },
            headerTintColor: '#153248',
            contentStyle: { backgroundColor: '#f4efe6' },
          }}
        />
        <Stack.Screen
          name="board"
          options={{
            title: 'Board',
            headerShadowVisible: false,
            headerStyle: { backgroundColor: '#f4efe6' },
            headerTitleStyle: { color: '#153248', fontSize: 18, fontWeight: '600' },
            headerTintColor: '#153248',
            contentStyle: { backgroundColor: '#f4efe6' },
          }}
        />
      </Stack>
    </SafeAreaProvider>
  );
}
