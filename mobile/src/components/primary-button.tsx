import { Pressable, StyleSheet, Text } from 'react-native';

type PrimaryButtonProps = {
  label: string;
  onPress: () => void;
  variant?: 'solid' | 'outline' | 'ghost';
};

export function PrimaryButton({
  label,
  onPress,
  variant = 'solid',
}: PrimaryButtonProps) {
  const outlined = variant === 'outline';
  const ghost = variant === 'ghost';

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        ghost ? styles.ghostButton : outlined ? styles.outlineButton : styles.solidButton,
        pressed ? styles.pressed : null,
      ]}>
      <Text
        style={[
          styles.label,
          ghost ? styles.ghostLabel : outlined ? styles.outlineLabel : styles.solidLabel,
        ]}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    minHeight: 58,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#000000',
    shadowOpacity: 0.22,
    shadowRadius: 16,
    shadowOffset: { width: 0, height: 10 },
    elevation: 4,
  },
  solidButton: {
    backgroundColor: '#f3e4be',
  },
  outlineButton: {
    backgroundColor: 'rgba(243, 228, 190, 0.1)',
    borderWidth: 1,
    borderColor: 'rgba(243, 228, 190, 0.6)',
  },
  ghostButton: {
    backgroundColor: 'rgba(255, 255, 255, 0.04)',
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.08)',
  },
  pressed: {
    opacity: 0.84,
  },
  label: {
    fontSize: 18,
    fontWeight: '700',
    letterSpacing: 0.2,
  },
  solidLabel: {
    color: '#1d1d1d',
  },
  outlineLabel: {
    color: '#f8f3e7',
  },
  ghostLabel: {
    color: '#d7e0e8',
  },
});
