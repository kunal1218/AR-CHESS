import { Pressable, StyleSheet, Text, View } from 'react-native';

type ActionButtonProps = {
  label: string;
  caption: string;
  onPress: () => void;
  disabled?: boolean;
  variant?: 'primary' | 'secondary';
};

export function ActionButton({
  label,
  caption,
  onPress,
  disabled = false,
  variant = 'primary',
}: ActionButtonProps) {
  const secondary = variant === 'secondary';

  return (
    <Pressable
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        secondary ? styles.buttonSecondary : styles.buttonPrimary,
        disabled ? styles.buttonDisabled : null,
        pressed && !disabled ? styles.buttonPressed : null,
      ]}>
      <View style={styles.copy}>
        <Text style={[styles.label, secondary ? styles.labelSecondary : styles.labelPrimary]}>
          {label}
        </Text>
        <Text style={[styles.caption, secondary ? styles.captionSecondary : styles.captionPrimary]}>
          {caption}
        </Text>
      </View>
      <Text style={[styles.arrow, secondary ? styles.labelSecondary : styles.labelPrimary]}>→</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    minHeight: 88,
    borderRadius: 24,
    paddingHorizontal: 20,
    paddingVertical: 18,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 16,
  },
  buttonPrimary: {
    backgroundColor: '#153248',
  },
  buttonSecondary: {
    backgroundColor: '#fffaf2',
    borderWidth: 1,
    borderColor: '#ddd1c3',
  },
  buttonDisabled: {
    opacity: 0.55,
  },
  buttonPressed: {
    transform: [{ scale: 0.99 }],
  },
  copy: {
    flex: 1,
    gap: 5,
  },
  label: {
    fontSize: 18,
    fontWeight: '700',
  },
  labelPrimary: {
    color: '#f8f4ed',
  },
  labelSecondary: {
    color: '#153248',
  },
  caption: {
    fontSize: 14,
    lineHeight: 20,
  },
  captionPrimary: {
    color: '#c8dff0',
  },
  captionSecondary: {
    color: '#6a5d52',
  },
  arrow: {
    fontSize: 22,
    fontWeight: '700',
  },
});
