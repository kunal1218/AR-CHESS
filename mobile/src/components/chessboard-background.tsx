import { useWindowDimensions, View } from 'react-native';

export function ChessboardBackground() {
  const { width, height } = useWindowDimensions();
  const boardSize = Math.max(width, height) * 1.35;
  const squareSize = boardSize / 8;

  return (
    <View
      pointerEvents="none"
      style={{
        position: 'absolute',
        width: boardSize,
        height: boardSize,
        top: -height * 0.18,
        left: -(boardSize - width) / 2,
        transform: [{ rotate: '-8deg' }],
      }}>
      {Array.from({ length: 8 }).map((_, row) => (
        <View key={`row-${row}`} style={{ flexDirection: 'row' }}>
          {Array.from({ length: 8 }).map((__, column) => {
            const isLight = (row + column) % 2 === 0;

            return (
              <View
                key={`square-${row}-${column}`}
                style={{
                  width: squareSize,
                  height: squareSize,
                  backgroundColor: isLight ? '#d7b98c' : '#5a3b24',
                }}
              />
            );
          })}
        </View>
      ))}
    </View>
  );
}
