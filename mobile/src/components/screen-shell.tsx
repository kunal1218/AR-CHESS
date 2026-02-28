import type { ReactElement, ReactNode } from 'react';
import {
  ScrollView,
  StyleSheet,
  Text,
  type RefreshControlProps,
  type ViewStyle,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

type ScreenShellProps = {
  eyebrow: string;
  title: string;
  subtitle: string;
  children: ReactNode;
  refreshControl?: ReactElement<RefreshControlProps>;
  contentStyle?: ViewStyle;
};

export function ScreenShell({
  eyebrow,
  title,
  subtitle,
  children,
  refreshControl,
  contentStyle,
}: ScreenShellProps) {
  return (
    <SafeAreaView edges={['bottom']} style={styles.safeArea}>
      <ScrollView
        contentContainerStyle={[styles.content, contentStyle]}
        refreshControl={refreshControl}
        showsVerticalScrollIndicator={false}>
        <View style={styles.header}>
          <Text style={styles.eyebrow}>{eyebrow}</Text>
          <Text style={styles.title}>{title}</Text>
          <Text style={styles.subtitle}>{subtitle}</Text>
        </View>
        {children}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f4efe6',
  },
  content: {
    paddingHorizontal: 20,
    paddingTop: 18,
    paddingBottom: 32,
    gap: 18,
  },
  header: {
    gap: 10,
  },
  eyebrow: {
    alignSelf: 'flex-start',
    backgroundColor: '#dbe7ef',
    color: '#173146',
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 7,
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.1,
    textTransform: 'uppercase',
  },
  title: {
    color: '#1d1b18',
    fontSize: 36,
    fontWeight: '800',
    letterSpacing: -1.1,
  },
  subtitle: {
    color: '#5c534a',
    fontSize: 16,
    lineHeight: 24,
  },
});
