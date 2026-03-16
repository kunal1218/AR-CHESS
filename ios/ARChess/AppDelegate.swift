import AVFoundation
import ARKit
import CoreMotion
import CryptoKit
import Foundation
import ImageIO
import OSLog
import RealityKit
import Speech
import SwiftUI
import UIKit
import WebKit
import simd

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UIHostingController(rootView: ARChessRootView())
    self.window = window
    window.makeKeyAndVisible()
    return true
  }
}

private struct GIFAnimationSequence {
  let frames: [UIImage]
  let duration: TimeInterval

  static func loadFromBundle(named name: String, withExtension ext: String) -> GIFAnimationSequence? {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }

    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else {
      return nil
    }

    var frames: [UIImage] = []
    var totalDuration: TimeInterval = 0

    for index in 0..<frameCount {
      guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
        continue
      }

      let duration = frameDuration(for: source, index: index)
      let repeats = max(1, Int(round(duration / 0.04)))
      let image = UIImage(cgImage: cgImage)
      frames.append(contentsOf: Array(repeating: image, count: repeats))
      totalDuration += duration
    }

    guard !frames.isEmpty else {
      return nil
    }

    return GIFAnimationSequence(frames: frames, duration: max(totalDuration, 0.4))
  }

  private static func frameDuration(for source: CGImageSource, index: Int) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
      return 0.08
    }

    let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
    let duration = unclamped ?? clamped ?? 0.08
    return duration < 0.02 ? 0.08 : duration
  }
}

private enum PlayerMode: String, Hashable {
  case join
  case create

  var title: String {
    rawValue.capitalized
  }

  var heading: String {
    switch self {
    case .join:
      return "Join selected"
    case .create:
      return "Create selected"
    }
  }

  var lobbySummary: String {
    switch self {
    case .join:
      return "Join an existing room and align your device with the shared board space."
    case .create:
      return "Create a fresh room, host the board, and prepare the native AR scene."
    }
  }
}

private enum PlayModeChoice: Hashable {
  case course
  case passAndPlay
  case queueMatch
  case playVsStockfish

  var title: String {
    switch self {
    case .course:
      return "Course"
    case .passAndPlay:
      return "Pass & Play"
    case .queueMatch:
      return "Queue Match"
    case .playVsStockfish:
      return "Play vs Stockfish"
    }
  }
}

private enum NarratorType: String, CaseIterable, Identifiable {
  case silky
  case fletcher

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .silky:
      return "Silky Voice"
    case .fletcher:
      return "Fletcher"
    }
  }

  var summary: String {
    switch self {
    case .silky:
      return "Calm, polished, and elegant instructional commentary."
    case .fletcher:
      return "Explosive, brutal, and sarcastic coaching that still teaches."
    }
  }
}

private let geminiNarrationSentenceLimit = 5
private let geminiNarrationCharacterLimit = 320
private let experienceLaunchDelayNanoseconds: UInt64 = 650_000_000
private let experienceStartupRemoteWorkDelayNanoseconds: UInt64 = 850_000_000

private func cappedNarrationText(
  _ text: String,
  maxSentences: Int = geminiNarrationSentenceLimit,
  maxCharacters: Int = geminiNarrationCharacterLimit
) -> (text: String, truncated: Bool) {
  let normalized = text
    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty else {
    return ("", false)
  }

  var capped = normalized
  var truncated = false

  if maxSentences > 0,
     let regex = try? NSRegularExpression(pattern: #"[.!?]+(?:["')\]]+)?(?=\s|$)"#) {
    let range = NSRange(capped.startIndex..., in: capped)
    let matches = regex.matches(in: capped, range: range)
    if matches.count > maxSentences,
       let cutoff = Range(matches[maxSentences - 1].range, in: capped) {
      capped = String(capped[..<cutoff.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      truncated = true
    }
  }

  if capped.count > maxCharacters {
    let index = capped.index(capped.startIndex, offsetBy: maxCharacters)
    var shortened = String(capped[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    if let lastSpace = shortened.lastIndex(of: " ") {
      shortened = String(shortened[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    shortened = shortened.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
    if !shortened.hasSuffix(".") && !shortened.hasSuffix("!") && !shortened.hasSuffix("?") {
      shortened.append("...")
    }
    capped = shortened
    truncated = true
  }

  return (capped, truncated)
}

private let centerFocusHighlightSquares = ["d4", "e4", "d5", "e5"]

private func narrationHighlightSquares(for text: String) -> [String]? {
  let normalized = text
    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  guard !normalized.isEmpty else {
    return nil
  }

  if normalized.contains("board's heart")
    || normalized.contains("crossroads at the board's heart")
    || normalized.contains("the center")
    || normalized.contains("center control")
    || normalized.contains("central tension")
    || normalized.contains("central control")
    || normalized.contains("central space")
    || normalized.contains("central squares")
    || normalized.contains("control the center")
    || normalized.contains("fight for the center")
    || normalized.contains("contest the center")
    || normalized.contains("in the center")
    || normalized.contains("central") {
    return centerFocusHighlightSquares
  }

  return nil
}

private enum StockfishMatchLaunchKind: Hashable {
  case standard
  case devCheck
}

private struct StockfishMatchConfiguration: Hashable {
  let humanColor: ChessColor
  let startingFEN: String?
  let launchKind: StockfishMatchLaunchKind

  var engineColor: ChessColor {
    humanColor.opponent
  }

  var statusSummary: String {
    switch launchKind {
    case .standard:
      return "Coin toss assigned you \(humanColor.displayName)."
    case .devCheck:
      return "devCheck loaded. You are \(humanColor.displayName) because that side is to move in the FEN."
    }
  }

  var modeTitle: String {
    switch launchKind {
    case .standard:
      return "Stockfish Match • You are \(humanColor.displayName)"
    case .devCheck:
      return "Stockfish devCheck • You are \(humanColor.displayName)"
    }
  }

  var supportsPostGameReview: Bool {
    launchKind == .standard
  }

  static func coinToss() -> StockfishMatchConfiguration {
    StockfishMatchConfiguration(
      humanColor: Bool.random() ? .white : .black,
      startingFEN: nil,
      launchKind: .standard
    )
  }

  static func devCheck(fen: String, humanColor: ChessColor) -> StockfishMatchConfiguration {
    StockfishMatchConfiguration(
      humanColor: humanColor,
      startingFEN: fen,
      launchKind: .devCheck
    )
  }
}

private enum ExperienceMode: Hashable {
  case lesson(OpeningLessonDefinition)
  case passAndPlay(PlayerMode)
  case queueMatch
  case playVsStockfish(StockfishMatchConfiguration)

  var loadingTitle: String {
    switch self {
    case .lesson(let lesson):
      return "Loading \(lesson.title)"
    case .passAndPlay(let mode):
      return mode == .create ? "Creating AR Board" : "Joining AR Board"
    case .queueMatch:
      return "Opening Match Arena"
    case .playVsStockfish:
      return "Preparing Stockfish Match"
    }
  }

  var loadingSummary: String {
    switch self {
    case .lesson:
      return "Starting camera, staging the lesson position, and keeping the board load off the first visible frame."
    case .passAndPlay(let mode):
      return mode == .create
        ? "Starting camera, building the board, and giving the scene a moment to settle before you enter."
        : "Starting camera, aligning the scene, and preparing the shared board without dropping the first frame."
    case .queueMatch:
      return "Starting camera, preparing the synchronized board, and deferring network sync until the scene is visible."
    case .playVsStockfish:
      return "Starting camera, building the board, and holding engine startup until the AR scene is stable."
    }
  }

  var supportsPostGameReview: Bool {
    switch self {
    case .lesson:
      return false
    case .passAndPlay:
      return false
    case .queueMatch:
      return true
    case .playVsStockfish(let configuration):
      return configuration.supportsPostGameReview
    }
  }

  var supportsSocraticCoach: Bool {
    switch self {
    case .lesson, .passAndPlay, .queueMatch, .playVsStockfish:
      return true
    }
  }

  func humanPlayerColor(queueAssignedColor: ChessColor?) -> ChessColor? {
    switch self {
    case .lesson:
      return nil
    case .passAndPlay:
      return nil
    case .queueMatch:
      return queueAssignedColor
    case .playVsStockfish(let configuration):
      return configuration.humanColor
    }
  }

  var localEngineOpponentColor: ChessColor? {
    guard case .playVsStockfish(let configuration) = self else {
      return nil
    }

    return configuration.engineColor
  }

  var usesLocalMatchLog: Bool {
    switch self {
    case .lesson:
      return false
    case .passAndPlay, .playVsStockfish:
      return true
    case .queueMatch:
      return false
    }
  }

  var allowsRemoteMatchLogSync: Bool {
    switch self {
    case .lesson:
      return false
    case .passAndPlay:
      return true
    case .queueMatch:
      return false
    case .playVsStockfish(let configuration):
      return configuration.launchKind == .standard
    }
  }

  var matchLogStatusSummary: String? {
    guard case .playVsStockfish(let configuration) = self,
          configuration.launchKind == .devCheck else {
      return nil
    }

    return "devCheck keeps moves local only because the game started from a custom FEN."
  }

  var isLessonMode: Bool {
    if case .lesson = self {
      return true
    }
    return false
  }

  var warmsStockfishAnalysis: Bool {
    switch self {
    case .lesson:
      return false
    case .passAndPlay, .queueMatch, .playVsStockfish:
      return true
    }
  }

  var supportsPassiveAutomaticCommentary: Bool {
    switch self {
    case .lesson:
      return false
    case .passAndPlay, .queueMatch, .playVsStockfish:
      return true
    }
  }
}

private enum NativeScreen {
  case modeSelection
  case course
  case stockfishSetup
  case landing
  case lobby(PlayerMode)
  case queueMatch
  case experienceLoading(ExperienceMode)
  case experience(ExperienceMode)
}

private enum CourseCatalogKind: Hashable {
  case italianOpening
  case mock
}

private struct CourseCatalogEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let kind: CourseCatalogKind

  var lessonID: String? {
    switch kind {
    case .italianOpening:
      return OpeningLessonDefinition.italianOpening.id
    case .mock:
      return nil
    }
  }

  static let pageSize = 81

  static let mockCatalog: [CourseCatalogEntry] = {
    let featuredTitles: [(String, CourseCatalogKind)] = [
      ("Learn the Italian Opening", .italianOpening),
      ("Learn How to Use the Knight", .mock),
      ("Learn Basic Checkmates", .mock),
      ("Learn Fork Tactics", .mock),
      ("Learn Pins and Skewers", .mock),
      ("Learn Pawn Breaks", .mock),
      ("Learn King Safety", .mock),
      ("Learn Rook Endgames", .mock),
      ("Learn Queen Trades", .mock),
      ("Learn Time Management", .mock),
      ("Learn Deflection Tactics", .mock),
      ("Learn Discovered Attacks", .mock),
      ("Learn Passed Pawns", .mock),
      ("Learn Opposition", .mock),
      ("Learn Outposts", .mock),
      ("Learn Piece Activity", .mock),
      ("Learn the Sicilian Defense", .mock),
      ("Learn the French Defense", .mock),
      ("Learn the London System", .mock),
      ("Learn the Caro-Kann", .mock),
    ]

    let generatedTitles = (1...142).map { index in
      CourseCatalogEntry(id: "mock-course-\(index)", title: "Mock Course \(index)", kind: .mock)
    }

    return featuredTitles.enumerated().map { offset, item in
      CourseCatalogEntry(id: "featured-course-\(offset)", title: item.0, kind: item.1)
    } + generatedTitles
  }()

  static var mockPages: [[CourseCatalogEntry]] {
    stride(from: 0, to: mockCatalog.count, by: pageSize).map { start in
      let end = min(start + pageSize, mockCatalog.count)
      return Array(mockCatalog[start..<end])
    }
  }
}

private struct AppRuntimeConfig {
  let apiBaseURL: URL?
  let piperAPIBaseURL: URL?

  static let current = AppRuntimeConfig()

  init() {
    apiBaseURL = Self.resolveURL(
      environmentKey: "AR_CHESS_API_BASE_URL",
      bundleKey: "ARChessAPIBaseURL"
    )
    piperAPIBaseURL = Self.resolveURL(
      environmentKey: "AR_CHESS_PIPER_API_BASE_URL",
      bundleKey: "ARChessPiperAPIBaseURL",
      fallback: apiBaseURL
    )
  }

  private static func resolveURL(
    environmentKey: String,
    bundleKey: String,
    fallback: URL? = nil
  ) -> URL? {
    let sources = [
      ProcessInfo.processInfo.environment[environmentKey],
      Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String,
    ]

    for candidate in sources {
      guard let candidate else {
        continue
      }

      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
        continue
      }

      return url.deletingTrailingSlash()
    }

    return fallback
  }
}

private struct GeminiHintRequestPayload: Encodable {
  let fen: String
  let recent_history: String?
  let best_move: String
  let side_to_move: String
  let narrator: String
  let moving_piece: String?
  let is_capture: Bool
  let gives_check: Bool
  let themes: [String]
}

private struct GeminiHintResponsePayload: Decodable {
  let hint: String
}

private struct GeminiCoachCommentaryRequestPayload: Encodable {
  let fen: String
  let narrator: String
}

private struct GeminiPieceVoiceLineRequestPayload: Encodable {
  let fen: String
  let piece_type: String
  let piece_color: String
  let recent_lines: [String]
  let dialogue_mode: String
  let piece_dialogue_history: [GeminiDialogueUtterancePayload]
  let latest_piece_line: GeminiDialogueUtterancePayload?
  let context_mode: String
  let from_square: String
  let to_square: String
  let is_capture: Bool
  let is_check: Bool
  let is_near_enemy_king: Bool
  let is_attacked: Bool
  let is_attacked_by_multiple: Bool
  let is_defended: Bool
  let is_well_defended: Bool
  let is_hanging: Bool
  let is_pinned: Bool
  let is_retreat: Bool
  let is_aggressive_advance: Bool
  let is_fork_threat: Bool
  let attacker_count: Int
  let defender_count: Int
  let eval_before: Int?
  let eval_after: Int?
  let eval_delta: Int?
  let position_state: String
  let move_quality: String
  let piece_move_count: Int
  let underutilized_reason: String?
}

private struct GeminiPassiveNarratorLineRequestPayload: Encodable {
  let fen: String
  let recent_history: String?
  let recent_lines: [String]
  let dialogue_mode: String
  let latest_piece_line: GeminiDialogueUtterancePayload?
  let phase: String
  let turns_since_last_narrator_line: Int
  let move_san: String?
  let moving_piece: String?
  let moving_color: String?
  let from_square: String?
  let to_square: String?
  let is_capture: Bool
  let is_check: Bool
  let is_checkmate: Bool
  let is_near_enemy_king: Bool
  let is_attacked: Bool
  let is_pinned: Bool
  let is_retreat: Bool
  let is_aggressive_advance: Bool
  let is_fork_threat: Bool
  let attacker_count: Int
  let defender_count: Int
  let eval_before: Int?
  let eval_after: Int?
  let eval_delta: Int?
  let position_state: String?
  let move_quality: String?
}

private struct GeminiPieceVoiceLineResponsePayload: Decodable {
  let line: String
}

private struct GeminiPassiveNarratorLineResponsePayload: Decodable {
  let line: String
}

private enum PiperSpeakerType: String, CaseIterable, Identifiable {
  case pawn
  case rook
  case knight
  case bishop
  case queen
  case king
  case narrator

  var displayName: String {
    switch self {
    case .pawn:
      return "Pawn"
    case .rook:
      return "Rook"
    case .knight:
      return "Knight"
    case .bishop:
      return "Bishop"
    case .queen:
      return "Queen"
    case .king:
      return "King"
    case .narrator:
      return "Narrator"
    }
  }

  var usesGeminiLiveNarrator: Bool {
    self == .narrator
  }

  var id: String { rawValue }
}

private struct PiperSpeakLineRequestPayload: Encodable {
  let speaker_type: String
  let text: String
}

private struct PiperSpeakLineResponsePayload: Decodable {
  let speaker_type: String
  let resolved_speaker_type: String
  let cache_key: String
  let cache_hit: Bool
  let used_fallback_voice: Bool
  let audio_url: String
}

private struct PiperVoiceInventoryEntryPayload: Decodable, Hashable, Identifiable {
  let voice_id: String
  let name: String
  let language: String?
  let quality: String?
  let sample_rate: Int?
  let configured_speaker_types: [String]

  var id: String { voice_id }

  var displayName: String {
    name
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
  }

  var metadataLine: String {
    [
      language?.uppercased(),
      quality?.capitalized,
      sample_rate.map { "\($0) Hz" }
    ]
    .compactMap { $0 }
    .joined(separator: " • ")
  }
}

private struct PiperVoiceInventoryResponsePayload: Decodable {
  let default_speaker_type: String
  let speaker_assignments: [String: String?]
  let voices: [PiperVoiceInventoryEntryPayload]
}

private struct PiperVoiceAuditionRequestPayload: Encodable {
  let voice_id: String
  let text: String
}

private struct PiperVoiceAuditionResponsePayload: Decodable {
  let voice_id: String
  let cache_key: String
  let cache_hit: Bool
  let audio_url: String
}

private struct PiperVoiceAssignmentRequestPayload: Encodable {
  let voice_id: String
}

private struct PiperVoiceAssignmentResponsePayload: Decodable {
  let speaker_type: String
  let assigned_voice_id: String?
}

private struct GeminiPieceRole: Decodable, Equatable, Hashable {
  let piece: String
  let square: String
  let reason: String
}

private struct GeminiCoachCommentary: Decodable, Equatable {
  let sideToMove: String
  let topWorkers: [GeminiPieceRole]
  let topTraitors: [GeminiPieceRole]
  let coachLines: [String]

  enum CodingKeys: String, CodingKey {
    case sideToMove = "side_to_move"
    case topWorkers = "top_3_workers"
    case topTraitors = "top_3_traitors"
    case coachLines = "coach_lines"
  }
}

private struct GeminiLiveStatusPayload: Decodable, Equatable {
  enum ConnectionState: String, Decodable {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
    case error = "ERROR"
  }

  let state: ConnectionState
  let lastError: String?
  let since: String?
}

private struct GeminiHintContext {
  let fen: String
  let recentHistory: String?
  let bestMove: String
  let sideToMove: ChessColor
  let narrator: NarratorType
  let movingPiece: ChessPieceKind?
  let isCapture: Bool
  let givesCheck: Bool
  let themes: [String]
}

private struct GeminiCoachCommentaryContext: Equatable {
  let fen: String
  let narrator: NarratorType
}

private enum PieceVoicePositionState: String {
  case winning
  case equal
  case losing
}

private enum PieceVoiceContextMode: String {
  case moved
  case ambient
}

private enum PieceVoiceMoveQuality: String {
  case strong
  case tactical
  case defensive
  case desperate
  case poor
  case aggressive
  case routine
}

private enum AutonomousDialogueSpeakerClass: String {
  case piece
  case narrator
  case coach
  case user
}

private enum PieceDialogueMode: String {
  case historyReactive = "history_reactive"
  case independent
  case underutilizedSnark = "underutilized_snark"
}

private enum PassiveNarratorDialogueMode: String {
  case independent
  case pieceReactive = "piece_reactive"
}

private struct GeminiDialogueUtterancePayload: Encodable {
  let speaker_class: String
  let piece_type: String?
  let piece_color: String?
  let piece_identity: String?
  let text: String
}

private struct GeminiPieceVoiceLineContext {
  let fen: String
  let pieceType: ChessPieceKind
  let pieceColor: ChessColor
  let recentLines: [String]
  let dialogueMode: PieceDialogueMode
  let pieceDialogueHistory: [GeminiDialogueUtterancePayload]
  let latestPieceLine: GeminiDialogueUtterancePayload?
  let contextMode: PieceVoiceContextMode
  let fromSquare: BoardSquare
  let toSquare: BoardSquare
  let isCapture: Bool
  let isCheck: Bool
  let isNearEnemyKing: Bool
  let isAttacked: Bool
  let isAttackedByMultiple: Bool
  let isDefended: Bool
  let isWellDefended: Bool
  let isHanging: Bool
  let isPinned: Bool
  let isRetreat: Bool
  let isAggressiveAdvance: Bool
  let isForkThreat: Bool
  let attackerCount: Int
  let defenderCount: Int
  let evalBefore: Int?
  let evalAfter: Int?
  let evalDelta: Int?
  let positionState: PieceVoicePositionState
  let moveQuality: PieceVoiceMoveQuality
  let pieceMoveCount: Int
  let underutilizedReason: String?
}

private enum PassiveNarratorPhase: String {
  case opening
  case move
}

private struct GeminiPassiveNarratorLineContext {
  let fen: String
  let recentHistory: String?
  let recentLines: [String]
  let dialogueMode: PassiveNarratorDialogueMode
  let latestPieceLine: GeminiDialogueUtterancePayload?
  let phase: PassiveNarratorPhase
  let turnsSinceLastNarratorLine: Int
  let moveSAN: String?
  let movingPiece: ChessPieceKind?
  let movingColor: ChessColor?
  let fromSquare: BoardSquare?
  let toSquare: BoardSquare?
  let isCapture: Bool
  let isCheck: Bool
  let isCheckmate: Bool
  let isNearEnemyKing: Bool
  let isAttacked: Bool
  let isPinned: Bool
  let isRetreat: Bool
  let isAggressiveAdvance: Bool
  let isForkThreat: Bool
  let attackerCount: Int
  let defenderCount: Int
  let evalBefore: Int?
  let evalAfter: Int?
  let evalDelta: Int?
  let positionState: PieceVoicePositionState?
  let moveQuality: PieceVoiceMoveQuality?
}

private struct AutonomousDialogueMemoryEntry {
  let speakerClass: AutonomousDialogueSpeakerClass
  let speakerName: String
  let text: String
  let pieceType: ChessPieceKind?
  let pieceColor: ChessColor?
  let pieceIdentity: String?
}

private struct SocraticCoachContext: Equatable {
  let fen: String
  let moveHistory: [String]
  let activeColor: ChessColor
}

private struct SocraticCoachContextUpdatePayload: Encodable {
  let type = "context_update"
  let fen: String
  let move_history: [String]
  let active_color: String
  let moves_played: Int
}

private struct SocraticCoachAudioChunkPayload: Encodable {
  let type = "audio_chunk"
  let data: String
  let mime_type: String
}

private struct SocraticCoachSimplePayload: Encodable {
  let type: String
}

private struct SocraticCoachLessonIntroPayload: Encodable {
  let type = "lesson_intro"
  let lesson_title: String
  let prompt: String
  let focus: String
}

private struct SocraticCoachLessonAttemptFeedbackPayload: Encodable {
  let type = "lesson_attempt_feedback"
  let lesson_title: String
  let prompt: String
  let focus: String
  let remaining_tries: Int
  let move_revealed: Bool
}

private struct SocraticCoachLessonSuccessPayload: Encodable {
  let type = "lesson_success"
  let lesson_title: String
  let prompt: String
  let focus: String
}

private struct SocraticCoachLessonCompletionPayload: Encodable {
  let type = "lesson_complete"
  let lesson_title: String
  let summary: String
}

private struct SocraticCoachVoiceMoveCommitPayload: Encodable {
  let type = "voice_move_commit"
  let uci: String
  let spoken: String?
}

private enum GeminiPassiveAutomaticSpeakerRole: String, Encodable {
  case narrator
  case piece
}

private struct GeminiPassiveNarratorLiveSpeakPayload: Encodable {
  let type = "narrate_line"
  let text: String
  let speaker_role: String
  let speaker_name: String?
}

private enum SocraticCoachMicState: String {
  case inactive
  case muted
  case active

  var systemImageName: String {
    switch self {
    case .inactive:
      return "mic.slash"
    case .muted:
      return "mic.slash.fill"
    case .active:
      return "mic.fill"
    }
  }

  var accentColor: Color {
    switch self {
    case .inactive:
      return Color.black.opacity(0.54)
    case .muted:
      return Color(red: 0.37, green: 0.22, blue: 0.22).opacity(0.84)
    case .active:
      return Color(red: 0.20, green: 0.45, blue: 0.28).opacity(0.90)
    }
  }

  var label: String {
    switch self {
    case .inactive:
      return "Mic off"
    case .muted:
      return "Mic muted"
    case .active:
      return "Mic live"
    }
  }
}

private enum SocraticCoachConnectionState: String {
  case disconnected
  case connecting
  case ready
  case error
}

private final class AudioSessionCoordinator {
  static let shared = AudioSessionCoordinator()

  private enum SessionProfile {
    case playback
    case recording
  }

  private let lock = NSLock()
  private var recordingClients = 0
  private var configuredProfile: SessionProfile?
  private var isSessionActive = false

  private init() {}

  func activatePlaybackSession() throws {
    try configureAudioSession()
  }

  func beginRecordingSession() throws {
    lock.lock()
    recordingClients += 1
    lock.unlock()
    try configureAudioSession()
  }

  func endRecordingSession() {
    lock.lock()
    recordingClients = max(0, recordingClients - 1)
    lock.unlock()
    try? configureAudioSession()
  }

  private func configureAudioSession() throws {
    let desiredProfile: SessionProfile = {
      lock.lock()
      defer { lock.unlock() }
      return recordingClients > 0 ? .recording : .playback
    }()

    guard configuredProfile != desiredProfile || !isSessionActive else {
      return
    }

    let session = AVAudioSession.sharedInstance()
    switch desiredProfile {
    case .recording:
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetoothHFP]
      )
    case .playback:
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    try session.setActive(true, options: [])
    configuredProfile = desiredProfile
    isSessionActive = true
  }
}

private final class SocraticCoachPCMPlayer {
  private static let logger = Logger(subsystem: "ARChess", category: "SocraticCoachAudio")

  private let queue = DispatchQueue(label: "ARChess.SocraticCoachAudio")
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private var configuredSampleRate: Double = 24_000
  private var pendingBufferCount = 0
  private var isEngineConfigured = false
  private var isSpeechActive = false
  private var speechReleaseWorkItem: DispatchWorkItem?
  var onPlaybackActivityChange: ((Bool) -> Void)?

  init() {
    engine.attach(playerNode)
  }

  func play(base64PCM: String, mimeType: String) {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      guard let data = Data(base64Encoded: base64PCM) else {
        Self.logger.error("Coach audio decode failed for base64 chunk.")
        return
      }

      let sampleRate = Self.sampleRate(from: mimeType) ?? 24_000
      let sampleCount = data.count / MemoryLayout<Int16>.size
      guard sampleCount > 0 else {
        return
      }

      var samples = Array(repeating: Int16.zero, count: sampleCount)
      _ = samples.withUnsafeMutableBytes { destination in
        data.copyBytes(to: destination)
      }

      do {
        try AudioSessionCoordinator.shared.activatePlaybackSession()
        try self.prepareEngine(sampleRate: sampleRate)
      } catch {
        Self.logger.error("Coach audio session failed: \(error.localizedDescription, privacy: .public)")
        return
      }

      guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
            let channel = buffer.floatChannelData?[0] else {
        return
      }

      buffer.frameLength = AVAudioFrameCount(sampleCount)
      for index in 0..<sampleCount {
        channel[index] = Float(samples[index]) / Float(Int16.max)
      }

      self.speechReleaseWorkItem?.cancel()
      self.pendingBufferCount += 1
      self.updateSpeechActivity(true)
      self.playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
        guard let self else {
          return
        }
        self.queue.async {
          self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
          if self.pendingBufferCount == 0 {
            let releaseWorkItem = DispatchWorkItem {
              self.updateSpeechActivity(false)
            }
            self.speechReleaseWorkItem = releaseWorkItem
            self.queue.asyncAfter(deadline: .now() + 0.45, execute: releaseWorkItem)
          }
        }
      })

      if !self.playerNode.isPlaying {
        self.playerNode.play()
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      self.pendingBufferCount = 0
      self.speechReleaseWorkItem?.cancel()
      self.speechReleaseWorkItem = nil
      self.playerNode.stop()
      self.engine.stop()
      self.isEngineConfigured = false
      self.updateSpeechActivity(false)
    }
  }

  private func prepareEngine(sampleRate: Double) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw NSError(
        domain: "ARChess.SocraticCoach",
        code: -1301,
        userInfo: [NSLocalizedDescriptionKey: "Could not prepare Socratic Coach playback format."]
      )
    }

    if !isEngineConfigured || configuredSampleRate != sampleRate {
      engine.stop()
      playerNode.stop()
      engine.disconnectNodeOutput(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: format)
      configuredSampleRate = sampleRate
      isEngineConfigured = true
    }

    if !engine.isRunning {
      try engine.start()
    }
  }

  private static func sampleRate(from mimeType: String) -> Double? {
    let lowercased = mimeType.lowercased()
    guard let range = lowercased.range(of: "rate=") else {
      return nil
    }
    let value = lowercased[range.upperBound...]
    let numericPrefix = value.prefix { $0.isNumber }
    return Double(numericPrefix)
  }

  private func updateSpeechActivity(_ isActive: Bool) {
    guard isSpeechActive != isActive else {
      return
    }

    isSpeechActive = isActive
    AmbientMusicController.shared.setSpeechActive(isActive)
    let handler = onPlaybackActivityChange
    DispatchQueue.main.async {
      handler?(isActive)
    }
  }
}

private final class SocraticCoachMicCaptureManager {
  private static let logger = Logger(subsystem: "ARChess", category: "SocraticCoachMic")
  private static let prewarmLock = NSLock()
  private static var hasProcessPrewarmedCapturePath = false

  private let audioEngine = AVAudioEngine()
  private let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
  private var audioConverter: AVAudioConverter?
  private var pendingSamples: [Int16] = []

  var onChunk: ((Data) -> Void)?
  var onStateChange: ((SocraticCoachMicState) -> Void)?
  var onInputBuffer: ((AVAudioPCMBuffer) -> Void)?

  private(set) var state: SocraticCoachMicState = .inactive {
    didSet {
      guard oldValue != state else {
        return
      }
      onStateChange?(state)
    }
  }

  func start(unmuted: Bool) throws {
    guard state == .inactive else {
      setMuted(!unmuted)
      return
    }

    do {
      try prepareCaptureGraph { [weak self] buffer in
        self?.handleInputBuffer(buffer)
      }
      state = unmuted ? .active : .muted
    } catch {
      teardownCaptureGraph(resetRecordingSession: true)
      throw error
    }
  }

  func prewarmIfNeeded() throws {
    Self.prewarmLock.lock()
    let shouldPrewarm = !Self.hasProcessPrewarmedCapturePath
    Self.prewarmLock.unlock()
    guard shouldPrewarm, state == .inactive else {
      return
    }

    do {
      try prepareCaptureGraph { _ in }
      teardownCaptureGraph(resetRecordingSession: true)
      Self.prewarmLock.lock()
      Self.hasProcessPrewarmedCapturePath = true
      Self.prewarmLock.unlock()
    } catch {
      teardownCaptureGraph(resetRecordingSession: true)
      throw error
    }
  }

  func toggleMute() {
    switch state {
    case .inactive:
      break
    case .muted:
      state = .active
    case .active:
      state = .muted
    }
  }

  func setMuted(_ muted: Bool) {
    switch state {
    case .inactive:
      break
    case .muted, .active:
      state = muted ? .muted : .active
    }
  }

  func stop() {
    guard state != .inactive else {
      return
    }

    _ = finishStreamingTurn()
  }

  func finishStreamingTurn() -> Data? {
    guard state != .inactive else {
      return nil
    }

    let finalChunk = flushPendingSamplesForManualSend()
    teardownCaptureGraph(resetRecordingSession: true)
    pendingSamples.removeAll(keepingCapacity: false)
    state = .inactive
    return finalChunk
  }

  private func prepareCaptureGraph(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
    try AudioSessionCoordinator.shared.beginRecordingSession()
    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
      if self.state == .active {
        self.onInputBuffer?(buffer)
      }
      onBuffer(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  private func teardownCaptureGraph(resetRecordingSession: Bool) {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    audioConverter = nil
    if resetRecordingSession {
      AudioSessionCoordinator.shared.endRecordingSession()
    }
  }

  private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
    guard state == .active else {
      pendingSamples.removeAll(keepingCapacity: true)
      return
    }

    guard let converter = audioConverter else {
      return
    }

    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let estimatedFrameCount = max(1, Int(Double(buffer.frameLength) * ratio) + 8)
    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: AVAudioFrameCount(estimatedFrameCount)
    ) else {
      return
    }

    var sourceBuffer: AVAudioPCMBuffer? = buffer
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      if let currentBuffer = sourceBuffer {
        outStatus.pointee = .haveData
        sourceBuffer = nil
        return currentBuffer
      }
      outStatus.pointee = .noDataNow
      return nil
    }

    var error: NSError?
    let conversionStatus = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
    guard error == nil else {
      Self.logger.error("Coach mic conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
      return
    }

    guard conversionStatus != .error,
          let channel = convertedBuffer.floatChannelData?[0] else {
      return
    }

    for index in 0..<Int(convertedBuffer.frameLength) {
      let sample = max(-1.0, min(1.0, channel[index]))
      pendingSamples.append(Int16(sample * Float(Int16.max)))
    }

    emitFullChunksIfNeeded()
  }

  private func emitFullChunksIfNeeded() {
    while pendingSamples.count >= 2048 {
      let chunk = Array(pendingSamples.prefix(2048))
      pendingSamples.removeFirst(2048)
      onChunk?(Self.data(for: chunk))
    }
  }

  private func flushPendingSamples() {
    guard let chunkData = flushPendingSamplesForManualSend() else {
      return
    }

    onChunk?(chunkData)
  }

  private func flushPendingSamplesForManualSend() -> Data? {
    guard !pendingSamples.isEmpty, state == .active else {
      return nil
    }

    var chunk = pendingSamples
    pendingSamples.removeAll(keepingCapacity: false)
    if chunk.count < 2048 {
      chunk.append(contentsOf: repeatElement(0, count: 2048 - chunk.count))
    }
    return Self.data(for: Array(chunk.prefix(2048)))
  }

  private static func data(for samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { pointer in
      Data(buffer: pointer)
    }
  }
}

private final class SocraticCoachDirectCommandRecognizer {
  private static let logger = Logger(subsystem: "ARChess", category: "SocraticCoachSpeech")
  private static let finishWaitNanoseconds: UInt64 = 350_000_000

  private let transcriptLock = NSLock()
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var latestTranscript = ""

  static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
    SFSpeechRecognizer.authorizationStatus()
  }

  static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }

  func startIfAuthorized() {
    cancel()

    guard Self.authorizationStatus() == .authorized,
          let recognizer,
          recognizer.isAvailable else {
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 16.0, *) {
      request.addsPunctuation = false
    }

    latestTranscript = ""
    recognitionRequest = request
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else {
        return
      }

      if let result {
        self.transcriptLock.lock()
        self.latestTranscript = result.bestTranscription.formattedString
        self.transcriptLock.unlock()
      }

      if let error {
        Self.logger.debug("Direct command recognition finished with error: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    recognitionRequest?.append(buffer)
  }

  func finish() async -> String? {
    recognitionRequest?.endAudio()
    try? await Task.sleep(nanoseconds: Self.finishWaitNanoseconds)
    let transcript = currentTranscript()
    cancel()
    return transcript
  }

  func cancel() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    transcriptLock.lock()
    latestTranscript = ""
    transcriptLock.unlock()
  }

  private func currentTranscript() -> String? {
    transcriptLock.lock()
    let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    transcriptLock.unlock()
    return transcript.isEmpty ? nil : transcript
  }
}

@MainActor
private final class SocraticCoachStore: ObservableObject {
  private static let logger = Logger(subsystem: "ARChess", category: "SocraticCoach")
  private static let startupConnectDelay: TimeInterval = 0.15
  private static let microphonePrewarmDelay: TimeInterval = 0.45
  private static let blockedTranscriptMarkers = [
    "the user",
    "the player asked",
    "user posed",
    "i'm focusing on",
    "i am focusing on",
    "i'm crafting",
    "i am crafting",
    "i'm now structuring",
    "i am now structuring",
    "i'm aiming to",
    "i am aiming to",
    "i intend to",
    "my goal is to",
    "i will narrate",
    "i will conclude",
    "without analyzing",
    "framework emphasizes",
    "socratic question",
    "internal process",
    "scratch work",
    "section title",
  ]

  @Published private(set) var connectionState: SocraticCoachConnectionState = .disconnected
  @Published private(set) var micState: SocraticCoachMicState = .inactive
  @Published private(set) var isStreamingResponse = false
  @Published private(set) var statusText = "Socratic Coach is offline."
  @Published private(set) var lastError: String?
  @Published private(set) var transcriptText: String?

  private let encoder = JSONEncoder()
  private let webSocketURL: URL?
  private let session: URLSession
  private let micCapture = SocraticCoachMicCaptureManager()
  private let audioPlayer = SocraticCoachPCMPlayer()
  private let directCommandRecognizer = SocraticCoachDirectCommandRecognizer()
  private var webSocketTask: URLSessionWebSocketTask?
  private var isEnabled = false
  private var currentContext: SocraticCoachContext?
  private var lastSentContext: SocraticCoachContext?
  private var reconnectWorkItem: DispatchWorkItem?
  private var delayedConnectWorkItem: DispatchWorkItem?
  private var microphonePrewarmWorkItem: DispatchWorkItem?
  private var threatZoneHandler: (([String], String?) -> Void)?
  private var moveHandler: ((String, String?) -> Void)?
  private var directVoiceCommandHandler: ((String) -> String?)?

  init(
    narrator: NarratorType,
    apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL,
    session: URLSession = .shared
  ) {
    self.webSocketURL = Self.makeWebSocketURL(from: apiBaseURL, narrator: narrator)
    self.session = session

    micCapture.onStateChange = { [weak self] nextState in
      Task { @MainActor [weak self] in
        self?.micState = nextState
        AmbientMusicController.shared.setSpeechActive(nextState == .active)
      }
    }

    micCapture.onChunk = { [weak self] chunkData in
      Task { @MainActor [weak self] in
        await self?.sendAudioChunk(chunkData)
      }
    }

    micCapture.onInputBuffer = { [weak self] buffer in
      self?.directCommandRecognizer.append(buffer)
    }
  }

  var isConfigured: Bool {
    webSocketURL != nil
  }

  var isVisibleInCurrentMode: Bool {
    isEnabled
  }

  var canRequestHelp: Bool {
    isEnabled && isConfigured && !isStreamingResponse
  }

  var blocksPassiveCommentary: Bool {
    isEnabled && (micState != .inactive || isStreamingResponse)
  }

  var caption: PiecePersonalityDirector.Caption? {
    nil
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else {
      return
    }

    isEnabled = enabled
    if enabled {
      statusText = isConfigured
        ? "Socratic Coach standing by."
        : "Set ARChessAPIBaseURL to enable Socratic Coach."
      scheduleDelayedConnect()
      scheduleMicrophonePrewarmIfNeeded()
      if let currentContext, webSocketTask != nil {
        sendContextIfNeeded(force: true, context: currentContext)
      }
    } else {
      disconnect()
    }
  }

  func bindThreatZoneHandler(_ handler: @escaping ([String], String?) -> Void) {
    threatZoneHandler = handler
  }

  func unbindThreatZoneHandler() {
    threatZoneHandler = nil
  }

  func bindMoveHandler(_ handler: @escaping (String, String?) -> Void) {
    moveHandler = handler
  }

  func unbindMoveHandler() {
    moveHandler = nil
  }

  func bindDirectVoiceCommandHandler(_ handler: @escaping (String) -> String?) {
    directVoiceCommandHandler = handler
  }

  func unbindDirectVoiceCommandHandler() {
    directVoiceCommandHandler = nil
  }

  func updateContext(_ context: SocraticCoachContext?) {
    currentContext = context
    guard isEnabled, let context else {
      return
    }

    if webSocketTask != nil {
      sendContextIfNeeded(force: false, context: context)
    } else {
      scheduleDelayedConnect()
    }
  }

  func requestStrategicBriefing() {
    guard canRequestHelp, prepareNarrationRequest() else {
      return
    }
    send(payload: SocraticCoachSimplePayload(type: "help_request"))
  }

  func requestLessonIntro(lessonTitle: String, prompt: String, focus: String) {
    guard prepareNarrationRequest() else {
      return
    }
    send(
      payload: SocraticCoachLessonIntroPayload(
        lesson_title: lessonTitle,
        prompt: prompt,
        focus: focus
      )
    )
  }

  func requestLessonAttemptFeedback(
    lessonTitle: String,
    prompt: String,
    focus: String,
    remainingTries: Int,
    moveRevealed: Bool
  ) {
    guard prepareNarrationRequest() else {
      return
    }

    send(
      payload: SocraticCoachLessonAttemptFeedbackPayload(
        lesson_title: lessonTitle,
        prompt: prompt,
        focus: focus,
        remaining_tries: remainingTries,
        move_revealed: moveRevealed
      )
    )
  }

  func requestLessonSuccess(lessonTitle: String, prompt: String, focus: String) {
    guard prepareNarrationRequest() else {
      return
    }

    send(
      payload: SocraticCoachLessonSuccessPayload(
        lesson_title: lessonTitle,
        prompt: prompt,
        focus: focus
      )
    )
  }

  func requestLessonCompletion(lessonTitle: String, summary: String) {
    guard prepareNarrationRequest() else {
      return
    }

    send(
      payload: SocraticCoachLessonCompletionPayload(
        lesson_title: lessonTitle,
        summary: summary
      )
    )
  }

  func toggleMicrophone() async {
    guard isEnabled, isConfigured else {
      statusText = "Socratic Coach mic is unavailable until ARChessAPIBaseURL is configured."
      return
    }

    delayedConnectWorkItem?.cancel()
    ensureConnectedIfNeeded()
    if let currentContext {
      sendContextIfNeeded(force: true, context: currentContext)
    }

    switch micState {
    case .inactive:
      let granted = await requestMicrophonePermission()
      guard granted else {
        lastError = "Microphone permission was denied."
        statusText = "Microphone permission is required for live Socratic questions."
        return
      }

      let speechAuthorization = await requestSpeechRecognitionAuthorizationIfNeeded()
      if speechAuthorization == .authorized {
        directCommandRecognizer.startIfAuthorized()
      } else {
        directCommandRecognizer.cancel()
      }

      do {
        try await startMicCapture(unmuted: true)
        statusText = "Mic live. Tap again to send your question."
      } catch {
        lastError = error.localizedDescription
        statusText = "Mic could not start."
      }
    case .active:
      let finalChunk = micCapture.finishStreamingTurn()
      transcriptText = nil
      audioPlayer.stop()
      let directVoiceCommandTranscript = await directCommandRecognizer.finish()
      if let directVoiceCommandTranscript,
         let committedMoveUCI = directVoiceCommandHandler?(directVoiceCommandTranscript) {
        send(
          payload: SocraticCoachVoiceMoveCommitPayload(
            uci: committedMoveUCI,
            spoken: directVoiceCommandTranscript
          )
        )
        isStreamingResponse = false
        statusText = "Voice move ready."
        return
      }
      if let finalChunk {
        await sendAudioChunk(finalChunk)
      }
      isStreamingResponse = true
      send(payload: SocraticCoachSimplePayload(type: "audio_stream_end"))
      statusText = "Question sent. Socratic Coach is listening for the reply."
    case .muted:
      micCapture.toggleMute()
      isStreamingResponse = false
      statusText = "Mic live. Tap again to send your question."
    }
  }

  func disconnect() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    delayedConnectWorkItem?.cancel()
    delayedConnectWorkItem = nil
    microphonePrewarmWorkItem?.cancel()
    microphonePrewarmWorkItem = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    micCapture.stop()
    directCommandRecognizer.cancel()
    audioPlayer.stop()
    connectionState = .disconnected
    isStreamingResponse = false
    transcriptText = nil
    lastSentContext = nil
    statusText = isConfigured
      ? "Socratic Coach disconnected."
      : "Set ARChessAPIBaseURL to enable Socratic Coach."
  }

  private func ensureConnectedIfNeeded() {
    guard isEnabled else {
      return
    }

    guard let webSocketURL else {
      connectionState = .error
      statusText = "Set ARChessAPIBaseURL to enable Socratic Coach."
      return
    }

    guard webSocketTask == nil else {
      return
    }

    connectionState = .connecting
    statusText = "Socratic Coach connecting..."
    let task = session.webSocketTask(with: webSocketURL)
    webSocketTask = task
    task.resume()
    receiveNextMessage()
  }

  private func prepareNarrationRequest() -> Bool {
    guard isEnabled, isConfigured, !isStreamingResponse else {
      return false
    }

    delayedConnectWorkItem?.cancel()
    ensureConnectedIfNeeded()
    if let currentContext {
      sendContextIfNeeded(force: true, context: currentContext)
    }
    transcriptText = nil
    audioPlayer.stop()
    isStreamingResponse = true
    return true
  }

  private func scheduleDelayedConnect() {
    guard isEnabled, isConfigured, webSocketTask == nil else {
      return
    }

    delayedConnectWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.ensureConnectedIfNeeded()
        if let context = self?.currentContext {
          self?.sendContextIfNeeded(force: true, context: context)
        }
      }
    }
    delayedConnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupConnectDelay, execute: workItem)
  }

  private func scheduleMicrophonePrewarmIfNeeded() {
    guard isEnabled, isConfigured, micState == .inactive else {
      return
    }

    let permission = AVAudioSession.sharedInstance().recordPermission
    guard permission == .granted else {
      return
    }

    microphonePrewarmWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      guard self.isEnabled, self.micState == .inactive else {
        return
      }

      let micCapture = self.micCapture
      DispatchQueue.global(qos: .utility).async {
        do {
          try micCapture.prewarmIfNeeded()
        } catch {
          Self.logger.debug("Mic prewarm skipped: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
    microphonePrewarmWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.microphonePrewarmDelay, execute: workItem)
  }

  private func receiveNextMessage() {
    guard let webSocketTask else {
      return
    }

    webSocketTask.receive { [weak self] result in
      guard let self else {
        return
      }

      Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        switch result {
        case .failure(let error):
          self.handleReceiveFailure(error)
        case .success(let message):
          self.handleReceived(message)
          self.receiveNextMessage()
        }
      }
    }
  }

  private func handleReceiveFailure(_ error: Error) {
    webSocketTask = nil
    connectionState = .connecting
    isStreamingResponse = false
    lastError = error.localizedDescription
    statusText = "Socratic Coach reconnecting..."

    guard isEnabled else {
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.ensureConnectedIfNeeded()
        if let context = self?.currentContext {
          self?.sendContextIfNeeded(force: true, context: context)
        }
      }
    }
    reconnectWorkItem?.cancel()
    reconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
  }

  private func handleReceived(_ message: URLSessionWebSocketTask.Message) {
    let data: Data
    switch message {
    case .string(let text):
      data = Data(text.utf8)
    case .data(let rawData):
      data = rawData
    @unknown default:
      return
    }

    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = payload["type"] as? String else {
      return
    }

    switch type {
    case "status":
      let stateValue = (payload["state"] as? String ?? "").lowercased()
      switch stateValue {
      case "ready":
        connectionState = .ready
        lastError = nil
        statusText = "Socratic Coach is ready."
        if let context = currentContext {
          sendContextIfNeeded(force: true, context: context)
        }
      case "connecting":
        connectionState = .connecting
        statusText = payload["message"] as? String ?? "Socratic Coach connecting..."
      case "error":
        connectionState = .error
        isStreamingResponse = false
        let message = payload["message"] as? String ?? "Socratic Coach failed."
        lastError = message
        statusText = message
      default:
        connectionState = .disconnected
        statusText = payload["message"] as? String ?? "Socratic Coach disconnected."
      }
    case "streaming":
      isStreamingResponse = payload["active"] as? Bool ?? false
    case "turn_complete":
      isStreamingResponse = false
      statusText = "Socratic Coach is ready."
    case "output_transcription":
      let capped = (payload["text"] as? String).flatMap(Self.sanitizedTranscript)
      if let capped {
        maybeHighlightNarrationFocus(capped.text)
      }
      transcriptText = nil
    case "audio_chunk":
      guard let base64PCM = payload["data"] as? String else {
        return
      }
      let mimeType = payload["mime_type"] as? String ?? "audio/pcm;rate=24000"
      audioPlayer.play(base64PCM: base64PCM, mimeType: mimeType)
    case "tool_call":
      guard let name = payload["name"] as? String, name == "show_threat_zone" else {
        return
      }
      let args = payload["args"] as? [String: Any]
      let squares = args?["squares"] as? [String] ?? []
      let reason = args?["reason"] as? String
      threatZoneHandler?(squares, reason)
    case "voice_move":
      guard let uci = payload["uci"] as? String else {
        return
      }
      let spoken = payload["spoken"] as? String
      isStreamingResponse = false
      transcriptText = nil
      audioPlayer.stop()
      statusText = "Voice move ready."
      if let destinationSquare = Self.destinationSquare(forVoiceMoveUCI: uci) {
        threatZoneHandler?([destinationSquare], "Voice command")
      }
      moveHandler?(uci, spoken)
    default:
      break
    }
  }

  private func sendContextIfNeeded(force: Bool, context: SocraticCoachContext) {
    guard force || lastSentContext != context else {
      return
    }

    lastSentContext = context
    send(
      payload: SocraticCoachContextUpdatePayload(
        fen: context.fen,
        move_history: context.moveHistory,
        active_color: context.activeColor.fenSymbol,
        moves_played: context.moveHistory.count
      )
    )
  }

  private func sendAudioChunk(_ chunkData: Data) async {
    guard isEnabled, webSocketTask != nil else {
      return
    }

    let payload = SocraticCoachAudioChunkPayload(
      data: chunkData.base64EncodedString(),
      mime_type: "audio/pcm;rate=16000"
    )
    send(payload: payload)
  }

  private func send<T: Encodable>(payload: T) {
    guard let webSocketTask else {
      return
    }

    do {
      let data = try encoder.encode(payload)
      guard let text = String(data: data, encoding: .utf8) else {
        return
      }

      webSocketTask.send(.string(text)) { [weak self] error in
        guard let self, let error else {
          return
        }

        Task { @MainActor [weak self] in
          self?.handleReceiveFailure(error)
        }
      }
    } catch {
      lastError = error.localizedDescription
      statusText = "Socratic Coach failed to encode a websocket message."
    }
  }

  private func startMicCapture(unmuted: Bool) async throws {
    let micCapture = self.micCapture
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try micCapture.start(unmuted: unmuted)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func maybeHighlightNarrationFocus(_ text: String) {
    guard let squares = narrationHighlightSquares(for: text) else {
      return
    }
    threatZoneHandler?(squares, "Central focus")
  }

  private static func sanitizedTranscript(_ text: String) -> (text: String, truncated: Bool)? {
    let normalized = text
      .replacingOccurrences(of: "**", with: " ")
      .replacingOccurrences(of: "__", with: " ")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return nil
    }

    let lowered = normalized.lowercased()
    guard !blockedTranscriptMarkers.contains(where: { lowered.contains($0) }) else {
      return nil
    }

    guard !looksLikeSectionHeading(normalized) else {
      return nil
    }

    let capped = cappedNarrationText(normalized)
    guard !capped.text.isEmpty else {
      return nil
    }
    return capped
  }

  private static func looksLikeSectionHeading(_ text: String) -> Bool {
    guard text.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!,:;")) == nil else {
      return false
    }

    let words = text.split(separator: " ")
    guard !words.isEmpty, words.count <= 6 else {
      return false
    }

    let letterWords = words.compactMap { word -> String? in
      let letters = word.filter { $0.isLetter }
      return letters.isEmpty ? nil : String(letters)
    }
    guard !letterWords.isEmpty else {
      return false
    }

    return letterWords.allSatisfy { word in
      guard let first = word.first else {
        return false
      }
      return first.isUppercase
    }
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func requestSpeechRecognitionAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
    let currentStatus = SocraticCoachDirectCommandRecognizer.authorizationStatus()
    switch currentStatus {
    case .authorized, .denied, .restricted:
      return currentStatus
    case .notDetermined:
      return await SocraticCoachDirectCommandRecognizer.requestAuthorization()
    @unknown default:
      return .denied
    }
  }

  private static func makeWebSocketURL(from apiBaseURL: URL?, narrator: NarratorType) -> URL? {
    guard let apiBaseURL else {
      return nil
    }

    var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
    if components?.scheme == "https" {
      components?.scheme = "wss"
    } else {
      components?.scheme = "ws"
    }

    let existingPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    let suffix = "v1/gemini/live"
    components?.path = existingPath.isEmpty ? "/\(suffix)" : "/\(existingPath)/\(suffix)"
    var queryItems = components?.queryItems ?? []
    queryItems.removeAll { $0.name == "narrator" }
    queryItems.append(URLQueryItem(name: "narrator", value: narrator.rawValue))
    components?.queryItems = queryItems
    return components?.url
  }

  private static func destinationSquare(forVoiceMoveUCI uci: String) -> String? {
    let trimmed = uci.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.count >= 4 else {
      return nil
    }
    return String(trimmed.dropFirst(2).prefix(2))
  }
}

@MainActor
private final class GeminiPassiveNarratorLiveSpeaker {
  struct PlaybackRequest {
    let line: String
    let role: GeminiPassiveAutomaticSpeakerRole
    let speakerName: String?
  }

  private static let logger = Logger(subsystem: "ARChess", category: "PassiveNarratorLive")
  private static let reconnectDelay: TimeInterval = 1.5

  private let encoder = JSONEncoder()
  private let webSocketURL: URL?
  private let session: URLSession
  private let audioPlayer = SocraticCoachPCMPlayer()
  private var webSocketTask: URLSessionWebSocketTask?
  private var reconnectWorkItem: DispatchWorkItem?
  private var currentRequest: PlaybackRequest?
  private var hasObservedAudioForCurrentLine = false
  private var isStreamingResponse = false
  private var isAudioPlaying = false
  private var isEnabled = true

  var onBusyStateChange: ((Bool) -> Void)?
  var onPlaybackActivityChange: ((PlaybackRequest?, Bool) -> Void)?
  var onLineFailure: ((PlaybackRequest, String) -> Void)?

  init(
    narrator: NarratorType,
    apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL,
    session: URLSession = .shared
  ) {
    self.webSocketURL = Self.makeWebSocketURL(from: apiBaseURL, narrator: narrator)
    self.session = session

    audioPlayer.onPlaybackActivityChange = { [weak self] isActive in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        self.isAudioPlaying = isActive
        self.onPlaybackActivityChange?(self.currentRequest, isActive)
        self.notifyBusyStateChange()
      }
    }
  }

  var isConfigured: Bool {
    webSocketURL != nil
  }

  var isBusy: Bool {
    isStreamingResponse || isAudioPlaying
  }

  func prewarmIfNeeded() {
    guard isEnabled else {
      return
    }
    ensureConnectedIfNeeded()
  }

  func speak(
    line: String,
    role: GeminiPassiveAutomaticSpeakerRole,
    speakerName: String? = nil
  ) -> Bool {
    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isEnabled, isConfigured, !trimmedLine.isEmpty, !isBusy else {
      return false
    }

    reconnectWorkItem?.cancel()
    ensureConnectedIfNeeded()
    currentRequest = PlaybackRequest(line: trimmedLine, role: role, speakerName: speakerName)
    hasObservedAudioForCurrentLine = false
    isStreamingResponse = true
    notifyBusyStateChange()
    send(
      payload: GeminiPassiveNarratorLiveSpeakPayload(
        text: trimmedLine,
        speaker_role: role.rawValue,
        speaker_name: speakerName
      )
    )
    return true
  }

  func stop() {
    currentRequest = nil
    hasObservedAudioForCurrentLine = false
    isStreamingResponse = false
    audioPlayer.stop()
    notifyBusyStateChange()
  }

  func disconnect() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    stop()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
  }

  private func ensureConnectedIfNeeded() {
    guard isEnabled else {
      return
    }

    guard let webSocketURL else {
      return
    }

    guard webSocketTask == nil else {
      return
    }

    let task = session.webSocketTask(with: webSocketURL)
    webSocketTask = task
    task.resume()
    receiveNextMessage()
  }

  private func receiveNextMessage() {
    guard let webSocketTask else {
      return
    }

    webSocketTask.receive { [weak self] result in
      guard let self else {
        return
      }

      Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        switch result {
        case .failure(let error):
          self.handleReceiveFailure(error)
        case .success(let message):
          self.handleReceived(message)
          self.receiveNextMessage()
        }
      }
    }
  }

  private func handleReceiveFailure(_ error: Error) {
    webSocketTask = nil
    let message = error.localizedDescription
    if let currentRequest, !hasObservedAudioForCurrentLine {
      onLineFailure?(currentRequest, message)
    }
    currentRequest = nil
    hasObservedAudioForCurrentLine = false
    isStreamingResponse = false
    audioPlayer.stop()
    notifyBusyStateChange()

    guard isEnabled else {
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.ensureConnectedIfNeeded()
      }
    }
    reconnectWorkItem?.cancel()
    reconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay, execute: workItem)
  }

  private func handleReceived(_ message: URLSessionWebSocketTask.Message) {
    let data: Data
    switch message {
    case .string(let text):
      data = Data(text.utf8)
    case .data(let rawData):
      data = rawData
    @unknown default:
      return
    }

    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = payload["type"] as? String else {
      return
    }

    switch type {
    case "status":
      if let state = payload["state"] as? String, state.lowercased() == "error" {
        let message = payload["message"] as? String ?? "Gemini passive narrator failed."
        if let currentRequest, !hasObservedAudioForCurrentLine {
          onLineFailure?(currentRequest, message)
        }
        currentRequest = nil
        hasObservedAudioForCurrentLine = false
        isStreamingResponse = false
        audioPlayer.stop()
        notifyBusyStateChange()
      }
    case "streaming":
      isStreamingResponse = payload["active"] as? Bool ?? false
      notifyBusyStateChange()
    case "output_transcription":
      let text = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !text.isEmpty, let currentRequest {
        self.currentRequest = PlaybackRequest(
          line: text,
          role: currentRequest.role,
          speakerName: currentRequest.speakerName
        )
      }
    case "audio_chunk":
      guard let base64PCM = payload["data"] as? String else {
        return
      }
      let mimeType = payload["mime_type"] as? String ?? "audio/pcm;rate=24000"
      hasObservedAudioForCurrentLine = true
      audioPlayer.play(base64PCM: base64PCM, mimeType: mimeType)
      notifyBusyStateChange()
    case "turn_complete":
      isStreamingResponse = false
      if !isAudioPlaying {
        currentRequest = nil
        hasObservedAudioForCurrentLine = false
      }
      notifyBusyStateChange()
    case "busy":
      if let currentRequest, !hasObservedAudioForCurrentLine {
        let message = payload["message"] as? String ?? "Gemini passive narrator is busy."
        onLineFailure?(currentRequest, message)
      }
      currentRequest = nil
      hasObservedAudioForCurrentLine = false
      isStreamingResponse = false
      notifyBusyStateChange()
    default:
      break
    }

    if !isBusy {
      currentRequest = nil
      hasObservedAudioForCurrentLine = false
    }
  }

  private func send<T: Encodable>(payload: T) {
    guard let webSocketTask else {
      if let currentRequest, !hasObservedAudioForCurrentLine {
        onLineFailure?(currentRequest, "Gemini passive narrator socket is unavailable.")
      }
      currentRequest = nil
      hasObservedAudioForCurrentLine = false
      isStreamingResponse = false
      notifyBusyStateChange()
      return
    }

    do {
      let data = try encoder.encode(payload)
      guard let text = String(data: data, encoding: .utf8) else {
        return
      }

      webSocketTask.send(.string(text)) { [weak self] error in
        guard let self, let error else {
          return
        }

        Task { @MainActor [weak self] in
          self?.handleReceiveFailure(error)
        }
      }
    } catch {
      if let currentRequest, !hasObservedAudioForCurrentLine {
        onLineFailure?(currentRequest, error.localizedDescription)
      }
      currentRequest = nil
      hasObservedAudioForCurrentLine = false
      isStreamingResponse = false
      notifyBusyStateChange()
    }
  }

  private func notifyBusyStateChange() {
    onBusyStateChange?(isBusy)
  }

  private static func makeWebSocketURL(from apiBaseURL: URL?, narrator: NarratorType) -> URL? {
    guard let apiBaseURL else {
      return nil
    }

    var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
    if components?.scheme == "https" {
      components?.scheme = "wss"
    } else {
      components?.scheme = "ws"
    }

    let existingPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    let suffix = "v1/gemini/passive-live"
    components?.path = existingPath.isEmpty ? "/\(suffix)" : "/\(existingPath)/\(suffix)"
    var queryItems = components?.queryItems ?? []
    queryItems.removeAll { $0.name == "narrator" }
    queryItems.append(URLQueryItem(name: "narrator", value: narrator.rawValue))
    components?.queryItems = queryItems
    return components?.url
  }
}

private struct PiperPreparedLine {
  let requestedSpeakerType: PiperSpeakerType
  let resolvedSpeakerType: PiperSpeakerType
  let cacheKey: String
  let cacheHit: Bool
  let usedFallbackVoice: Bool
  let localFileURL: URL
}

private struct PiperAuditionPreparedLine {
  let voiceID: String
  let cacheKey: String
  let cacheHit: Bool
  let localFileURL: URL
}

private final class PiperTTSService {
  private static let logger = Logger(subsystem: "ARChess", category: "PiperTTSService")

  private let apiBaseURL: URL?
  private let session: URLSession
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    apiBaseURL: URL? = AppRuntimeConfig.current.piperAPIBaseURL,
    session: URLSession = .shared,
    fileManager: FileManager = .default
  ) {
    self.apiBaseURL = apiBaseURL
    self.session = session
    self.fileManager = fileManager
  }

  var isConfigured: Bool {
    apiBaseURL != nil
  }

  func prepareCacheIfNeeded() {
    let directory = cacheDirectory()
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
  }

  func synthesizeLine(
    speakerType: PiperSpeakerType,
    text: String
  ) async throws -> PiperPreparedLine {
    let baseURL = try requireBaseURL()

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2002,
        userInfo: [NSLocalizedDescriptionKey: "Piper TTS cannot speak an empty line."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("tts")
        .appendingPathComponent("piper")
        .appendingPathComponent("speak")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 20.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try encoder.encode(
      PiperSpeakLineRequestPayload(
        speaker_type: speakerType.rawValue,
        text: trimmedText
      )
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2003,
        userInfo: [NSLocalizedDescriptionKey: "Piper TTS metadata endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Piper TTS response."
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let payload = try decoder.decode(PiperSpeakLineResponsePayload.self, from: data)
    let sanitizedCacheKey = Self.sanitizeCacheKey(payload.cache_key)
    let localFileURL = cacheDirectory().appendingPathComponent("\(sanitizedCacheKey).wav")
    if !isPlayableAudioFile(at: localFileURL) {
      let audioURL = try resolveAudioURL(payload.audio_url, apiBaseURL: baseURL)
      try await downloadAudioIfNeeded(from: audioURL, to: localFileURL)
    }

    let requestedSpeaker = PiperSpeakerType(rawValue: payload.speaker_type) ?? speakerType
    let resolvedSpeaker = PiperSpeakerType(rawValue: payload.resolved_speaker_type) ?? .narrator
    return PiperPreparedLine(
      requestedSpeakerType: requestedSpeaker,
      resolvedSpeakerType: resolvedSpeaker,
      cacheKey: sanitizedCacheKey,
      cacheHit: payload.cache_hit,
      usedFallbackVoice: payload.used_fallback_voice,
      localFileURL: localFileURL
    )
  }

  func fetchAvailableVoices() async throws -> PiperVoiceInventoryResponsePayload {
    let baseURL = try requireBaseURL()
    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("tts")
        .appendingPathComponent("piper")
        .appendingPathComponent("voices")
    )
    request.httpMethod = "GET"
    request.timeoutInterval = 20.0
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data, fallbackMessage: "Piper voice inventory request failed.")
    return try decoder.decode(PiperVoiceInventoryResponsePayload.self, from: data)
  }

  func synthesizeAuditionLine(
    voiceID: String,
    text: String
  ) async throws -> PiperAuditionPreparedLine {
    let baseURL = try requireBaseURL()
    let trimmedVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVoiceID.isEmpty else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2007,
        userInfo: [NSLocalizedDescriptionKey: "Piper audition requires a voice id."]
      )
    }

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2008,
        userInfo: [NSLocalizedDescriptionKey: "Piper audition cannot speak an empty line."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("tts")
        .appendingPathComponent("piper")
        .appendingPathComponent("audition")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 20.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try encoder.encode(
      PiperVoiceAuditionRequestPayload(
        voice_id: trimmedVoiceID,
        text: trimmedText
      )
    )

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data, fallbackMessage: "Piper audition request failed.")

    let payload = try decoder.decode(PiperVoiceAuditionResponsePayload.self, from: data)
    let sanitizedCacheKey = Self.sanitizeCacheKey(payload.cache_key)
    let localFileURL = cacheDirectory().appendingPathComponent("\(sanitizedCacheKey).wav")
    if !isPlayableAudioFile(at: localFileURL) {
      let audioURL = try resolveAudioURL(payload.audio_url, apiBaseURL: baseURL)
      try await downloadAudioIfNeeded(from: audioURL, to: localFileURL)
    }

    return PiperAuditionPreparedLine(
      voiceID: payload.voice_id,
      cacheKey: sanitizedCacheKey,
      cacheHit: payload.cache_hit,
      localFileURL: localFileURL
    )
  }

  func assignVoice(
    _ voiceID: String,
    to speakerType: PiperSpeakerType
  ) async throws -> PiperVoiceAssignmentResponsePayload {
    let baseURL = try requireBaseURL()
    let trimmedVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVoiceID.isEmpty else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2009,
        userInfo: [NSLocalizedDescriptionKey: "Piper assignment requires a voice id."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("tts")
        .appendingPathComponent("piper")
        .appendingPathComponent("voices")
        .appendingPathComponent("assignments")
        .appendingPathComponent(speakerType.rawValue)
    )
    request.httpMethod = "PUT"
    request.timeoutInterval = 20.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try encoder.encode(PiperVoiceAssignmentRequestPayload(voice_id: trimmedVoiceID))

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data, fallbackMessage: "Piper voice assignment failed.")
    return try decoder.decode(PiperVoiceAssignmentResponsePayload.self, from: data)
  }

  private func downloadAudioIfNeeded(from audioURL: URL, to destinationURL: URL) async throws {
    try fileManager.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true, attributes: nil)

    if isPlayableAudioFile(at: destinationURL) {
      return
    }

    let (temporaryURL, response) = try await session.download(from: audioURL)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2004,
        userInfo: [NSLocalizedDescriptionKey: "Piper audio endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Piper audio download failed with status \(httpResponse.statusCode)."]
      )
    }

    let stagingURL = destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent("\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
    if fileManager.fileExists(atPath: stagingURL.path) {
      try? fileManager.removeItem(at: stagingURL)
    }

    do {
      try fileManager.copyItem(at: temporaryURL, to: stagingURL)
    } catch {
      Self.logger.error("Piper audio copy failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }

    if isPlayableAudioFile(at: destinationURL) {
      try? fileManager.removeItem(at: stagingURL)
      return
    }

    if fileManager.fileExists(atPath: destinationURL.path) {
      try? fileManager.removeItem(at: destinationURL)
    }
    try fileManager.moveItem(at: stagingURL, to: destinationURL)
  }

  private func resolveAudioURL(_ rawValue: String, apiBaseURL: URL) throws -> URL {
    if let directURL = URL(string: rawValue), directURL.scheme != nil {
      return directURL
    }

    if let relativeURL = URL(string: rawValue, relativeTo: apiBaseURL)?.absoluteURL {
      return relativeURL
    }

    throw NSError(
      domain: "ARChess.PiperTTS",
      code: -2005,
      userInfo: [NSLocalizedDescriptionKey: "Piper audio_url could not be resolved."]
    )
  }

  private func cacheDirectory() -> URL {
    let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return root.appendingPathComponent("PiperTTS", isDirectory: true)
  }

  private func isPlayableAudioFile(at fileURL: URL) -> Bool {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return false
    }

    let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return fileSize > 0
  }

  private static func sanitizeCacheKey(_ rawValue: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let filteredScalars = rawValue.unicodeScalars.filter { allowed.contains($0) }
    let sanitized = String(String.UnicodeScalarView(filteredScalars))
    return sanitized.isEmpty ? UUID().uuidString.lowercased() : sanitized.lowercased()
  }

  private func requireBaseURL() throws -> URL {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2001,
        userInfo: [NSLocalizedDescriptionKey: "Piper TTS is disabled until ARChessPiperAPIBaseURL or ARChessAPIBaseURL is configured."]
      )
    }
    return baseURL
  }

  private func validateHTTPResponse(
    _ response: URLResponse,
    data: Data,
    fallbackMessage: String
  ) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: -2010,
        userInfo: [NSLocalizedDescriptionKey: "Piper endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? fallbackMessage
      throw NSError(
        domain: "ARChess.PiperTTS",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }
}

@MainActor
private final class PiperAutomaticSpeaker: NSObject, AVAudioPlayerDelegate {
  struct SpeechLine {
    let speakerType: PiperSpeakerType
    let text: String
  }

  struct PlaybackRequest {
    let line: SpeechLine
  }

  private static let logger = Logger(subsystem: "ARChess", category: "PiperAutomaticSpeaker")

  private let ttsService: PiperTTSService
  private var currentTask: Task<Void, Never>?
  private var audioPlayer: AVAudioPlayer?
  private var currentRequest: PlaybackRequest?
  private var isPreparing = false
  private var isAudioPlaying = false

  var onBusyStateChange: ((Bool) -> Void)?
  var onPlaybackActivityChange: ((PlaybackRequest?, Bool) -> Void)?
  var onVoicePrepared: ((PlaybackRequest, PiperPreparedLine) -> Void)?
  var onLineFailure: ((PlaybackRequest, String) -> Void)?

  init(ttsService: PiperTTSService = PiperTTSService()) {
    self.ttsService = ttsService
    super.init()
  }

  var isConfigured: Bool {
    ttsService.isConfigured
  }

  var isBusy: Bool {
    isPreparing || isAudioPlaying
  }

  func prepareIfNeeded() {
    ttsService.prepareCacheIfNeeded()
  }

  func speakLine(_ line: SpeechLine) -> Bool {
    let trimmedText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty, !isBusy else {
      return false
    }

    currentRequest = PlaybackRequest(
      line: SpeechLine(
        speakerType: line.speakerType,
        text: trimmedText
      )
    )
    isPreparing = true
    notifyBusyStateChange()

    currentTask = Task { @MainActor [weak self] in
      await self?.synthesizeAndPlayCurrentRequest()
    }
    return true
  }

  func stop() {
    currentTask?.cancel()
    currentTask = nil
    let stoppedRequest = currentRequest
    currentRequest = nil
    isPreparing = false
    audioPlayer?.stop()
    audioPlayer = nil

    if isAudioPlaying {
      AmbientMusicController.shared.setSpeechActive(false)
      onPlaybackActivityChange?(stoppedRequest, false)
    }
    isAudioPlaying = false
    notifyBusyStateChange()
  }

  private func synthesizeAndPlayCurrentRequest() async {
    guard let request = currentRequest else {
      currentTask = nil
      isPreparing = false
      notifyBusyStateChange()
      return
    }

    do {
      let preparedLine = try await ttsService.synthesizeLine(
        speakerType: request.line.speakerType,
        text: request.line.text
      )
      guard !Task.isCancelled else {
        currentTask = nil
        isPreparing = false
        notifyBusyStateChange()
        return
      }

      try AudioSessionCoordinator.shared.activatePlaybackSession()
      let player = try AVAudioPlayer(contentsOf: preparedLine.localFileURL)
      player.delegate = self
      player.prepareToPlay()
      audioPlayer = player
      onVoicePrepared?(request, preparedLine)
      isPreparing = false
      currentTask = nil

      guard player.play() else {
        throw NSError(
          domain: "ARChess.PiperTTS",
          code: -2006,
          userInfo: [NSLocalizedDescriptionKey: "Piper audio player could not start playback."]
        )
      }

      isAudioPlaying = true
      AmbientMusicController.shared.setSpeechActive(true)
      onPlaybackActivityChange?(request, true)
      notifyBusyStateChange()
    } catch is CancellationError {
      currentTask = nil
      isPreparing = false
      notifyBusyStateChange()
    } catch {
      Self.logger.error("Piper automatic playback failed: \(error.localizedDescription, privacy: .public)")
      currentTask = nil
      isPreparing = false
      audioPlayer = nil
      let failedRequest = currentRequest
      currentRequest = nil
      if isAudioPlaying {
        AmbientMusicController.shared.setSpeechActive(false)
        onPlaybackActivityChange?(failedRequest, false)
      }
      isAudioPlaying = false
      if let failedRequest {
        onLineFailure?(failedRequest, error.localizedDescription)
      }
      notifyBusyStateChange()
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    finishPlayback(failureMessage: flag ? nil : "Piper audio playback ended unsuccessfully.")
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    finishPlayback(failureMessage: error?.localizedDescription ?? "Piper audio decode failed.")
  }

  private func finishPlayback(failureMessage: String?) {
    let finishedRequest = currentRequest
    audioPlayer = nil
    if isAudioPlaying {
      AmbientMusicController.shared.setSpeechActive(false)
      onPlaybackActivityChange?(finishedRequest, false)
    }
    isAudioPlaying = false
    currentRequest = nil

    if let failureMessage, let finishedRequest {
      onLineFailure?(finishedRequest, failureMessage)
    }
    notifyBusyStateChange()
  }

  private func notifyBusyStateChange() {
    onBusyStateChange?(isBusy)
  }
}

@MainActor
private final class PiperVoiceAuditionStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
  static let builtInSamples = [
    "The knight circles the king with elegant menace.",
    "Rook useless.",
    "Lots of time to read the good book back here.",
    "Advance again and I split your line.",
  ]

  private static let logger = Logger(subsystem: "ARChess", category: "PiperVoiceAudition")

  private let ttsService: PiperTTSService
  private var previewTask: Task<Void, Never>?
  private var audioPlayer: AVAudioPlayer?

  @Published private(set) var voices: [PiperVoiceInventoryEntryPayload] = []
  @Published private(set) var speakerAssignments: [PiperSpeakerType: String] = [:]
  @Published private(set) var statusText = "Load installed Piper voices."
  @Published private(set) var isLoadingVoices = false
  @Published private(set) var isPreviewing = false
  @Published private(set) var isAssigning = false
  @Published var selectedVoiceID: String?
  @Published var selectedSampleIndex = 0
  @Published var customText = ""
  @Published var autoPreviewOnVoiceChange = true

  init(ttsService: PiperTTSService = PiperTTSService()) {
    self.ttsService = ttsService
    super.init()
    self.ttsService.prepareCacheIfNeeded()
  }

  var selectedVoice: PiperVoiceInventoryEntryPayload? {
    voices.first(where: { $0.voice_id == selectedVoiceID })
  }

  var selectedSampleText: String {
    let safeIndex = min(max(0, selectedSampleIndex), Self.builtInSamples.count - 1)
    return Self.builtInSamples[safeIndex]
  }

  var trimmedCustomText: String {
    customText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasConfiguredAPIBaseURL: Bool {
    ttsService.isConfigured
  }

  func loadIfNeeded() async {
    guard voices.isEmpty, !isLoadingVoices else {
      return
    }
    await refreshVoices()
  }

  func refreshVoices(keeping preferredVoiceID: String? = nil) async {
    guard !isLoadingVoices else {
      return
    }

    isLoadingVoices = true
    statusText = "Refreshing installed Piper voices..."
    defer { isLoadingVoices = false }

    do {
      let inventory = try await ttsService.fetchAvailableVoices()
      voices = inventory.voices
      speakerAssignments = Dictionary(
        uniqueKeysWithValues: inventory.speaker_assignments.compactMap { key, value in
          guard let speakerType = PiperSpeakerType(rawValue: key), let value else {
            return nil
          }
          return (speakerType, value)
        }
      )

      if let preferredVoiceID,
         voices.contains(where: { $0.voice_id == preferredVoiceID }) {
        selectedVoiceID = preferredVoiceID
      } else if let selectedVoiceID,
                voices.contains(where: { $0.voice_id == selectedVoiceID }) {
        self.selectedVoiceID = selectedVoiceID
      } else {
        selectedVoiceID = voices.first?.voice_id
      }

      if let selectedVoice {
        statusText = "Ready to audition \(selectedVoice.displayName)."
      } else if voices.isEmpty {
        statusText = "No installed Piper voices found on the current backend."
      } else {
        statusText = "Select a Piper voice to preview."
      }
    } catch {
      voices = []
      speakerAssignments = [:]
      selectedVoiceID = nil
      statusText = "Piper voice inventory failed: \(error.localizedDescription)"
    }
  }

  func selectVoice(_ voiceID: String, autoplay: Bool) {
    guard selectedVoiceID != voiceID else {
      return
    }
    selectedVoiceID = voiceID
    if let selectedVoice {
      statusText = "Selected \(selectedVoice.displayName)."
    }
    if autoplay && autoPreviewOnVoiceChange {
      previewSelectedSample()
    }
  }

  func selectNextVoice() {
    guard !voices.isEmpty else {
      return
    }
    let currentIndex = voices.firstIndex(where: { $0.voice_id == selectedVoiceID }) ?? 0
    let nextIndex = min(currentIndex + 1, voices.count - 1)
    selectVoice(voices[nextIndex].voice_id, autoplay: true)
  }

  func selectPreviousVoice() {
    guard !voices.isEmpty else {
      return
    }
    let currentIndex = voices.firstIndex(where: { $0.voice_id == selectedVoiceID }) ?? 0
    let previousIndex = max(currentIndex - 1, 0)
    selectVoice(voices[previousIndex].voice_id, autoplay: true)
  }

  func previewSelectedSample() {
    preview(text: selectedSampleText, label: "sample")
  }

  func previewCustomText() {
    preview(text: trimmedCustomText, label: "custom")
  }

  func assignSelectedVoice(to speakerType: PiperSpeakerType) async {
    guard !speakerType.usesGeminiLiveNarrator else {
      statusText = "Narrator stays on Gemini Live."
      return
    }
    guard let selectedVoice else {
      statusText = "Select a Piper voice before assigning it."
      return
    }
    guard !isAssigning else {
      return
    }

    isAssigning = true
    statusText = "Assigning \(selectedVoice.displayName) to \(speakerType.displayName)..."
    defer { isAssigning = false }

    do {
      let response = try await ttsService.assignVoice(selectedVoice.voice_id, to: speakerType)
      if let assignedVoiceID = response.assigned_voice_id {
        speakerAssignments[speakerType] = assignedVoiceID
      } else {
        speakerAssignments.removeValue(forKey: speakerType)
      }
      statusText = "\(speakerType.displayName) now uses \(selectedVoice.displayName)."
      await refreshVoices(keeping: selectedVoice.voice_id)
    } catch {
      statusText = "Piper assignment failed: \(error.localizedDescription)"
    }
  }

  func stop() {
    previewTask?.cancel()
    previewTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    if isPreviewing {
      AmbientMusicController.shared.setSpeechActive(false)
    }
    isPreviewing = false
  }

  func assignmentLabel(for speakerType: PiperSpeakerType) -> String {
    if speakerType.usesGeminiLiveNarrator {
      return "Gemini Live narrator"
    }
    guard let assignedVoiceID = speakerAssignments[speakerType] else {
      return "Unassigned"
    }
    if let voice = voices.first(where: { $0.voice_id == assignedVoiceID }) {
      return voice.displayName
    }
    return "Missing voice"
  }

  private func preview(text: String, label: String) {
    guard let selectedVoice else {
      statusText = "Select a Piper voice before previewing."
      return
    }

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      statusText = "Enter a short line to preview."
      return
    }

    stop()
    statusText = "Preparing \(label) preview for \(selectedVoice.displayName)..."

    previewTask = Task { @MainActor [weak self] in
      await self?.runPreview(voice: selectedVoice, text: trimmedText)
    }
  }

  private func runPreview(
    voice: PiperVoiceInventoryEntryPayload,
    text: String
  ) async {
    do {
      let preparedLine = try await ttsService.synthesizeAuditionLine(
        voiceID: voice.voice_id,
        text: text
      )
      guard !Task.isCancelled else {
        return
      }

      try AudioSessionCoordinator.shared.activatePlaybackSession()
      let player = try AVAudioPlayer(contentsOf: preparedLine.localFileURL)
      player.delegate = self
      player.prepareToPlay()
      audioPlayer = player

      guard player.play() else {
        throw NSError(
          domain: "ARChess.PiperTTS",
          code: -2011,
          userInfo: [NSLocalizedDescriptionKey: "Piper audition audio could not start playback."]
        )
      }

      previewTask = nil
      isPreviewing = true
      AmbientMusicController.shared.setSpeechActive(true)
      statusText = preparedLine.cacheHit
        ? "Previewing \(voice.displayName) from cache."
        : "Previewing \(voice.displayName) with fresh synthesis."
    } catch is CancellationError {
      previewTask = nil
      statusText = "Preview cancelled."
    } catch {
      Self.logger.error("Piper audition playback failed: \(error.localizedDescription, privacy: .public)")
      previewTask = nil
      audioPlayer = nil
      if isPreviewing {
        AmbientMusicController.shared.setSpeechActive(false)
      }
      isPreviewing = false
      statusText = "Piper audition failed: \(error.localizedDescription)"
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    previewTask = nil
    audioPlayer = nil
    if isPreviewing {
      AmbientMusicController.shared.setSpeechActive(false)
    }
    isPreviewing = false
    if !flag {
      statusText = "Preview ended unexpectedly."
    }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    previewTask = nil
    audioPlayer = nil
    if isPreviewing {
      AmbientMusicController.shared.setSpeechActive(false)
    }
    isPreviewing = false
    statusText = error?.localizedDescription ?? "Preview audio decode failed."
  }
}

private final class GeminiHintService {
  private static let logger = Logger(subsystem: "ARChess", category: "GeminiHint")
  private static let pieceVoiceTimeoutSeconds: TimeInterval = 2.4

  private let apiBaseURL: URL?
  private let session: URLSession

  init(
    apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL,
    session: URLSession = .shared
  ) {
    self.apiBaseURL = apiBaseURL
    self.session = session
  }

  var isConfigured: Bool {
    apiBaseURL != nil
  }

  func fetchHint(for context: GeminiHintContext) async throws -> String {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1001,
        userInfo: [NSLocalizedDescriptionKey: "Gemini hints are disabled until ARChessAPIBaseURL is configured."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("gemini")
        .appendingPathComponent("hint")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 8.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      GeminiHintRequestPayload(
        fen: context.fen,
        recent_history: context.recentHistory,
        best_move: context.bestMove,
        side_to_move: context.sideToMove.displayName.lowercased(),
        narrator: context.narrator.rawValue,
        moving_piece: context.movingPiece?.displayName.lowercased(),
        is_capture: context.isCapture,
        gives_check: context.givesCheck,
        themes: context.themes
      )
    )

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1003,
        userInfo: [NSLocalizedDescriptionKey: "Gemini did not return an HTTP response."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Gemini response."
      Self.logger.error("Gemini backend hint request failed status=\(httpResponse.statusCode, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let payload = try JSONDecoder().decode(GeminiHintResponsePayload.self, from: data)
    let rawText = payload.hint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawText.isEmpty else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1004,
        userInfo: [NSLocalizedDescriptionKey: "Gemini backend returned no hint text."]
      )
    }

    let sanitized = sanitize(rawText, fallback: fallbackHint(for: context))
    Self.logger.info("Gemini hint ready via backend duration_ms=\(durationMs, privacy: .public)")
    return sanitized
  }

  func fetchConnectionStatus() async throws -> GeminiLiveStatusPayload {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1005,
        userInfo: [NSLocalizedDescriptionKey: "Gemini hints are disabled until ARChessAPIBaseURL is configured."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("gemini")
        .appendingPathComponent("status")
    )
    request.httpMethod = "GET"
    request.timeoutInterval = 3.0
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1006,
        userInfo: [NSLocalizedDescriptionKey: "Gemini status endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Gemini status response."
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    return try JSONDecoder().decode(GeminiLiveStatusPayload.self, from: data)
  }

  func fetchCoachCommentary(for context: GeminiCoachCommentaryContext) async throws -> GeminiCoachCommentary {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1007,
        userInfo: [NSLocalizedDescriptionKey: "Gemini commentary is disabled until ARChessAPIBaseURL is configured."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("gemini")
        .appendingPathComponent("commentary")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 8.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      GeminiCoachCommentaryRequestPayload(
        fen: context.fen,
        narrator: context.narrator.rawValue
      )
    )

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1008,
        userInfo: [NSLocalizedDescriptionKey: "Gemini commentary endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Gemini commentary response."
      Self.logger.error("Gemini backend commentary request failed status=\(httpResponse.statusCode, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let decoder = JSONDecoder()
    let payload = try decoder.decode(GeminiCoachCommentary.self, from: data)
    Self.logger.info("Gemini coach commentary ready via backend duration_ms=\(durationMs, privacy: .public)")
    return payload
  }

  func fetchPieceVoiceLine(for context: GeminiPieceVoiceLineContext) async throws -> String {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1009,
        userInfo: [NSLocalizedDescriptionKey: "Gemini piece voice lines are disabled until ARChessAPIBaseURL is configured."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("gemini")
        .appendingPathComponent("piece-voice-line")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = Self.pieceVoiceTimeoutSeconds
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      GeminiPieceVoiceLineRequestPayload(
        fen: context.fen,
        piece_type: context.pieceType.displayName.lowercased(),
        piece_color: context.pieceColor.displayName.lowercased(),
        recent_lines: context.recentLines,
        dialogue_mode: context.dialogueMode.rawValue,
        piece_dialogue_history: context.pieceDialogueHistory,
        latest_piece_line: context.latestPieceLine,
        context_mode: context.contextMode.rawValue,
        from_square: context.fromSquare.algebraic,
        to_square: context.toSquare.algebraic,
        is_capture: context.isCapture,
        is_check: context.isCheck,
        is_near_enemy_king: context.isNearEnemyKing,
        is_attacked: context.isAttacked,
        is_attacked_by_multiple: context.isAttackedByMultiple,
        is_defended: context.isDefended,
        is_well_defended: context.isWellDefended,
        is_hanging: context.isHanging,
        is_pinned: context.isPinned,
        is_retreat: context.isRetreat,
        is_aggressive_advance: context.isAggressiveAdvance,
        is_fork_threat: context.isForkThreat,
        attacker_count: context.attackerCount,
        defender_count: context.defenderCount,
        eval_before: context.evalBefore,
        eval_after: context.evalAfter,
        eval_delta: context.evalDelta,
        position_state: context.positionState.rawValue,
        move_quality: context.moveQuality.rawValue,
        piece_move_count: context.pieceMoveCount,
        underutilized_reason: context.underutilizedReason
      )
    )

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1010,
        userInfo: [NSLocalizedDescriptionKey: "Gemini piece voice endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Gemini piece voice response."
      Self.logger.error("Gemini backend piece voice request failed status=\(httpResponse.statusCode, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let payload = try JSONDecoder().decode(GeminiPieceVoiceLineResponsePayload.self, from: data)
    let line = payload.line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1011,
        userInfo: [NSLocalizedDescriptionKey: "Gemini backend returned no piece voice line."]
      )
    }

    Self.logger.info("Gemini piece voice ready via backend duration_ms=\(durationMs, privacy: .public)")
    return line
  }

  func fetchPassiveNarratorLine(for context: GeminiPassiveNarratorLineContext) async throws -> String {
    guard let baseURL = apiBaseURL else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1012,
        userInfo: [NSLocalizedDescriptionKey: "Gemini passive narrator is disabled until ARChessAPIBaseURL is configured."]
      )
    }

    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("gemini")
        .appendingPathComponent("passive-commentary-line")
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 6.0
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      GeminiPassiveNarratorLineRequestPayload(
        fen: context.fen,
        recent_history: context.recentHistory,
        recent_lines: context.recentLines,
        dialogue_mode: context.dialogueMode.rawValue,
        latest_piece_line: context.latestPieceLine,
        phase: context.phase.rawValue,
        turns_since_last_narrator_line: context.turnsSinceLastNarratorLine,
        move_san: context.moveSAN,
        moving_piece: context.movingPiece?.displayName.lowercased(),
        moving_color: context.movingColor?.displayName.lowercased(),
        from_square: context.fromSquare?.algebraic,
        to_square: context.toSquare?.algebraic,
        is_capture: context.isCapture,
        is_check: context.isCheck,
        is_checkmate: context.isCheckmate,
        is_near_enemy_king: context.isNearEnemyKing,
        is_attacked: context.isAttacked,
        is_pinned: context.isPinned,
        is_retreat: context.isRetreat,
        is_aggressive_advance: context.isAggressiveAdvance,
        is_fork_threat: context.isForkThreat,
        attacker_count: context.attackerCount,
        defender_count: context.defenderCount,
        eval_before: context.evalBefore,
        eval_after: context.evalAfter,
        eval_delta: context.evalDelta,
        position_state: context.positionState?.rawValue,
        move_quality: context.moveQuality?.rawValue
      )
    )

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1013,
        userInfo: [NSLocalizedDescriptionKey: "Gemini passive narrator endpoint did not return HTTP."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected Gemini passive narrator response."
      Self.logger.error("Gemini backend passive narrator request failed status=\(httpResponse.statusCode, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let payload = try JSONDecoder().decode(GeminiPassiveNarratorLineResponsePayload.self, from: data)
    let line = payload.line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else {
      throw NSError(
        domain: "ARChess.GeminiHint",
        code: -1014,
        userInfo: [NSLocalizedDescriptionKey: "Gemini backend returned no passive narrator line."]
      )
    }

    Self.logger.info("Gemini passive narrator ready via backend duration_ms=\(durationMs, privacy: .public)")
    return line
  }

  private func sanitize(_ raw: String, fallback: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let movePattern = #"\b[a-h][1-8][a-h][1-8][qrbn]?\b|\b[a-h][1-8]\b"#

    guard trimmed.range(of: movePattern, options: .regularExpression) == nil else {
      return fallback
    }

    let condensed = trimmed.replacingOccurrences(
      of: #"\s+"#,
      with: " ",
      options: .regularExpression
    )
    let final = condensed.trimmingCharacters(in: .whitespacesAndNewlines)
    return final.isEmpty ? fallback : final
  }

  private func fallbackHint(for context: GeminiHintContext) -> String {
    if context.givesCheck {
      return "The enemy king looks a little exposed."
    }

    if context.themes.contains("fight for the center") {
      switch context.movingPiece {
      case .knight:
        return "Your knight dreams of the center."
      case .pawn:
        return "A brave pawn wants to claim more space."
      default:
        return "This move helps seize the center."
      }
    }

    if context.themes.contains("develop a new piece") {
      return "A sleepy piece is ready to join the adventure."
    }

    if context.isCapture {
      return "A clean trade could swing the momentum."
    }

    if context.themes.contains("improve king safety") {
      return "Your king would sleep better after this."
    }

    return "There is a tidy move that improves your position."
  }
}

private struct RemoteGameResponse: Decodable {
  let game_id: String
}

private struct RemoteMoveRequest: Encodable {
  let ply: Int
  let move_uci: String
}

private struct QueueTicketRequest: Encodable {
  let player_id: String
}

private struct QueueMatchMoveRequestPayload: Encodable {
  let player_id: String
  let ply: Int
  let move_uci: String
}

private struct QueueTicketPayload: Decodable {
  let ticket_id: String
  let player_id: String
  let status: String
  let match_id: String?
  let assigned_color: String?
  let heartbeat_at: String
  let expires_at: String
  let poll_after_ms: Int
}

private struct QueueMatchMovePayload: Decodable, Equatable {
  let match_id: String
  let game_id: String
  let ply: Int
  let move_uci: String
  let player_id: String
  let created_at: String
}

private struct QueueMatchStatePayload: Decodable {
  let match_id: String
  let game_id: String
  let status: String
  let white_player_id: String
  let black_player_id: String
  let your_color: String?
  let latest_ply: Int
  let next_turn: String
  let moves: [QueueMatchMovePayload]
}

private struct QueueMatchMovesPayload: Decodable {
  let match_id: String
  let game_id: String
  let latest_ply: Int
  let next_turn: String
  let moves: [QueueMatchMovePayload]
}

private struct QueueConflictDetail: Decodable {
  let message: String
  let current_state: QueueMatchStatePayload
}

private struct QueueConflictEnvelope: Decodable {
  let detail: QueueConflictDetail
}

private enum QueueMatchViewState: String {
  case idle
  case waiting
  case matched
  case reconnecting
  case syncError
  case cancelled
}

private enum QueueMatchStoreError: LocalizedError {
  case missingAPIBaseURL
  case invalidURL
  case serverError(String)
  case conflict(String, QueueMatchStatePayload)
  case invalidMatchState(String)
  case notYourTurn
  case duplicateMove

  var errorDescription: String? {
    switch self {
    case .missingAPIBaseURL:
      return "Queue Match requires ARChessAPIBaseURL so this device can reach the backend."
    case .invalidURL:
      return "Queue Match could not build a valid backend URL."
    case .serverError(let message):
      return message
    case .conflict(let message, _):
      return message
    case .invalidMatchState(let message):
      return message
    case .notYourTurn:
      return "It is not your turn."
    case .duplicateMove:
      return "This move is already pending or already recorded."
    }
  }
}

@MainActor
private final class MatchLogStore: ObservableObject {
  struct Entry: Identifiable {
    let id = UUID()
    let ply: Int
    let color: ChessColor
    let moveUCI: String
    var isSynced = false
    var syncError: String?

    var label: String {
      let moveNumber = (ply + 1) / 2
      switch color {
      case .white:
        return "\(moveNumber). \(moveUCI)"
      case .black:
        return "\(moveNumber)... \(moveUCI)"
      }
    }

    var statusLabel: String {
      if isSynced {
        return "saved"
      }

      if syncError != nil {
        return "retrying"
      }

      return "pending"
    }
  }

  @Published private(set) var entries: [Entry] = []
  @Published private(set) var syncStatus = "Moves stay local until ARChessAPIBaseURL is set."
  @Published private(set) var remoteGameID: String?

  private let apiBaseURL: URL?
  private var remoteSyncEnabled = true

  init(apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL) {
    self.apiBaseURL = apiBaseURL
  }

  func configureRemoteSync(enabled: Bool, disabledReason: String? = nil) {
    remoteSyncEnabled = enabled

    guard enabled else {
      remoteGameID = nil
      syncStatus = disabledReason ?? "Moves are logging locally only."
      return
    }

    if let remoteGameID {
      syncStatus = "Connected to Railway game log \(remoteGameID.prefix(8))."
    } else {
      syncStatus = "Moves stay local until ARChessAPIBaseURL is set."
    }
  }

  func prepareRemoteGameIfNeeded() async {
    guard remoteSyncEnabled else {
      return
    }

    guard remoteGameID == nil else {
      return
    }

    guard let apiBaseURL else {
      syncStatus = "Moves are logging locally only. Set ARChessAPIBaseURL to sync to Railway."
      return
    }

    do {
      let game = try await createRemoteGame(baseURL: apiBaseURL)
      remoteGameID = game.game_id
      syncStatus = "Connected to Railway game log \(game.game_id.prefix(8))."
    } catch {
      syncStatus = "Railway sync unavailable: \(error.localizedDescription)"
    }
  }

  func recordMove(_ moveUCI: String, color: ChessColor) {
    let entry = Entry(ply: entries.count + 1, color: color, moveUCI: moveUCI)
    entries.append(entry)

    guard remoteSyncEnabled else {
      return
    }

    Task {
      await persistEntry(withID: entry.id)
    }
  }

  func resetSession() {
    entries = []
    remoteGameID = nil
    remoteSyncEnabled = true
    syncStatus = "Moves stay local until ARChessAPIBaseURL is set."
  }

  private func persistEntry(withID entryID: UUID) async {
    guard remoteSyncEnabled else {
      return
    }

    guard let entryIndex = entries.firstIndex(where: { $0.id == entryID }) else {
      return
    }

    guard let apiBaseURL else {
      return
    }

    await prepareRemoteGameIfNeeded()

    guard let remoteGameID else {
      entries[entryIndex].syncError = "No remote game ID"
      return
    }

    do {
      try await saveMove(
        baseURL: apiBaseURL,
        gameID: remoteGameID,
        entry: entries[entryIndex]
      )
      entries[entryIndex].isSynced = true
      entries[entryIndex].syncError = nil
      syncStatus = "Saved \(entries[entryIndex].moveUCI) to Railway and Postgres."
    } catch {
      entries[entryIndex].syncError = error.localizedDescription
      syncStatus = "Move log sync failed: \(error.localizedDescription)"
    }
  }

  private func createRemoteGame(baseURL: URL) async throws -> RemoteGameResponse {
    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("games")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data)
    return try JSONDecoder().decode(RemoteGameResponse.self, from: data)
  }

  private func saveMove(baseURL: URL, gameID: String, entry: Entry) async throws {
    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("games")
        .appendingPathComponent(gameID)
        .appendingPathComponent("moves")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      RemoteMoveRequest(ply: entry.ply, move_uci: entry.moveUCI)
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data)
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(
        domain: "ARChess",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Missing HTTP response from move log server."]
      )
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unexpected server response."
      throw NSError(
        domain: "ARChess",
        code: httpResponse.statusCode,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }
}

@MainActor
private final class QueueMatchStore: ObservableObject {
  @Published private(set) var state: QueueMatchViewState = .idle
  @Published private(set) var statusText = "Queue Match syncs through Railway."
  @Published private(set) var logEntries: [MatchLogStore.Entry] = []
  @Published private(set) var remoteGameID: String?
  @Published private(set) var matchID: String?
  @Published private(set) var assignedColor: ChessColor?
  @Published private(set) var nextTurn: ChessColor = .white
  @Published private(set) var latestPly = 0

  let playerID: UUID

  private let apiBaseURL: URL?
  private var ticketID: UUID?
  private var heartbeatTask: Task<Void, Never>?
  private var ticketPollTask: Task<Void, Never>?
  private var movePollTask: Task<Void, Never>?
  private var knownMoves: [QueueMatchMovePayload] = []
  private var pendingSubmittedPlies: Set<Int> = []
  private var boardSyncHandler: (([QueueMatchMovePayload]) -> Void)?

  init(apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL) {
    self.apiBaseURL = apiBaseURL

    let defaultsKey = "ARChessDevicePlayerID"
    if let raw = UserDefaults.standard.string(forKey: defaultsKey),
       let stored = UUID(uuidString: raw) {
      playerID = stored
    } else {
      let generated = UUID()
      UserDefaults.standard.set(generated.uuidString, forKey: defaultsKey)
      playerID = generated
    }

    if apiBaseURL == nil {
      state = .syncError
      statusText = "Queue Match requires ARChessAPIBaseURL before this device can join."
    }
  }

  var canOpenExperience: Bool {
    state == .matched && matchID != nil
  }

  var canSubmitMove: Bool {
    guard state == .matched, let assignedColor else {
      return false
    }

    return assignedColor == nextTurn
  }

  var playerIDLabel: String {
    playerID.uuidString
  }

  func bindBoardSync(_ handler: @escaping ([QueueMatchMovePayload]) -> Void) {
    boardSyncHandler = handler
    handler(knownMoves.sorted(by: { $0.ply < $1.ply }))
  }

  func unbindBoardSync() {
    boardSyncHandler = nil
  }

  func joinQueue() async {
    guard let apiBaseURL else {
      state = .syncError
      statusText = QueueMatchStoreError.missingAPIBaseURL.localizedDescription
      return
    }

    cancelAllTasks()
    clearMatchStateForFreshQueue()
    state = .waiting
    statusText = "Joining queue as \(playerID.uuidString.prefix(8))..."

    do {
      let payload: QueueTicketPayload = try await requestJSON(
        method: "POST",
        pathComponents: ["v1", "matchmaking", "enqueue"],
        requestBody: QueueTicketRequest(player_id: playerID.uuidString),
        apiBaseURL: apiBaseURL
      )
      await applyTicket(payload)
      if state == .waiting {
        startWaitingLoops()
      }
    } catch {
      state = .syncError
      statusText = "Queue join failed: \(error.localizedDescription)"
    }
  }

  func activateMatchSync() async {
    guard let apiBaseURL else {
      state = .syncError
      statusText = QueueMatchStoreError.missingAPIBaseURL.localizedDescription
      return
    }

    guard let matchID else {
      state = .syncError
      statusText = "Queue Match has no active match to sync."
      return
    }

    do {
      let statePayload: QueueMatchStatePayload = try await requestJSON(
        method: "GET",
        pathComponents: ["v1", "matches", matchID, "state"],
        queryItems: [URLQueryItem(name: "player_id", value: playerID.uuidString)],
        apiBaseURL: apiBaseURL
      )
      applyMatchState(statePayload, reconnecting: false)
      startMovePollingLoop()
    } catch {
      self.state = .reconnecting
      statusText = "Reconnecting to match: \(error.localizedDescription)"
      startMovePollingLoop()
    }
  }

  func stopRealtimeSync() {
    movePollTask?.cancel()
    movePollTask = nil
    boardSyncHandler = nil
  }

  func exitQueueFlow() async {
    if state == .waiting {
      await cancelQueue()
      return
    }

    cancelAllTasks()
    if state == .matched {
      statusText = "Match paused. Reopen Queue Match to reconnect."
    }
  }

  func cancelQueue() async {
    defer {
      cancelAllTasks()
      ticketID = nil
      if state != .matched {
        state = .cancelled
      }
      statusText = "Queue cancelled."
      logEntries = []
      remoteGameID = nil
      matchID = nil
      assignedColor = nil
      latestPly = 0
      nextTurn = .white
      knownMoves = []
      pendingSubmittedPlies.removeAll()
      boardSyncHandler?([])
    }

    guard let apiBaseURL,
          let ticketID,
          state == .waiting || state == .reconnecting else {
      return
    }

    var request = URLRequest(
      url: makeURL(
        apiBaseURL: apiBaseURL,
        pathComponents: ["v1", "matchmaking", ticketID.uuidString],
        queryItems: [URLQueryItem(name: "player_id", value: playerID.uuidString)]
      )
    )
    request.httpMethod = "DELETE"
    _ = try? await send(request, retries: 1)
  }

  func submitMove(moveUCI: String, ply: Int) async throws {
    guard let apiBaseURL else {
      throw QueueMatchStoreError.missingAPIBaseURL
    }
    guard let matchID else {
      throw QueueMatchStoreError.invalidMatchState("Queue Match has no server match ID.")
    }
    guard canSubmitMove else {
      throw QueueMatchStoreError.notYourTurn
    }
    guard !pendingSubmittedPlies.contains(ply), !knownMoves.contains(where: { $0.ply == ply }) else {
      throw QueueMatchStoreError.duplicateMove
    }

    pendingSubmittedPlies.insert(ply)
    statusText = "Submitting \(moveUCI)..."
    defer { pendingSubmittedPlies.remove(ply) }

    let requestBody = QueueMatchMoveRequestPayload(
      player_id: playerID.uuidString,
      ply: ply,
      move_uci: moveUCI
    )
    let request = try makeRequest(
      method: "POST",
      pathComponents: ["v1", "matches", matchID, "moves"],
      requestBody: requestBody,
      apiBaseURL: apiBaseURL
    )

    let (data, response) = try await send(request, retries: 2)
    if response.statusCode == 409 {
      let envelope = try decode(QueueConflictEnvelope.self, from: data)
      applyMatchState(envelope.detail.current_state, reconnecting: false)
      throw QueueMatchStoreError.conflict(envelope.detail.message, envelope.detail.current_state)
    }

    guard (200..<300).contains(response.statusCode) else {
      throw QueueMatchStoreError.serverError(errorMessage(from: data, response: response))
    }

    let move = try decode(QueueMatchMovePayload.self, from: data)
    mergeMoves([move], replaceKnownMoves: false)
    self.state = .matched
    statusText = "Move \(move.move_uci) synced. Waiting for \(nextTurn.displayName)."
  }

  private func clearMatchStateForFreshQueue() {
    remoteGameID = nil
    matchID = nil
    assignedColor = nil
    latestPly = 0
    nextTurn = .white
    logEntries = []
    knownMoves = []
    pendingSubmittedPlies.removeAll()
    boardSyncHandler?([])
  }

  private func startWaitingLoops() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 10_000_000_000)
          guard !Task.isCancelled, let ticketID else {
            return
          }

          let payload: QueueTicketPayload = try await requestJSON(
            method: "POST",
            pathComponents: ["v1", "matchmaking", ticketID.uuidString, "heartbeat"],
            requestBody: QueueTicketRequest(player_id: playerID.uuidString),
            apiBaseURL: self.apiBaseURL
          )
          await applyTicket(payload)
        } catch {
          if Task.isCancelled {
            return
          }

          await MainActor.run {
            self.state = .reconnecting
            self.statusText = "Queue heartbeat retrying: \(error.localizedDescription)"
          }
        }
      }
    }

    ticketPollTask?.cancel()
    ticketPollTask = Task { [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          guard let ticketID else {
            return
          }

          let payload: QueueTicketPayload = try await requestJSON(
            method: "GET",
            pathComponents: ["v1", "matchmaking", ticketID.uuidString],
            queryItems: [URLQueryItem(name: "player_id", value: playerID.uuidString)],
            apiBaseURL: self.apiBaseURL
          )
          attempt = 0
          await applyTicket(payload)
          if self.state == .matched {
            return
          }
          try await Task.sleep(nanoseconds: UInt64(max(1, payload.poll_after_ms)) * 1_000_000)
        } catch {
          if Task.isCancelled {
            return
          }

          attempt += 1
          await MainActor.run {
            self.state = .reconnecting
            self.statusText = "Queue poll retrying: \(error.localizedDescription)"
          }
          try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
        }
      }
    }
  }

  private func startMovePollingLoop() {
    movePollTask?.cancel()
    movePollTask = Task { [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          guard let matchID else {
            return
          }

          let payload: QueueMatchMovesPayload = try await requestJSON(
            method: "GET",
            pathComponents: ["v1", "matches", matchID, "moves"],
            queryItems: [
              URLQueryItem(name: "after_ply", value: String(self.latestPly)),
              URLQueryItem(name: "player_id", value: playerID.uuidString),
            ],
            apiBaseURL: self.apiBaseURL
          )
          attempt = 0
          await MainActor.run {
            self.state = .matched
            self.nextTurn = ChessColor(serverValue: payload.next_turn) ?? self.nextTurn
            self.latestPly = max(self.latestPly, payload.latest_ply)
            self.remoteGameID = payload.game_id
            self.matchID = payload.match_id
          }
          if !payload.moves.isEmpty {
            await MainActor.run {
              self.mergeMoves(payload.moves, replaceKnownMoves: false)
            }
          }
          try await Task.sleep(nanoseconds: 900_000_000)
        } catch {
          if Task.isCancelled {
            return
          }

          attempt += 1
          await MainActor.run {
            self.state = .reconnecting
            self.statusText = "Match sync retrying: \(error.localizedDescription)"
          }
          try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
        }
      }
    }
  }

  private func applyTicket(_ ticket: QueueTicketPayload) async {
    ticketID = UUID(uuidString: ticket.ticket_id)

    switch ticket.status {
    case "queued":
      state = .waiting
      statusText = "Waiting in queue as \(playerID.uuidString.prefix(8))..."
    case "matched":
      state = .matched
      statusText = "Matched as \(ticket.assigned_color?.capitalized ?? "Unknown"). Opening synced board."
      cancelWaitingTasks()
      matchID = ticket.match_id
      assignedColor = ChessColor(serverValue: ticket.assigned_color)
    case "cancelled":
      state = .cancelled
      statusText = "Queue cancelled."
    default:
      state = .syncError
      statusText = "Unexpected ticket state: \(ticket.status)"
    }

    if ticket.status == "matched", ticket.match_id != nil {
      await activateMatchSync()
    }
  }

  private func applyMatchState(_ payload: QueueMatchStatePayload, reconnecting: Bool) {
    state = reconnecting ? .reconnecting : .matched
    matchID = payload.match_id
    remoteGameID = payload.game_id
    assignedColor = ChessColor(serverValue: payload.your_color)
    latestPly = payload.latest_ply
    nextTurn = ChessColor(serverValue: payload.next_turn) ?? nextTurn
    mergeMoves(payload.moves, replaceKnownMoves: true)

    if reconnecting {
      statusText = "Reconnected to match \(payload.match_id.prefix(8))."
      state = .matched
    } else {
      let colorLabel = assignedColor?.displayName ?? "Unknown"
      let turnLabel = nextTurn.displayName
      statusText = "Matched as \(colorLabel). \(turnLabel) to move."
    }
  }

  private func mergeMoves(_ incomingMoves: [QueueMatchMovePayload], replaceKnownMoves: Bool) {
    if replaceKnownMoves {
      knownMoves = incomingMoves.sorted(by: { $0.ply < $1.ply })
    } else {
      for move in incomingMoves {
        if let existingIndex = knownMoves.firstIndex(where: { $0.ply == move.ply }) {
          knownMoves[existingIndex] = move
        } else {
          knownMoves.append(move)
        }
      }
      knownMoves.sort(by: { $0.ply < $1.ply })
    }

    latestPly = knownMoves.last?.ply ?? latestPly
    nextTurn = ChessColor.turnColor(afterLatestPly: latestPly)
    remoteGameID = incomingMoves.last?.game_id ?? remoteGameID
    logEntries = knownMoves.map { move in
      MatchLogStore.Entry(
        ply: move.ply,
        color: ChessColor.turnColor(forPly: move.ply),
        moveUCI: move.move_uci,
        isSynced: true,
        syncError: nil
      )
    }
    boardSyncHandler?(knownMoves)
  }

  private func cancelAllTasks() {
    cancelWaitingTasks()
    movePollTask?.cancel()
    movePollTask = nil
  }

  private func cancelWaitingTasks() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    ticketPollTask?.cancel()
    ticketPollTask = nil
  }

  private func makeURL(
    apiBaseURL: URL,
    pathComponents: [String],
    queryItems: [URLQueryItem] = []
  ) -> URL {
    var url = apiBaseURL
    for component in pathComponents {
      url.appendPathComponent(component)
    }

    guard !queryItems.isEmpty else {
      return url
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = queryItems
    return components?.url ?? url
  }

  private func makeRequest<Body: Encodable>(
    method: String,
    pathComponents: [String],
    queryItems: [URLQueryItem] = [],
    requestBody: Body? = nil,
    apiBaseURL: URL?
  ) throws -> URLRequest {
    guard let apiBaseURL else {
      throw QueueMatchStoreError.missingAPIBaseURL
    }

    let url = makeURL(apiBaseURL: apiBaseURL, pathComponents: pathComponents, queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let requestBody {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(requestBody)
    }

    return request
  }

  private func makeRequest(
    method: String,
    pathComponents: [String],
    queryItems: [URLQueryItem] = [],
    apiBaseURL: URL?
  ) throws -> URLRequest {
    guard let apiBaseURL else {
      throw QueueMatchStoreError.missingAPIBaseURL
    }

    let url = makeURL(apiBaseURL: apiBaseURL, pathComponents: pathComponents, queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func requestJSON<T: Decodable, Body: Encodable>(
    method: String,
    pathComponents: [String],
    queryItems: [URLQueryItem] = [],
    requestBody: Body? = nil,
    apiBaseURL: URL?
  ) async throws -> T {
    let request = try makeRequest(
      method: method,
      pathComponents: pathComponents,
      queryItems: queryItems,
      requestBody: requestBody,
      apiBaseURL: apiBaseURL
    )
    let (data, response) = try await send(request, retries: 2)
    guard (200..<300).contains(response.statusCode) else {
      throw QueueMatchStoreError.serverError(errorMessage(from: data, response: response))
    }
    return try decode(T.self, from: data)
  }

  private func requestJSON<T: Decodable>(
    method: String,
    pathComponents: [String],
    queryItems: [URLQueryItem] = [],
    apiBaseURL: URL?
  ) async throws -> T {
    let request = try makeRequest(
      method: method,
      pathComponents: pathComponents,
      queryItems: queryItems,
      apiBaseURL: apiBaseURL
    )
    let (data, response) = try await send(request, retries: 2)
    guard (200..<300).contains(response.statusCode) else {
      throw QueueMatchStoreError.serverError(errorMessage(from: data, response: response))
    }
    return try decode(T.self, from: data)
  }

  private func send(_ request: URLRequest, retries: Int) async throws -> (Data, HTTPURLResponse) {
    var attempt = 0

    while true {
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
          throw QueueMatchStoreError.serverError("Missing HTTP response from queue service.")
        }

        if (500..<600).contains(httpResponse.statusCode), attempt < retries {
          attempt += 1
          state = .reconnecting
          statusText = "Queue reconnecting after server error \(httpResponse.statusCode)..."
          try await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
          continue
        }

        return (data, httpResponse)
      } catch {
        if attempt >= retries {
          throw error
        }

        attempt += 1
        state = .reconnecting
        statusText = "Queue reconnecting..."
        try await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
      }
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(type, from: data)
  }

  private func errorMessage(from data: Data, response: HTTPURLResponse) -> String {
    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw, !raw.isEmpty {
      return raw
    }

    return "Queue service returned HTTP \(response.statusCode)."
  }

  private func retryDelayNanoseconds(attempt: Int) -> UInt64 {
    let cappedAttempt = min(attempt, 5)
    let baseSeconds = pow(2.0, Double(cappedAttempt - 1)) * 0.6
    let jitterSeconds = Double.random(in: 0.0...0.35)
    return UInt64((baseSeconds + jitterSeconds) * 1_000_000_000)
  }
}

private extension URL {
  func deletingTrailingSlash() -> URL {
    let raw = absoluteString
    guard raw.hasSuffix("/") else {
      return self
    }

    return URL(string: String(raw.dropLast())) ?? self
  }
}

private enum StockfishAnalysisDefaults {
  static let multiPV = 5
  static let pvPreviewCount = 5
  static let confidenceGapWindowCp = 240
}

private struct StockfishAnalysis {
  let fen: String
  let sideToMove: ChessColor
  let requestID: String
  let durationMs: Int
  let scoreCp: Int?
  let mateIn: Int?
  let pv: [String]
  let bestMove: String?
  let rawCandidates: [StockfishCandidate]
  let topUniqueMoves: [StockfishCandidate]

  var candidates: [StockfishCandidate] {
    rawCandidates
  }

  var normalizedScore: Int {
    // Mate scores need a stable numeric ordering so review checkpoints can compare
    // and sort eval drops without special-casing every mate transition.
    if let mateIn {
      let magnitude = max(1, 100_000 - (abs(mateIn) * 1_000))
      return mateIn >= 0 ? magnitude : -magnitude
    }

    return scoreCp ?? 0
  }

  var whitePerspectiveScore: Int {
    sideToMove == .white ? normalizedScore : -normalizedScore
  }

  var blackPerspectiveScore: Int {
    -whitePerspectiveScore
  }

  func perspectiveScore(for color: ChessColor) -> Int {
    color == .white ? whitePerspectiveScore : blackPerspectiveScore
  }

  func formattedEval(for color: ChessColor) -> String {
    if let mateIn {
      let mateForWhite = sideToMove == .white ? mateIn : -mateIn
      let signedMate = color == .white ? mateForWhite : -mateForWhite
      return signedMate >= 0 ? "#\(signedMate)" : "-#\(abs(signedMate))"
    }

    let centipawns = color == .white ? whitePerspectiveScore : blackPerspectiveScore
    return String(format: "%+.2f", Double(centipawns) / 100.0)
  }
}

private struct StockfishCandidate {
  let rank: Int
  let move: String?
  let scoreCp: Int?
  let mateIn: Int?
  let depth: Int
  let pv: [String]
  let pvPreview: [String]
  let rootFrom: String?
  let rootTo: String?
  let confidence: Double

  init(
    rank: Int,
    move: String?,
    scoreCp: Int?,
    mateIn: Int?,
    depth: Int,
    pv: [String],
    confidence: Double = 1.0
  ) {
    let resolvedMove = move ?? pv.first
    self.rank = rank
    self.move = resolvedMove
    self.scoreCp = scoreCp
    self.mateIn = mateIn
    self.depth = depth
    self.pv = pv
    self.pvPreview = Array(pv.prefix(StockfishAnalysisDefaults.pvPreviewCount))
    self.rootFrom = resolvedMove.map { String($0.prefix(2)) }
    self.rootTo = resolvedMove.map { String($0.dropFirst(2).prefix(2)) }
    self.confidence = max(0.0, min(1.0, confidence))
  }

  var bestMove: String? {
    move
  }

  var formattedScore: String {
    if let mateIn {
      return mateIn >= 0 ? "#\(mateIn)" : "-#\(abs(mateIn))"
    }

    return String(format: "%+.2f", Double(scoreCp ?? 0) / 100.0)
  }

  var normalizedScore: Int {
    if let mateIn {
      let magnitude = max(1, 100_000 - (abs(mateIn) * 1_000))
      return mateIn >= 0 ? magnitude : -magnitude
    }

    return scoreCp ?? 0
  }
}

private struct CachedAnalysis {
  let fen: String
  let analysis: StockfishAnalysis
}

private struct FixedRingBuffer<Element> {
  private let capacity: Int
  private var storage: [Element] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  mutating func append(_ element: Element) {
    storage.append(element)
    let overflow = storage.count - capacity
    if overflow > 0 {
      storage.removeFirst(overflow)
    }
  }

  mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
  }

  var elements: [Element] {
    storage
  }
}

private enum StockfishControllerState: String {
  case initialize = "INIT"
  case sentUCI = "SENT_UCI"
  case waitingReady = "WAITING_READY"
  case ready = "READY"
  case thinking = "THINKING"
  case failed = "FAILED"
  case closed = "CLOSED"
}

private struct StockfishEngineConfig {
  var defaultMovetimeMs = 80
  var hardTimeoutMs = 600
  // Cold boot inside a WKWebView while ARKit is stabilizing is slower than a normal search
  // and should not share the same budget.
  var startupTimeoutMs = 6_000
  var readyTimeoutMs = 1_500
  var threads = 1
  var hashMB = 16
  var strictFENValidation = false
  var maxStartupRetries = 1
}

private struct StockfishSearchOptions {
  var movetimeMs: Int?
  var debugDepth: Int?
  var hardTimeoutMs: Int?
  var multiPV: Int?
  var searchMoves: [String]?

  static func realtime(
    movetimeMs: Int = 80,
    hardTimeoutMs: Int = 600,
    // Human-facing analysis wants multiple candidate choices, not only the best line.
    multiPV: Int = StockfishAnalysisDefaults.multiPV,
    searchMoves: [String]? = nil
  ) -> Self {
    StockfishSearchOptions(
      movetimeMs: movetimeMs,
      debugDepth: nil,
      hardTimeoutMs: hardTimeoutMs,
      multiPV: multiPV,
      searchMoves: searchMoves
    )
  }
}

private struct StockfishValidatedFEN {
  let fen: String
  let sideToMove: ChessColor
}

private enum StockfishFENValidationError: LocalizedError {
  case fieldCount
  case sideToMove(String)
  case castlingRights(String)
  case enPassant(String)
  case halfmove(String)
  case fullmove(String)
  case rankCount(Int)
  case invalidRankLength(rank: Int, sum: Int)
  case invalidPieceCharacter(Character)
  case invalidDigit(Character)
  case missingKings(white: Int, black: Int)
  case pawnOnBackRank(rank: Int)

  var errorDescription: String? {
    switch self {
    case .fieldCount:
      return "FEN must contain exactly 6 space-separated fields."
    case .sideToMove(let value):
      return "Invalid side-to-move field: \(value)"
    case .castlingRights(let value):
      return "Invalid castling rights field: \(value)"
    case .enPassant(let value):
      return "Invalid en-passant field: \(value)"
    case .halfmove(let value):
      return "Invalid halfmove clock: \(value)"
    case .fullmove(let value):
      return "Invalid fullmove number: \(value)"
    case .rankCount(let count):
      return "Piece placement must contain 8 ranks. Found \(count)."
    case .invalidRankLength(let rank, let sum):
      return "Rank \(rank) does not sum to 8 squares. Found \(sum)."
    case .invalidPieceCharacter(let character):
      return "Invalid FEN piece character: \(character)"
    case .invalidDigit(let character):
      return "Invalid FEN digit: \(character)"
    case .missingKings(let white, let black):
      return "FEN must contain exactly one white king and one black king. Found white=\(white), black=\(black)."
    case .pawnOnBackRank(let rank):
      return "Strict FEN validation rejects pawns on rank \(rank)."
    }
  }
}

private enum StockfishFENValidator {
  static func validate(_ fen: String, strict: Bool = false) throws -> StockfishValidatedFEN {
    let trimmed = fen.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 6 else {
      throw StockfishFENValidationError.fieldCount
    }

    let placement = fields[0]
    let sideField = fields[1]
    let castling = fields[2]
    let enPassant = fields[3]
    let halfmove = fields[4]
    let fullmove = fields[5]

    let sideToMove: ChessColor
    switch sideField {
    case "w":
      sideToMove = .white
    case "b":
      sideToMove = .black
    default:
      throw StockfishFENValidationError.sideToMove(sideField)
    }

    let castlingPattern = #"^(?:-|K?Q?k?q?)$"#
    guard castling.range(of: castlingPattern, options: .regularExpression) != nil else {
      throw StockfishFENValidationError.castlingRights(castling)
    }

    let enPassantPattern = #"^(?:-|[a-h][36])$"#
    guard enPassant.range(of: enPassantPattern, options: .regularExpression) != nil else {
      throw StockfishFENValidationError.enPassant(enPassant)
    }

    guard let halfmoveValue = Int(halfmove), halfmoveValue >= 0 else {
      throw StockfishFENValidationError.halfmove(halfmove)
    }

    guard let fullmoveValue = Int(fullmove), fullmoveValue >= 1 else {
      throw StockfishFENValidationError.fullmove(fullmove)
    }

    let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)
    guard ranks.count == 8 else {
      throw StockfishFENValidationError.rankCount(ranks.count)
    }

    var whiteKings = 0
    var blackKings = 0
    let validPieces = Set("prnbqkPRNBQK")

    for (index, rank) in ranks.enumerated() {
      var squareCount = 0
      for character in rank {
        if let digit = character.wholeNumberValue {
          guard (1...8).contains(digit) else {
            throw StockfishFENValidationError.invalidDigit(character)
          }
          squareCount += digit
          continue
        }

        guard validPieces.contains(character) else {
          throw StockfishFENValidationError.invalidPieceCharacter(character)
        }

        squareCount += 1
        if character == "K" {
          whiteKings += 1
        } else if character == "k" {
          blackKings += 1
        }

        if strict, character.lowercased() == "p", (index == 0 || index == 7) {
          throw StockfishFENValidationError.pawnOnBackRank(rank: 8 - index)
        }
      }

      guard squareCount == 8 else {
        throw StockfishFENValidationError.invalidRankLength(rank: 8 - index, sum: squareCount)
      }
    }

    guard whiteKings == 1, blackKings == 1 else {
      throw StockfishFENValidationError.missingKings(white: whiteKings, black: blackKings)
    }

    _ = halfmoveValue
    _ = fullmoveValue
    return StockfishValidatedFEN(fen: trimmed, sideToMove: sideToMove)
  }
}

private enum StockfishDevCheckInputError: LocalizedError {
  case empty
  case tooManyFields

  var errorDescription: String? {
    switch self {
    case .empty:
      return "Paste a FEN before launching devCheck."
    case .tooManyFields:
      return "devCheck accepts between 1 and 6 FEN fields."
    }
  }
}

private enum StockfishDevCheckFENResolver {
  static func resolve(_ input: String) throws -> StockfishValidatedFEN {
    let fields = input
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }

    guard !fields.isEmpty else {
      throw StockfishDevCheckInputError.empty
    }

    guard fields.count <= 6 else {
      throw StockfishDevCheckInputError.tooManyFields
    }

    // devCheck accepts shorthand FEN and fills the omitted trailing fields with
    // standard defaults before reusing the normal validator.
    var normalizedFields = ["", "w", "-", "-", "0", "1"]
    for (index, field) in fields.enumerated() {
      normalizedFields[index] = field
    }

    return try StockfishFENValidator.validate(normalizedFields.joined(separator: " "))
  }
}

private struct StockfishDiagnosticsSnapshot {
  let requestID: String?
  let fenHash: String?
  let state: StockfishControllerState
  let status: String
  let error: String?
  let commands: [String]
  let lines: [String]

  func render() -> String {
    var sections: [String] = [
      "state=\(state.rawValue)",
      "status=\(status)",
    ]

    if let requestID {
      sections.append("request_id=\(requestID)")
    }

    if let fenHash {
      sections.append("fen_hash=\(fenHash)")
    }

    if let error, !error.isEmpty {
      sections.append("error=\(error)")
    }

    sections.append("commands_sent:")
    sections.append(contentsOf: commands.map { "  > \($0)" })
    sections.append("engine_output:")
    sections.append(contentsOf: lines.map { "  < \($0)" })
    return sections.joined(separator: "\n")
  }
}

private struct StockfishControllerError: LocalizedError {
  let message: String
  let diagnostics: String

  var errorDescription: String? {
    message
  }

  var failureReason: String? {
    diagnostics
  }
}

private enum MoveClassification: String {
  case brilliant
  case good
  case ok
  case inaccuracy
  case mistake
  case blunder

  var label: String {
    rawValue.capitalized
  }
}

private struct MoveEvaluationDelta {
  let evalBefore: Int
  let evalAfter: Int

  var deltaW: Int {
    evalAfter - evalBefore
  }
}

private enum GameReviewPhase: Equatable {
  case idle
  case prompt
  case loading
  case active
}

private struct GameReviewCheckpoint: Identifiable, Equatable {
  let id = UUID()
  let fenBeforeMistake: String
  let moveIndex: Int
  let blunderMove: String
  // Evals are always normalized to the mover's perspective. Mate scores are stored as
  // large centipawn-like sentinels so sorting keeps the same direction as raw Stockfish.
  let evalBefore: Int
  let evalAfter: Int
  let deltaW: Int
  let playerColor: ChessColor
}

@MainActor
private final class GameReviewStore: ObservableObject {
  private static let maximumCheckpointCount = 3
  private static let loadingDelayNs: UInt64 = 350_000_000

  @Published private(set) var phase: GameReviewPhase = .idle
  @Published private(set) var reviewCheckpoints: [GameReviewCheckpoint] = []
  @Published private(set) var currentReviewIndex = 0
  @Published private(set) var checkpointReloadVersion = 0

  private var recordedDrops: [GameReviewCheckpoint] = []
  private var stagedCheckpoints: [GameReviewCheckpoint] = []

  var currentCheckpoint: GameReviewCheckpoint? {
    guard reviewCheckpoints.indices.contains(currentReviewIndex) else {
      return nil
    }

    return reviewCheckpoints[currentReviewIndex]
  }

  var isLoading: Bool {
    phase == .loading
  }

  var isAwaitingEntryDecision: Bool {
    phase == .prompt
  }

  var isReviewMode: Bool {
    phase == .active
  }

  var stagedCheckpointCount: Int {
    stagedCheckpoints.count
  }

  func recordNegativeDrop(_ checkpoint: GameReviewCheckpoint) {
    guard phase == .idle, checkpoint.deltaW < 0 else {
      return
    }

    recordedDrops.append(checkpoint)
  }

  func stageReviewPrompt() -> Bool {
    guard phase == .idle else {
      return false
    }

    let selected = selectedCheckpoints()
    guard !selected.isEmpty else {
      return false
    }

    stagedCheckpoints = selected
    phase = .prompt
    return true
  }

  func startStagedReviewSequence() async -> Bool {
    guard phase == .prompt, !stagedCheckpoints.isEmpty else {
      return false
    }

    phase = .loading
    reviewCheckpoints = []
    currentReviewIndex = 0
    checkpointReloadVersion += 1

    try? await Task.sleep(nanoseconds: Self.loadingDelayNs)

    guard !Task.isCancelled else {
      resetSession()
      return false
    }

    guard !stagedCheckpoints.isEmpty else {
      resetSession()
      return false
    }

    reviewCheckpoints = stagedCheckpoints
    currentReviewIndex = 0
    checkpointReloadVersion += 1
    phase = .active
    return true
  }

  func restartCurrentCheckpoint() {
    guard phase == .active, currentCheckpoint != nil else {
      return
    }

    checkpointReloadVersion += 1
  }

  func advanceToNextCheckpoint() -> Bool {
    guard phase == .active else {
      return true
    }

    let nextIndex = currentReviewIndex + 1
    guard reviewCheckpoints.indices.contains(nextIndex) else {
      resetSession()
      return true
    }

    currentReviewIndex = nextIndex
    checkpointReloadVersion += 1
    return false
  }

  func resetSession() {
    phase = .idle
    reviewCheckpoints = []
    currentReviewIndex = 0
    checkpointReloadVersion = 0
    recordedDrops = []
    stagedCheckpoints = []
  }

  private func selectedCheckpoints() -> [GameReviewCheckpoint] {
    Array(
      recordedDrops
        .sorted(by: { $0.deltaW < $1.deltaW })
        .prefix(Self.maximumCheckpointCount)
    )
  }
}

private struct OpeningLessonStep: Identifiable, Equatable, Hashable {
  let id: String
  let startingFEN: String
  let sideToMove: ChessColor
  let correctMoveUCI: String
  let prompt: String
  let focus: String

  var destinationSquare: BoardSquare? {
    let trimmed = correctMoveUCI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.count >= 4 else {
      return nil
    }

    return BoardSquare(algebraic: String(trimmed.dropFirst(2).prefix(2)))
  }
}

private struct OpeningLessonDefinition: Equatable, Hashable {
  let id: String
  let title: String
  let summary: String
  let studentColor: ChessColor
  let steps: [OpeningLessonStep]

  static let italianOpening = buildItalianOpening()

  private static func buildItalianOpening() -> OpeningLessonDefinition {
    let sequence: [(uci: String, prompt: String, focus: String)] = [
      ("e2e4", "White starts by claiming the center. What is the first Italian Opening move?", "Open with a central pawn so your bishop and queen can breathe."),
      ("e7e5", "Black answers in the center. Find the matching reply.", "Mirror the central space grab and keep the position classical."),
      ("g1f3", "Now continue with White. Which move develops while attacking e5?", "Develop a knight, hit the center, and prepare to castle."),
      ("b8c6", "Black should support the center and develop. What fits?", "Develop a knight toward the center instead of wasting time."),
      ("f1c4", "White now enters the Italian structure. What move defines it?", "Develop the bishop to the active c4 diagonal and eye f7."),
      ("f8c5", "Finish the core setup for Black. What is the thematic bishop move?", "Meet bishop with bishop so both sides finish quick development.")
    ]

    var state = ChessGameState.initial()
    var steps: [OpeningLessonStep] = []

    for (index, item) in sequence.enumerated() {
      guard let move = state.move(forUCI: item.uci) else {
        preconditionFailure("Italian Opening lesson sequence contains an illegal move: \(item.uci)")
      }

      steps.append(
        OpeningLessonStep(
          id: "italian-opening-step-\(index)",
          startingFEN: state.fenString,
          sideToMove: state.turn,
          correctMoveUCI: move.uciString,
          prompt: item.prompt,
          focus: item.focus
        )
      )
      state = state.applying(move)
    }

    return OpeningLessonDefinition(
      id: "learn-the-italian-opening",
      title: "Learn the Italian Opening",
      summary: "Play the White side of the Italian Opening while Black replies automatically.",
      studentColor: .white,
      steps: steps
    )
  }
}

private enum OpeningLessonPhase: Equatable {
  case idle
  case active
  case complete
}

@MainActor
private final class OpeningLessonStore: ObservableObject {
  private static let maximumTriesPerStep = 3

  @Published private(set) var phase: OpeningLessonPhase = .idle
  @Published private(set) var activeLesson: OpeningLessonDefinition?
  @Published private(set) var currentStepIndex = 0
  @Published private(set) var remainingTries = 3
  @Published private(set) var isMoveRevealed = false
  @Published private(set) var reloadVersion = 0

  var currentStep: OpeningLessonStep? {
    guard let activeLesson,
          activeLesson.steps.indices.contains(currentStepIndex) else {
      return nil
    }

    return activeLesson.steps[currentStepIndex]
  }

  var isActive: Bool {
    phase == .active
  }

  var isComplete: Bool {
    phase == .complete
  }

  var isAwaitingPlayerMove: Bool {
    guard let activeLesson else {
      return false
    }

    return phase == .active && currentStep?.sideToMove == activeLesson.studentColor
  }

  var isAutoPlayingOpponentMove: Bool {
    guard let activeLesson else {
      return false
    }

    return phase == .active && currentStep?.sideToMove == activeLesson.studentColor.opponent
  }

  var currentPlayableStepNumber: Int {
    guard let activeLesson, !activeLesson.steps.isEmpty else {
      return 0
    }

    let cappedIndex = min(currentStepIndex, activeLesson.steps.count - 1)
    let completed = activeLesson.steps[...cappedIndex].filter { $0.sideToMove == activeLesson.studentColor }.count
    if completed == 0 {
      return 1
    }
    return min(completed, totalPlayableStepCount)
  }

  var totalPlayableStepCount: Int {
    guard let activeLesson else {
      return 0
    }

    return activeLesson.steps.filter { $0.sideToMove == activeLesson.studentColor }.count
  }

  func configure(for mode: ExperienceMode) {
    guard case .lesson(let lesson) = mode else {
      resetSession()
      return
    }

    guard activeLesson?.id != lesson.id || phase == .idle else {
      return
    }

    startLesson(lesson)
  }

  func restartLesson() {
    guard let activeLesson else {
      return
    }

    startLesson(activeLesson)
  }

  func revealCurrentMove() {
    guard phase == .active, currentStep != nil else {
      return
    }

    isMoveRevealed = true
  }

  @discardableResult
  func registerIncorrectAttempt() -> Bool {
    guard phase == .active, currentStep != nil, !isMoveRevealed else {
      return false
    }

    remainingTries = max(0, remainingTries - 1)

    if remainingTries == 0 {
      isMoveRevealed = true
    }

    return true
  }

  func advanceAfterCorrectMove() -> String? {
    guard let activeLesson else {
      return nil
    }

    isMoveRevealed = false

    let nextIndex = currentStepIndex + 1
    guard activeLesson.steps.indices.contains(nextIndex) else {
      phase = .complete
      remainingTries = Self.maximumTriesPerStep
      return activeLesson.id
    }

    currentStepIndex = nextIndex
    remainingTries = Self.maximumTriesPerStep
    return nil
  }

  func startLesson(_ lesson: OpeningLessonDefinition) {
    activeLesson = lesson
    phase = .active
    currentStepIndex = 0
    remainingTries = Self.maximumTriesPerStep
    isMoveRevealed = false
    reloadVersion += 1
  }

  func resetSession() {
    phase = .idle
    activeLesson = nil
    currentStepIndex = 0
    remainingTries = Self.maximumTriesPerStep
    isMoveRevealed = false
    reloadVersion = 0
  }
}

private enum PersonalitySpeaker {
  case pawn
  case rook
  case knight
  case bishop
  case queen
  case king

  var displayName: String {
    switch self {
    case .pawn:
      return "Pawn"
    case .rook:
      return "Rook"
    case .knight:
      return "Knight"
    case .bishop:
      return "Bishop"
    case .queen:
      return "Queen"
    case .king:
      return "King"
    }
  }

  var portraitGlyph: String {
    switch self {
    case .pawn:
      return "♟"
    case .rook:
      return "♜"
    case .knight:
      return "♞"
    case .bishop:
      return "♝"
    case .queen:
      return "♛"
    case .king:
      return "♚"
    }
  }

  var portraitTint: Color {
    switch self {
    case .pawn:
      return Color(red: 0.79, green: 0.21, blue: 0.24)
    case .rook:
      return Color(red: 0.79, green: 0.48, blue: 0.18)
    case .knight:
      return Color(red: 0.78, green: 0.30, blue: 0.12)
    case .bishop:
      return Color(red: 0.63, green: 0.63, blue: 0.85)
    case .queen:
      return Color(red: 0.84, green: 0.48, blue: 0.58)
    case .king:
      return Color(red: 0.92, green: 0.76, blue: 0.36)
    }
  }

  var portraitRotation: Double {
    switch self {
    case .pawn:
      return -7
    case .rook:
      return -9
    case .knight:
      return -14
    case .bishop:
      return -10
    case .queen:
      return -8
    case .king:
      return -6
    }
  }

  var defaultPitch: Float {
    switch self {
    case .pawn:
      return 0.94
    case .rook:
      return 0.68
    case .knight:
      return 1.48
    case .bishop:
      return 1.04
    case .queen:
      return 1.22
    case .king:
      return 0.82
    }
  }

  var defaultRate: Float {
    switch self {
    case .pawn:
      return 0.46
    case .rook:
      return 0.60
    case .knight:
      return 0.62
    case .bishop:
      return 0.38
    case .queen:
      return 0.30
    case .king:
      return 0.56
    }
  }

  var defaultVolume: Float {
    switch self {
    case .pawn:
      return 0.82
    case .rook:
      return 1.0
    case .knight:
      return 0.96
    case .bishop:
      return 0.88
    case .queen:
      return 0.92
    case .king:
      return 0.98
    }
  }

  var piperSpeakerType: PiperSpeakerType {
    switch self {
    case .pawn:
      return .pawn
    case .rook:
      return .rook
    case .knight:
      return .knight
    case .bishop:
      return .bishop
    case .queen:
      return .queen
    case .king:
      return .king
    }
  }
}

private struct SpokenLine {
  let speaker: PersonalitySpeaker
  let text: String
  let pitch: Float?
  let rate: Float?
  let volume: Float?
}

private enum SpeechPriority: Int {
  case normal
  case urgent
}

private enum CaptureImpactSound: CaseIterable {
  case pawnSword
  case bishopGunshot
  case knightThud
  case queenLaser
  case rookExplosion
}

private enum PieceMoveSound: CaseIterable {
  case pawnMarch
  case rookSlide
  case knightClop
  case bishopChime
  case queenSweep
  case kingShuffle
}

private final class CaptureSoundEffectEngine {
  private static let logger = Logger(subsystem: "ARChess", category: "CaptureSFX")
  private static let releasePadding: TimeInterval = 0.08

  private let queue = DispatchQueue(label: "ARChess.CaptureSFX")
  private let engine = AVAudioEngine()
  private let mixer = AVAudioMixerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  private lazy var buffers: [CaptureImpactSound: AVAudioPCMBuffer] = Self.buildBuffers(format: format)
  private lazy var moveBuffers: [PieceMoveSound: AVAudioPCMBuffer] = Self.buildMoveBuffers(format: format)
  private var activeFilePlayers: [AVAudioPlayer] = []
  private var busyUntil: CFTimeInterval = 0

  init() {
    engine.attach(mixer)
    engine.connect(mixer, to: engine.mainMixerNode, format: format)
    mixer.outputVolume = 0.95
  }

  func prewarmIfNeeded() {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      do {
        try self.ensureRunning()
        _ = self.moveBuffers.count
        _ = self.buffers.count
      } catch {
        Self.logger.debug("Capture SFX prewarm skipped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func play(_ effect: CaptureImpactSound) {
    if effect == .pawnSword {
      playFileResource(named: "pawnSword", extension: "mp3", volume: 0.88)
      return
    }

    if effect == .bishopGunshot {
      playFileResource(named: "bishopBell", extension: "mp3", volume: 0.84)
      return
    }

    if effect == .knightThud {
      playFileResource(named: "knightHorse", extension: "mp3", volume: 0.90)
      return
    }

    if effect == .queenLaser {
      playFileResource(named: "queenBlast", extension: "mp3", volume: 0.92)
      return
    }

    playBuffer(buffers[effect])
  }

  func playMove(for kind: ChessPieceKind) {
    let effect: PieceMoveSound
    switch kind {
    case .pawn:
      effect = .pawnMarch
    case .rook:
      effect = .rookSlide
    case .knight:
      effect = .knightClop
    case .bishop:
      effect = .bishopChime
    case .queen:
      effect = .queenSweep
    case .king:
      effect = .kingShuffle
    }

    playBuffer(moveBuffers[effect])
  }

  func remainingPlaybackTime() -> TimeInterval {
    queue.sync {
      max(0, busyUntil - CACurrentMediaTime())
    }
  }

  private func playBuffer(_ buffer: AVAudioPCMBuffer?) {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      do {
        try self.ensureRunning()
      } catch {
        Self.logger.error("Capture SFX engine failed to start: \(error.localizedDescription, privacy: .public)")
        return
      }

      guard let buffer else {
        return
      }

      self.noteBusy(duration: Double(buffer.frameLength) / buffer.format.sampleRate)

      let player = AVAudioPlayerNode()
      self.engine.attach(player)
      self.engine.connect(player, to: self.mixer, format: self.format)
      player.scheduleBuffer(buffer, at: nil, options: []) { [weak self, weak player] in
        guard let self, let player else {
          return
        }

        self.queue.async {
          player.stop()
          self.engine.disconnectNodeOutput(player)
          self.engine.detach(player)
        }
      }
      player.play()
    }
  }

  private func playFileResource(named name: String, extension ext: String, volume: Float) {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      do {
        try self.ensureRunning()
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
          Self.logger.error("Capture SFX file missing: \(name, privacy: .public).\(ext, privacy: .public)")
          return
        }

        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = volume
        player.prepareToPlay()
        self.noteBusy(duration: player.duration)
        self.activeFilePlayers.append(player)
        player.play()

        let cleanupDelay = player.duration + 0.25
        self.queue.asyncAfter(deadline: .now() + cleanupDelay) { [weak self, weak player] in
          guard let self, let player else {
            return
          }

          self.activeFilePlayers.removeAll { $0 === player }
        }
      } catch {
        Self.logger.error("Capture SFX file playback failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func ensureRunning() throws {
    try AudioSessionCoordinator.shared.activatePlaybackSession()

    guard !engine.isRunning else {
      return
    }

    try engine.start()
  }

  private func noteBusy(duration: TimeInterval) {
    let totalDuration = max(duration, 0.0) + Self.releasePadding
    busyUntil = max(busyUntil, CACurrentMediaTime() + totalDuration)
  }

  private static func buildBuffers(format: AVAudioFormat) -> [CaptureImpactSound: AVAudioPCMBuffer] {
    Dictionary(uniqueKeysWithValues: CaptureImpactSound.allCases.map { effect in
      (effect, makeBuffer(for: effect, format: format))
    })
  }

  private static func buildMoveBuffers(format: AVAudioFormat) -> [PieceMoveSound: AVAudioPCMBuffer] {
    Dictionary(uniqueKeysWithValues: PieceMoveSound.allCases.map { effect in
      (effect, makeMoveBuffer(for: effect, format: format))
    })
  }

  private static func makeBuffer(for effect: CaptureImpactSound, format: AVAudioFormat) -> AVAudioPCMBuffer {
    switch effect {
    case .pawnSword:
      return makePawnSwordBuffer(format: format)
    case .bishopGunshot:
      return makeBishopGunshotBuffer(format: format)
    case .knightThud:
      return makeKnightThudBuffer(format: format)
    case .queenLaser:
      return makeQueenLaserBuffer(format: format)
    case .rookExplosion:
      return makeRookExplosionBuffer(format: format)
    }
  }

  private static func makePawnSwordBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
    synthesizeBuffer(duration: 0.18, format: format) { t, normalized, noise in
      let env = expEnvelope(normalized, decay: 4.2)
      let sweepFrequency = 1450.0 - (650.0 * normalized)
      let tonal = Float(sin(2 * Double.pi * sweepFrequency * t)) * 0.22
      let composite = (noise * 0.34 + tonal) * env
      return clampSample(composite)
    }
  }

  private static func makeBishopGunshotBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
    synthesizeBuffer(duration: 0.20, format: format) { t, normalized, noise in
      let crackEnvelope = expEnvelope(normalized / 0.14, decay: 9.0)
      let crack: Float = normalized < 0.14 ? (noise * 0.95 * crackEnvelope) : 0
      let bodyWave = Float(sin(2 * Double.pi * 180 * t)) * expEnvelope(normalized, decay: 6.5) * 0.24
      let tail = noise * expEnvelope(normalized, decay: 10.0) * 0.16
      return clampSample(crack + bodyWave + tail)
    }
  }

  private static func makeKnightThudBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
    synthesizeBuffer(duration: 0.26, format: format) { t, normalized, noise in
      let low = Float(sin(2 * Double.pi * 92 * t)) * expEnvelope(normalized, decay: 5.0) * 0.55
      let smack = noise * expEnvelope(normalized, decay: 16.0) * 0.12
      return clampSample(low + smack)
    }
  }

  private static func makeQueenLaserBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
    synthesizeBuffer(duration: 0.24, format: format) { t, normalized, noise in
      let frequency = 1900.0 - (850.0 * normalized)
      let vibrato = 1.0 + (sin(2 * Double.pi * 14 * t) * 0.05)
      let beam = Float(sin(2 * Double.pi * frequency * vibrato * t)) * expEnvelope(normalized, decay: 2.8) * 0.42
      let sparkle = noise * expEnvelope(normalized, decay: 7.5) * 0.06
      return clampSample(beam + sparkle)
    }
  }

  private static func makeRookExplosionBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
    synthesizeBuffer(duration: 0.42, format: format) { t, normalized, noise in
      let boom = Float(sin(2 * Double.pi * 64 * t)) * expEnvelope(normalized, decay: 3.5) * 0.54
      let burst = noise * expEnvelope(normalized, decay: 4.2) * 0.44
      let rumble = Float(sin(2 * Double.pi * 34 * t)) * expEnvelope(normalized, decay: 2.2) * 0.18
      return clampSample(boom + burst + rumble)
    }
  }

  private static func makeMoveBuffer(for effect: PieceMoveSound, format: AVAudioFormat) -> AVAudioPCMBuffer {
    switch effect {
    case .pawnMarch:
      return synthesizeBuffer(duration: 0.10, format: format) { t, normalized, noise in
        let click = noise * expEnvelope(normalized, decay: 22.0) * 0.10
        let body = Float(sin(2 * Double.pi * 210 * t)) * expEnvelope(normalized, decay: 11.0) * 0.08
        return clampSample(click + body)
      }
    case .rookSlide:
      return synthesizeBuffer(duration: 0.14, format: format) { t, normalized, noise in
        let scrape = noise * expEnvelope(normalized, decay: 8.0) * 0.16
        let low = Float(sin(2 * Double.pi * 86 * t)) * expEnvelope(normalized, decay: 7.5) * 0.12
        return clampSample(scrape + low)
      }
    case .knightClop:
      return synthesizeBuffer(duration: 0.12, format: format) { t, normalized, noise in
        let phase = normalized < 0.45 ? 1.0 : 0.52
        let clop = noise * expEnvelope(normalized, decay: 18.0) * Float(phase) * 0.18
        let hoof = Float(sin(2 * Double.pi * 150 * t)) * expEnvelope(normalized, decay: 13.0) * 0.10
        return clampSample(clop + hoof)
      }
    case .bishopChime:
      return synthesizeBuffer(duration: 0.16, format: format) { t, normalized, noise in
        let toneA = Float(sin(2 * Double.pi * 620 * t)) * expEnvelope(normalized, decay: 6.0) * 0.10
        let toneB = Float(sin(2 * Double.pi * 930 * t)) * expEnvelope(normalized, decay: 8.0) * 0.06
        let air = noise * expEnvelope(normalized, decay: 14.0) * 0.02
        return clampSample(toneA + toneB + air)
      }
    case .queenSweep:
      return synthesizeBuffer(duration: 0.15, format: format) { t, normalized, noise in
        let sweepFrequency = 540.0 + (360.0 * normalized)
        let sweep = Float(sin(2 * Double.pi * sweepFrequency * t)) * expEnvelope(normalized, decay: 4.4) * 0.12
        let shimmer = noise * expEnvelope(normalized, decay: 12.0) * 0.03
        return clampSample(sweep + shimmer)
      }
    case .kingShuffle:
      return synthesizeBuffer(duration: 0.13, format: format) { t, normalized, noise in
        let wobble = Float(sin(2 * Double.pi * 118 * t)) * expEnvelope(normalized, decay: 7.2) * 0.10
        let step = noise * expEnvelope(normalized, decay: 17.0) * 0.08
        return clampSample(wobble + step)
      }
    }
  }

  private static func synthesizeBuffer(
    duration: Double,
    format: AVAudioFormat,
    generator: (_ time: Double, _ normalized: Double, _ noise: Float) -> Float
  ) -> AVAudioPCMBuffer {
    let sampleRate = format.sampleRate
    let frames = max(1, AVAudioFrameCount(duration * sampleRate))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames

    guard let channel = buffer.floatChannelData?[0] else {
      return buffer
    }

    for index in 0..<Int(frames) {
      let t = Double(index) / sampleRate
      let normalized = min(max(Double(index) / Double(max(Int(frames) - 1, 1)), 0), 1)
      let noise = Float.random(in: -1...1)
      channel[index] = generator(t, normalized, noise)
    }

    return buffer
  }

  private static func expEnvelope(_ x: Double, decay: Double) -> Float {
    Float(exp(-decay * max(0, x)))
  }

  private static func clampSample(_ sample: Float) -> Float {
    min(max(sample, -1), 1)
  }
}

private final class AmbientMusicController {
  static let shared = AmbientMusicController()

  private static let logger = Logger(subsystem: "ARChess", category: "AmbientMusic")
  private static let muteDefaultsKey = "AmbientMusicController.isMuted"

  private let queue = DispatchQueue(label: "ARChess.AmbientMusic")
  private var player: AVAudioPlayer?
  private var ambientTrackMissing = false
  private let idleVolume: Float = 0.09
  private let speechDuckedVolume: Float = 0.035
  private var isSpeechActive = false
  private var isPlayingRequested = false
  private var isMutedInternal = UserDefaults.standard.bool(forKey: muteDefaultsKey)

  private init() {}

  var isMuted: Bool {
    queue.sync { isMutedInternal }
  }

  func setMuted(_ muted: Bool) {
    queue.async { [weak self] in
      self?.applyMutedState(muted)
    }
  }

  func toggleMuted() {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      self.applyMutedState(!self.isMutedInternal)
    }
  }

  func playLoopIfNeeded() {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      self.isPlayingRequested = true
      do {
        try self.preparePlayerIfNeeded()
        self.player?.volume = self.isSpeechActive ? self.speechDuckedVolume : self.idleVolume
        guard !self.isMutedInternal else {
          self.player?.pause()
          return
        }
        if self.player?.isPlaying != true {
          self.player?.play()
        }
      } catch {
        Self.logger.error("Ambient music failed to start: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      self.isPlayingRequested = false
      self.player?.stop()
      self.player?.currentTime = 0
    }
  }

  func setSpeechActive(_ active: Bool) {
    queue.async { [weak self] in
      guard let self else {
        return
      }

      self.isSpeechActive = active
      self.player?.setVolume(active ? self.speechDuckedVolume : self.idleVolume, fadeDuration: 0.18)
    }
  }

  private func applyMutedState(_ muted: Bool) {
    guard isMutedInternal != muted else {
      return
    }

    isMutedInternal = muted
    UserDefaults.standard.set(muted, forKey: Self.muteDefaultsKey)

    if muted {
      player?.pause()
      return
    }

    guard isPlayingRequested else {
      return
    }

    do {
      try preparePlayerIfNeeded()
      player?.volume = isSpeechActive ? speechDuckedVolume : idleVolume
      if player?.isPlaying != true {
        player?.play()
      }
    } catch {
      Self.logger.error("Ambient music failed to resume: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func preparePlayerIfNeeded() throws {
    if player != nil || ambientTrackMissing {
      return
    }

    guard let url = Bundle.main.url(forResource: "doom_at_dooms_gate", withExtension: "mp3") else {
      ambientTrackMissing = true
      Self.logger.notice("Ambient track missing from app resources. Background music is disabled for this build.")
      return
    }

    try AudioSessionCoordinator.shared.activatePlaybackSession()

    let nextPlayer = try AVAudioPlayer(contentsOf: url)
    nextPlayer.numberOfLoops = -1
    nextPlayer.volume = idleVolume
    nextPlayer.prepareToPlay()
    player = nextPlayer
  }
}

private final class StockfishAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  private let indexHTMLProvider: () -> String
  private let engineData: Data

  init(
    indexHTMLProvider: @escaping () -> String,
    engineData: Data
  ) {
    self.indexHTMLProvider = indexHTMLProvider
    self.engineData = engineData
    super.init()
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
      return
    }

    let path = url.path.isEmpty ? "/index.html" : url.path
    let responsePayload: (Data, String)?

    switch path {
    case "/index.html":
      responsePayload = (Data(indexHTMLProvider().utf8), "text/html")
    case "/stockfish-nnue-16-single.js":
      responsePayload = (engineData, "application/javascript")
    default:
      responsePayload = nil
    }

    guard let (data, mimeType) = responsePayload else {
      urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
      return
    }

    let response = URLResponse(
      url: url,
      mimeType: mimeType,
      expectedContentLength: data.count,
      textEncodingName: mimeType == "text/html" || mimeType == "application/javascript" ? "utf-8" : nil
    )
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/*
 The previous bridge mixed startup, readiness, search dispatch, and cancellation in one loose queue.
 That led to exactly the flakiness we were seeing:
 - no strict UCI / readyok gating before every search
 - depth-based searches with non-deterministic latency
 - no structured diagnostics when bestmove was missing
 - opaque timeouts with no command/output history
 This controller keeps a single long-lived engine session and enforces a UCI state machine
 around every request.
 */
@MainActor
private final class StockfishWASMAnalyzer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private struct PendingSearch {
    let id: String
    let fen: String
    let options: StockfishSearchOptions
    let sideToMove: ChessColor
    let fenHash: String
    let startedAt = Date()
    let continuation: CheckedContinuation<StockfishAnalysis, Error>
  }

  private static let scheme = "archess-stockfish"
  private static let logger = Logger(subsystem: "ARChess", category: "Stockfish")

  private let messageHandlerName = "stockfishBridge"
  private let config: StockfishEngineConfig
  private var webView: WKWebView?
  private var schemeHandler: StockfishAssetSchemeHandler?
  private weak var hostView: UIView?
  private var engineState: StockfishControllerState = .initialize
  private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var currentSearch: PendingSearch?
  private var timeoutTask: Task<Void, Never>?
  private var commandBuffer = FixedRingBuffer<String>(capacity: 50)
  private var lineBuffer = FixedRingBuffer<String>(capacity: 300)
  private var requestCounter = 0
  private var startupRetryCount = 0
  private(set) var lastError: String?
  private(set) var lastStatus = "Stockfish idle."

  init(config: StockfishEngineConfig = StockfishEngineConfig()) {
    self.config = config
    super.init()
  }

  func analyze(
    fen: String,
    options: StockfishSearchOptions = .realtime()
  ) async throws -> StockfishAnalysis {
    let validatedFEN: StockfishValidatedFEN
    do {
      validatedFEN = try StockfishFENValidator.validate(fen, strict: config.strictFENValidation)
    } catch {
      lastError = error.localizedDescription
      lastStatus = "Rejected invalid FEN before engine call."
      throw makeError(
        "Invalid FEN: \(error.localizedDescription)",
        requestID: nil,
        fen: fen
      )
    }

    try await ensureEngineReady()
    if currentSearch != nil {
      try await cancelActiveSearchIfNeeded(reason: "superseded by a newer board state")
    }

    let requestID = nextRequestID()
    let payload = StockfishSearchOptions(
      movetimeMs: options.movetimeMs ?? config.defaultMovetimeMs,
      debugDepth: options.debugDepth,
      hardTimeoutMs: options.hardTimeoutMs ?? max(config.hardTimeoutMs, (options.movetimeMs ?? config.defaultMovetimeMs) * 4),
      multiPV: max(1, options.multiPV ?? 1),
      searchMoves: options.searchMoves
    )
    let fenHash = Self.hashFEN(validatedFEN.fen)
    lastStatus = payload.debugDepth != nil
      ? "Preparing depth search for request \(requestID)..."
      : "Preparing movetime \(payload.movetimeMs ?? config.defaultMovetimeMs)ms search for request \(requestID)..."

    return try await withCheckedThrowingContinuation { continuation in
      let pendingSearch = PendingSearch(
        id: requestID,
        fen: validatedFEN.fen,
        options: payload,
        sideToMove: validatedFEN.sideToMove,
        fenHash: fenHash,
        continuation: continuation
      )
      currentSearch = pendingSearch
      scheduleTimeout(for: pendingSearch)

      let command: [String: Any] = [
        "id": requestID,
        "fen": validatedFEN.fen,
        "movetimeMs": payload.movetimeMs ?? config.defaultMovetimeMs,
        "debugDepth": payload.debugDepth as Any,
        "multiPV": payload.multiPV ?? 1,
        "searchMoves": payload.searchMoves as Any,
      ]

      Self.logger.info("Stockfish request \(requestID, privacy: .public) queued state=\(self.engineState.rawValue, privacy: .public) fen_hash=\(fenHash, privacy: .public)")

      evaluate(script: "window.__archessAnalyze(\(jsonLiteral(command)));") { [weak self] result in
        guard let self else {
          return
        }

        switch result {
        case .success:
          return
        case .failure(let error):
          self.failCurrentSearch(
            message: "Could not dispatch Stockfish request: \(error.localizedDescription)",
            requestID: requestID,
            fen: validatedFEN.fen
          )
        }
      }
    }
  }

  func newGame() async {
    do {
      try await ensureEngineReady()
    } catch {
      lastError = error.localizedDescription
      return
    }

    evaluate(script: "window.__archessNewGame && window.__archessNewGame();") { _ in }
  }

  func attach(to hostView: UIView) {
    self.hostView = hostView
    guard let webView else {
      return
    }

    attachWebViewIfNeeded(webView, to: hostView)
  }

  func reset() {
    timeoutTask?.cancel()
    timeoutTask = nil
    currentSearch = nil
    readyWaiters.values.forEach {
      $0.resume(throwing: makeError("Engine session reset.", requestID: nil, fen: nil))
    }
    readyWaiters.removeAll()
    commandBuffer.removeAll()
    lineBuffer.removeAll()
    lastError = nil
    lastStatus = "Stockfish idle."
    engineState = .initialize
    startupRetryCount = 0

    if let webView {
      webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
      webView.navigationDelegate = nil
      webView.stopLoading()
      webView.removeFromSuperview()
    }

    webView = nil
    schemeHandler = nil
  }

  func dumpDiagnostics() -> String {
    diagnosticsSnapshot(requestID: currentSearch?.id, fen: currentSearch?.fen).render()
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == messageHandlerName,
          let payload = message.body as? [String: Any],
          let type = payload["type"] as? String else {
      return
    }

    switch type {
    case "status":
      if let message = payload["message"] as? String {
        lastStatus = message
      }
    case "state":
      if let rawState = payload["state"] as? String,
         let state = StockfishControllerState(rawValue: rawState) {
        engineState = state
      }
      if let reason = payload["reason"] as? String, !reason.isEmpty {
        lastStatus = reason
      }
    case "command":
      if let command = payload["command"] as? String {
        commandBuffer.append(command)
      }
    case "line":
      if let line = payload["line"] as? String {
        lineBuffer.append(line)
      }
    case "ready":
      engineState = .ready
      lastError = nil
      if let reason = payload["reason"] as? String, !reason.isEmpty {
        lastStatus = reason
      } else {
        lastStatus = "Stockfish ready."
      }
      let waiters = readyWaiters.values
      readyWaiters.removeAll()
      waiters.forEach { $0.resume() }
    case "error":
      let message = payload["message"] as? String ?? "Unknown Stockfish bridge error."
      lastError = message
      lastStatus = "Stockfish error: \(message)"
      engineState = .failed
      let diagnostics = diagnosticsSnapshot(requestID: currentSearch?.id, fen: currentSearch?.fen).render()
      let waiters = readyWaiters.values
      readyWaiters.removeAll()
      waiters.forEach { $0.resume(throwing: StockfishControllerError(message: message, diagnostics: diagnostics)) }
      if currentSearch != nil {
        failCurrentSearch(message: message, requestID: currentSearch?.id, fen: currentSearch?.fen)
      }
    case "result":
      guard let requestID = payload["id"] as? String else {
        return
      }
      handleResult(payload, requestID: requestID)
    default:
      return
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    lastError = error.localizedDescription
    lastStatus = "Stockfish webview navigation failed."
    engineState = .failed
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    lastError = error.localizedDescription
    lastStatus = "Stockfish webview provisional navigation failed."
    engineState = .failed
  }

  private func ensureEngineReady() async throws {
    ensureWebView()
    guard webView != nil else {
      throw makeError(lastError ?? "Bundled Stockfish assets are unavailable.", requestID: nil, fen: nil)
    }

    do {
      try await waitUntilReady(timeoutMs: config.startupTimeoutMs)
    } catch {
      guard startupRetryCount < config.maxStartupRetries else {
        throw error
      }

      startupRetryCount += 1
      Self.logger.error("Stockfish startup retry \(self.startupRetryCount, privacy: .public) after failure: \(self.lastStatus, privacy: .public)")
      rebuildWebView(reason: "Retrying Stockfish startup...")
      try await waitUntilReady(timeoutMs: config.startupTimeoutMs)
    }
  }

  private func ensureWebView() {
    guard webView == nil else {
      return
    }

    guard let engineURL = Bundle.main.url(forResource: "stockfish-nnue-16-single", withExtension: "js"),
          let wasmURL = Bundle.main.url(forResource: "stockfish-nnue-16-single", withExtension: "wasm"),
          let engineData = try? Data(contentsOf: engineURL),
          let wasmData = try? Data(contentsOf: wasmURL) else {
      lastError = "Bundled Stockfish assets are missing or unreadable."
      engineState = .failed
      return
    }

    let userContentController = WKUserContentController()
    userContentController.add(self, name: messageHandlerName)

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    let schemeHandler = StockfishAssetSchemeHandler(
      indexHTMLProvider: { [weak self] in
        self?.stockfishBridgeHTML(wasmBase64: wasmData.base64EncodedString()) ?? ""
      },
      engineData: engineData
    )
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.isUserInteractionEnabled = false
    webView.alpha = 0.015
    webView.navigationDelegate = self

    self.webView = webView
    self.schemeHandler = schemeHandler
    lastError = nil
    lastStatus = "Stockfish booting..."
    engineState = .initialize

    guard let indexURL = URL(string: "\(Self.scheme)://bundle/index.html") else {
      lastError = "Could not form Stockfish bridge URL."
      engineState = .failed
      return
    }

    if let hostView {
      attachWebViewIfNeeded(webView, to: hostView)
    }

    webView.load(URLRequest(url: indexURL))
  }

  private func waitUntilReady(timeoutMs: Int) async throws {
    if engineState == .ready {
      return
    }

    let waiterID = UUID()
    try await withCheckedThrowingContinuation { continuation in
      readyWaiters[waiterID] = continuation

      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        await MainActor.run {
          guard let self,
                let continuation = self.readyWaiters.removeValue(forKey: waiterID),
                self.engineState != .ready else {
            return
          }

          let message = "Timed out waiting for readyok."
          self.lastError = message
          self.lastStatus = "Stockfish did not reach READY in \(timeoutMs)ms."
          self.engineState = .failed
          Self.logger.error("Stockfish ready timeout after \(timeoutMs, privacy: .public)ms. Diagnostics:\n\(self.dumpDiagnostics(), privacy: .public)")
          continuation.resume(
            throwing: self.makeError(message, requestID: self.currentSearch?.id, fen: self.currentSearch?.fen)
          )
        }
      }
    }
  }

  private func cancelActiveSearchIfNeeded(reason: String) async throws {
    guard let pending = currentSearch else {
      return
    }

    timeoutTask?.cancel()
    timeoutTask = nil
    currentSearch = nil
    pending.continuation.resume(
      throwing: makeError("Stockfish request \(pending.id) cancelled: \(reason).", requestID: pending.id, fen: pending.fen)
    )

    lastStatus = "Cancelling request \(pending.id)..."
    evaluate(script: "window.__archessCancelCurrentAnalysis && window.__archessCancelCurrentAnalysis(\(jsonLiteral(reason)));") { _ in }
    try await waitUntilReady(timeoutMs: config.readyTimeoutMs)
  }

  private func scheduleTimeout(for pending: PendingSearch) {
    timeoutTask?.cancel()
    let timeoutMs = pending.options.hardTimeoutMs ?? config.hardTimeoutMs
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
      await MainActor.run {
        guard let self,
              let active = self.currentSearch,
              active.id == pending.id else {
          return
        }

        self.lastError = "Stockfish request timed out."
        self.lastStatus = "Stockfish request \(pending.id) timed out after \(timeoutMs)ms."
        self.evaluate(
          script: "window.__archessCancelCurrentAnalysis && window.__archessCancelCurrentAnalysis('timeout');"
        ) { _ in }
        self.failCurrentSearch(
          message: "Stockfish timed out after \(timeoutMs)ms.",
          requestID: pending.id,
          fen: pending.fen
        )
      }
    }
  }

  private func handleResult(_ payload: [String: Any], requestID: String) {
    guard let pending = currentSearch else {
      return
    }

    guard pending.id == requestID else {
      Self.logger.debug("Ignoring late Stockfish result for stale request \(requestID, privacy: .public)")
      return
    }

    timeoutTask?.cancel()
    timeoutTask = nil
    currentSearch = nil
    engineState = .ready

    let bestMove = payload["bestMove"] as? String
    guard let bestMove, !bestMove.isEmpty, bestMove != "(none)" else {
      pending.continuation.resume(
        throwing: makeError("Stockfish returned no bestmove.", requestID: requestID, fen: pending.fen)
      )
      return
    }

    let durationMs = payload["durationMs"] as? Int
      ?? max(0, Int(Date().timeIntervalSince(pending.startedAt) * 1_000))
    let rawCandidates = Self.decodeCandidates(
      from: payload["candidates"],
      fallbackMove: bestMove,
      fallbackScoreCp: payload["scoreCp"] as? Int,
      fallbackMateIn: payload["mateIn"] as? Int,
      fallbackPV: payload["pv"] as? [String] ?? []
    )
    let analysis = StockfishAnalysis(
      fen: pending.fen,
      sideToMove: pending.sideToMove,
      requestID: requestID,
      durationMs: durationMs,
      scoreCp: payload["scoreCp"] as? Int,
      mateIn: payload["mateIn"] as? Int,
      pv: payload["pv"] as? [String] ?? [],
      bestMove: bestMove,
      rawCandidates: rawCandidates,
      topUniqueMoves: Self.buildTopUniqueMoves(from: rawCandidates)
    )

    lastError = nil
    lastStatus = payload["status"] as? String ?? "Stockfish returned bestmove in \(durationMs)ms."
    Self.logger.info("Stockfish request \(requestID, privacy: .public) completed outcome=bestmove duration_ms=\(durationMs, privacy: .public) fen_hash=\(pending.fenHash, privacy: .public)")
    pending.continuation.resume(returning: analysis)
  }

  private func failCurrentSearch(message: String, requestID: String?, fen: String?) {
    timeoutTask?.cancel()
    timeoutTask = nil
    guard let pending = currentSearch else {
      lastError = message
      return
    }

    currentSearch = nil
    lastError = message
    Self.logger.error("Stockfish request \(pending.id, privacy: .public) failed message=\(message, privacy: .public) fen_hash=\(pending.fenHash, privacy: .public)")
    pending.continuation.resume(
      throwing: makeError(message, requestID: requestID ?? pending.id, fen: fen ?? pending.fen)
    )
  }

  private func diagnosticsSnapshot(requestID: String?, fen: String?) -> StockfishDiagnosticsSnapshot {
    StockfishDiagnosticsSnapshot(
      requestID: requestID,
      fenHash: fen.map(Self.hashFEN),
      state: engineState,
      status: lastStatus,
      error: lastError,
      commands: Array(commandBuffer.elements.suffix(50)),
      lines: Array(lineBuffer.elements.suffix(100))
    )
  }

  private func makeError(_ message: String, requestID: String?, fen: String?) -> StockfishControllerError {
    StockfishControllerError(
      message: message,
      diagnostics: diagnosticsSnapshot(requestID: requestID, fen: fen).render()
    )
  }

  private func nextRequestID() -> String {
    requestCounter += 1
    return "stockfish-\(requestCounter)"
  }

  private static func decodeCandidates(
    from rawValue: Any?,
    fallbackMove: String?,
    fallbackScoreCp: Int?,
    fallbackMateIn: Int?,
    fallbackPV: [String]
  ) -> [StockfishCandidate] {
    guard let rawCandidates = rawValue as? [[String: Any]] else {
      return fallbackCandidates(
        bestMove: fallbackMove,
        scoreCp: fallbackScoreCp,
        mateIn: fallbackMateIn,
        pv: fallbackPV
      )
    }

    let decoded = rawCandidates.compactMap { payload in
      let pv = payload["pv"] as? [String] ?? []
      return StockfishCandidate(
        rank: payload["rank"] as? Int ?? 1,
        move: payload["move"] as? String ?? payload["bestMove"] as? String,
        scoreCp: payload["scoreCp"] as? Int,
        mateIn: payload["mateIn"] as? Int,
        depth: payload["depth"] as? Int ?? 0,
        pv: pv
      )
    }
    .sorted { $0.rank < $1.rank }

    if decoded.isEmpty {
      return fallbackCandidates(
        bestMove: fallbackMove,
        scoreCp: fallbackScoreCp,
        mateIn: fallbackMateIn,
        pv: fallbackPV
      )
    }

    if let fallbackMove, !fallbackMove.isEmpty, !decoded.contains(where: { $0.move == fallbackMove }) {
      let fallback = StockfishCandidate(
        rank: 1,
        move: fallbackMove,
        scoreCp: fallbackScoreCp,
        mateIn: fallbackMateIn,
        depth: decoded.first?.depth ?? 0,
        pv: fallbackPV
      )
      return ([fallback] + decoded).sorted { $0.rank < $1.rank }
    }

    return decoded
  }

  private static func fallbackCandidates(
    bestMove: String?,
    scoreCp: Int?,
    mateIn: Int?,
    pv: [String]
  ) -> [StockfishCandidate] {
    guard let bestMove, !bestMove.isEmpty else {
      return []
    }

    return [
      StockfishCandidate(
        rank: 1,
        move: bestMove,
        scoreCp: scoreCp,
        mateIn: mateIn,
        depth: 0,
        pv: pv.isEmpty ? [bestMove] : pv
      )
    ]
  }

  private static func buildTopUniqueMoves(from rawCandidates: [StockfishCandidate]) -> [StockfishCandidate] {
    // Stockfish streams repeated info lines during search. By the time we receive bestmove,
    // each multipv rank holds its latest final snapshot. We then dedupe by root move so the
    // UI shows distinct human choices rather than repeated near-identical PVs.
    var bestByMove: [String: StockfishCandidate] = [:]

    for candidate in rawCandidates {
      guard let move = candidate.move, !move.isEmpty else {
        continue
      }

      if let existing = bestByMove[move] {
        if shouldPrefer(candidate, over: existing) {
          bestByMove[move] = candidate
        }
      } else {
        bestByMove[move] = candidate
      }
    }

    let ordered = bestByMove.values
      .sorted(by: compareCandidates)
      .prefix(StockfishAnalysisDefaults.multiPV)

    guard let bestCandidate = ordered.first else {
      return []
    }

    return Array(ordered.enumerated()).map { index, candidate in
      StockfishCandidate(
        rank: index + 1,
        move: candidate.move,
        scoreCp: candidate.scoreCp,
        mateIn: candidate.mateIn,
        depth: candidate.depth,
        pv: candidate.pv,
        confidence: confidence(for: candidate, relativeTo: bestCandidate)
      )
    }
  }

  private static func shouldPrefer(_ candidate: StockfishCandidate, over existing: StockfishCandidate) -> Bool {
    if candidate.rank != existing.rank {
      return candidate.rank < existing.rank
    }
    if candidate.normalizedScore != existing.normalizedScore {
      return candidate.normalizedScore > existing.normalizedScore
    }
    return candidate.depth > existing.depth
  }

  private static func compareCandidates(_ left: StockfishCandidate, _ right: StockfishCandidate) -> Bool {
    if left.normalizedScore != right.normalizedScore {
      return left.normalizedScore > right.normalizedScore
    }
    if left.rank != right.rank {
      return left.rank < right.rank
    }
    if left.depth != right.depth {
      return left.depth > right.depth
    }
    return (left.move ?? "") < (right.move ?? "")
  }

  private static func confidence(for candidate: StockfishCandidate, relativeTo bestCandidate: StockfishCandidate) -> Double {
    let gap = max(0, bestCandidate.normalizedScore - candidate.normalizedScore)
    let clampedGap = min(gap, StockfishAnalysisDefaults.confidenceGapWindowCp)
    return 1.0 - (Double(clampedGap) / Double(StockfishAnalysisDefaults.confidenceGapWindowCp))
  }

  private func evaluate(
    script: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    webView?.evaluateJavaScript(script) { _, error in
      if let error {
        completion(.failure(error))
      } else {
        completion(.success(()))
      }
    }
  }

  private func attachWebViewIfNeeded(_ webView: WKWebView, to hostView: UIView) {
    guard webView.superview !== hostView else {
      return
    }

    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = false
    hostView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.widthAnchor.constraint(equalToConstant: 2),
      webView.heightAnchor.constraint(equalToConstant: 2),
      webView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -2),
      webView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor, constant: -2),
    ])
  }

  private func rebuildWebView(reason: String) {
    if let webView {
      webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
      webView.navigationDelegate = nil
      webView.stopLoading()
      webView.removeFromSuperview()
    }

    webView = nil
    schemeHandler = nil
    readyWaiters.removeAll()
    currentSearch = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    engineState = .initialize
    lastError = nil
    lastStatus = reason
    ensureWebView()
  }

  private func jsonLiteral(_ payload: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
    return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
  }

  private func stockfishBridgeHTML(wasmBase64: String) -> String {
    return """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <script id="stockfish-engine" src="\(Self.scheme)://bundle/stockfish-nnue-16-single.js"></script>
        <script>
          const wasmBase64 = \(jsonLiteral(wasmBase64));
          const bridgeState = {
            state: 'INIT',
            waitingReadyReason: null,
            ready: false,
            engine: null,
            currentRequest: null,
            queuedRequest: null,
            needsNewGame: true,
            lastCommands: [],
            lastLines: [],
          };

          function pushRing(buffer, value, capacity) {
            buffer.push(value);
            if (buffer.length > capacity) {
              buffer.splice(0, buffer.length - capacity);
            }
          }

          function bridgePost(payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName)) {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload);
            }
          }

          function bridgeStatus(message) {
            bridgePost({ type: 'status', message });
          }

          function bridgeStateChange(state, reason) {
            bridgeState.state = state;
            bridgePost({ type: 'state', state, reason: reason || null, timestamp: Date.now() });
          }

          function logCommand(command) {
            pushRing(bridgeState.lastCommands, command, 50);
            bridgePost({ type: 'command', command, timestamp: Date.now() });
          }

          function logLine(line) {
            pushRing(bridgeState.lastLines, line, 300);
            bridgePost({ type: 'line', line, timestamp: Date.now() });
          }

          function decodeBase64ToUint8Array(base64) {
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) {
              bytes[index] = binary.charCodeAt(index);
            }
            return bytes;
          }

          function sendEngineCommand(command) {
            if (!bridgeState.engine) {
              bridgePost({ type: 'error', message: 'Stockfish engine missing while sending command.' });
              return false;
            }

            logCommand(command);
            if (typeof bridgeState.engine.onCustomMessage === 'function') {
              bridgeState.engine.onCustomMessage(command);
              return true;
            }

            if (typeof bridgeState.engine.postMessage === 'function') {
              bridgeState.engine.postMessage(command);
              return true;
            }

            bridgePost({ type: 'error', message: 'Stockfish command API missing.' });
            return false;
          }

          async function bootStockfish() {
            try {
              bridgeStatus('Loading bundled Stockfish script...');
              const factory = document.getElementById('stockfish-engine')._exports;
              if (!factory) {
                bridgePost({ type: 'error', message: 'Stockfish engine factory missing.' });
                return;
              }

              bridgeStatus('Decoding bundled WASM...');
              const wasmBinary = decodeBase64ToUint8Array(wasmBase64);
              bridgeStatus('Instantiating Stockfish locally...');
              const engine = await factory({ wasmBinary });
              bridgeState.engine = engine;

              if (typeof engine.addMessageListener === 'function') {
                engine.addMessageListener(handleEngineLine);
              } else if (typeof engine.onmessage !== 'undefined') {
                engine.onmessage = handleEngineLine;
              } else {
                bridgePost({ type: 'error', message: 'Stockfish listener API missing.' });
                return;
              }

              bridgeStateChange('SENT_UCI', 'Waiting for uciok...');
              sendEngineCommand('uci');
            } catch (error) {
              bridgePost({ type: 'error', message: String(error) });
            }
          }

          function requestReady(reason) {
            bridgeState.waitingReadyReason = reason;
            bridgeStateChange('WAITING_READY', 'Waiting for readyok (' + reason + ')...');
            sendEngineCommand('isready');
          }

          function beginQueuedSearch() {
            if (!bridgeState.queuedRequest) {
              bridgeStateChange('READY', 'Stockfish ready.');
              bridgePost({ type: 'ready', reason: 'Stockfish ready.' });
              return;
            }

            if (bridgeState.needsNewGame) {
              bridgeState.needsNewGame = false;
              sendEngineCommand('ucinewgame');
              requestReady('after-ucinewgame');
              return;
            }

            requestReady('before-search');
          }

          function startSearch(request) {
            bridgeState.currentRequest = {
              id: request.id,
              fen: request.fen,
              movetimeMs: request.movetimeMs,
              debugDepth: request.debugDepth || null,
              multiPV: Math.max(1, request.multiPV || 1),
              searchMoves: Array.isArray(request.searchMoves) ? request.searchMoves.filter(Boolean) : null,
              startedAtMs: Date.now(),
              scoreCp: null,
              mateIn: null,
              pv: [],
              candidates: {},
            };
            bridgeState.queuedRequest = null;
            const searchLabel = request.debugDepth ? ('Analyzing depth ' + request.debugDepth + '...') : ('Analyzing movetime ' + request.movetimeMs + 'ms...');
            bridgeStateChange('THINKING', searchLabel);
            sendEngineCommand('setoption name MultiPV value ' + bridgeState.currentRequest.multiPV);
            sendEngineCommand('position fen ' + request.fen);
            const searchMovesSuffix = bridgeState.currentRequest.searchMoves && bridgeState.currentRequest.searchMoves.length > 0
              ? (' searchmoves ' + bridgeState.currentRequest.searchMoves.join(' '))
              : '';
            if (request.debugDepth) {
              sendEngineCommand('go depth ' + request.debugDepth + searchMovesSuffix);
            } else {
              sendEngineCommand('go movetime ' + request.movetimeMs + searchMovesSuffix);
            }
          }

          function cancelCurrentAnalysis(reason) {
            bridgeState.queuedRequest = null;
            if (!bridgeState.currentRequest) {
              bridgeStateChange('READY', 'Search cancelled before dispatch.');
              bridgePost({ type: 'ready', reason: 'Search cancelled before dispatch.' });
              return true;
            }

            bridgeState.currentRequest.cancelled = true;
            bridgeStatus('Stopping current search (' + (reason || 'cancelled') + ')...');
            sendEngineCommand('stop');
            requestReady('after-stop');
            return true;
          }

          function parseInfoLine(line) {
            const current = bridgeState.currentRequest;
            if (!current) {
              return;
            }

            const multipvMatch = line.match(/\\smultipv\\s(\\d+)/);
            const rank = multipvMatch ? parseInt(multipvMatch[1], 10) : 1;
            // Stockfish emits many incremental info updates per rank while searching. We keep
            // only the latest snapshot for each multipv rank and publish the set once bestmove
            // arrives, which prevents intermediate search spam from masquerading as final lines.
            const candidate = current.candidates[rank] || {
              rank,
              scoreCp: null,
              mateIn: null,
              depth: 0,
              pv: [],
            };

            const depthMatch = line.match(/\\sdepth\\s(\\d+)/);
            if (depthMatch) {
              candidate.depth = parseInt(depthMatch[1], 10);
            }

            const cpMatch = line.match(/score cp (-?\\d+)/);
            if (cpMatch) {
              candidate.scoreCp = parseInt(cpMatch[1], 10);
              candidate.mateIn = null;
              if (rank === 1) {
                current.scoreCp = candidate.scoreCp;
                current.mateIn = null;
              }
            }

            const mateMatch = line.match(/score mate (-?\\d+)/);
            if (mateMatch) {
              candidate.mateIn = parseInt(mateMatch[1], 10);
              candidate.scoreCp = null;
              if (rank === 1) {
                current.mateIn = candidate.mateIn;
                current.scoreCp = null;
              }
            }

            const pvMatch = line.match(/\\spv\\s(.+)/);
            if (pvMatch) {
              candidate.pv = pvMatch[1].trim().split(/\\s+/).filter(Boolean);
              if (rank === 1) {
                current.pv = candidate.pv;
              }
            }

            current.candidates[rank] = candidate;
          }

          function handleEngineLine(message) {
            const line = String(message && message.data !== undefined ? message.data : message);
            logLine(line);

            if (line === 'uciok') {
              bridgeStateChange('WAITING_READY', 'uciok received. Configuring engine...');
              sendEngineCommand('setoption name UCI_AnalyseMode value true');
              sendEngineCommand('setoption name Threads value \(config.threads)');
              sendEngineCommand('setoption name Hash value \(config.hashMB)');
              sendEngineCommand('setoption name Ponder value false');
              requestReady('startup');
              return;
            }

            if (line === 'readyok') {
              bridgeState.ready = true;
              const waitingReason = bridgeState.waitingReadyReason;
              bridgeState.waitingReadyReason = null;

              if (waitingReason === 'startup') {
                bridgeStateChange('READY', 'Stockfish ready.');
                bridgePost({ type: 'ready', reason: 'Stockfish ready.' });
                return;
              }

              if (waitingReason === 'after-stop') {
                bridgeState.currentRequest = null;
                beginQueuedSearch();
                return;
              }

              if (waitingReason === 'after-ucinewgame' || waitingReason === 'before-search') {
                if (!bridgeState.queuedRequest) {
                  bridgeStateChange('READY', 'Stockfish ready.');
                  bridgePost({ type: 'ready', reason: 'Stockfish ready.' });
                  return;
                }

                startSearch(bridgeState.queuedRequest);
                return;
              }

              bridgeStateChange('READY', 'Stockfish ready.');
              bridgePost({ type: 'ready', reason: 'Stockfish ready.' });
              return;
            }

            if (line.startsWith('info ')) {
              parseInfoLine(line);
              return;
            }

            if (line.startsWith('bestmove ')) {
              const finished = bridgeState.currentRequest;
              const parts = line.trim().split(/\\s+/);
              bridgeState.currentRequest = null;

              if (!finished) {
                beginQueuedSearch();
                return;
              }

              if (finished.cancelled) {
                beginQueuedSearch();
                return;
              }

              const candidates = Object.values(finished.candidates || {})
                .sort((left, right) => (left.rank || 1) - (right.rank || 1))
                .map((candidate) => ({
                  rank: candidate.rank || 1,
                  scoreCp: candidate.scoreCp ?? null,
                  mateIn: candidate.mateIn ?? null,
                  depth: candidate.depth || 0,
                  pv: candidate.pv || [],
                  move: candidate.pv && candidate.pv.length > 0 ? candidate.pv[0] : null,
                }));

              bridgePost({
                type: 'result',
                id: finished.id,
                scoreCp: finished.scoreCp,
                mateIn: finished.mateIn,
                pv: finished.pv || [],
                bestMove: parts[1] || null,
                candidates,
                durationMs: Date.now() - finished.startedAtMs,
                status: parts[1] ? 'bestmove ' + parts[1] : 'bestmove unavailable',
              });
              beginQueuedSearch();
            }
          }

          window.__archessAnalyze = function(payload) {
            const request = typeof payload === 'string' ? JSON.parse(payload) : payload;
            bridgeState.queuedRequest = request;
            if (bridgeState.state === 'THINKING' && bridgeState.currentRequest) {
              bridgeStatus('Stopping previous search for newer board state...');
              bridgeState.currentRequest.cancelled = true;
              sendEngineCommand('stop');
              requestReady('after-stop');
              return true;
            }

            if (bridgeState.state === 'READY') {
              beginQueuedSearch();
              return true;
            }

            bridgeStatus('Queued analysis request ' + request.id + '.');
            return true;
          };

          window.__archessCancelCurrentAnalysis = function(reason) {
            return cancelCurrentAnalysis(reason);
          };

          window.__archessNewGame = function() {
            bridgeState.needsNewGame = true;
            bridgeStatus('Marked next analysis as a new game.');
            return true;
          };

          window.__archessDumpDiagnostics = function() {
            return JSON.stringify({
              state: bridgeState.state,
              waitingReadyReason: bridgeState.waitingReadyReason,
              currentRequest: bridgeState.currentRequest,
              queuedRequest: bridgeState.queuedRequest,
              commands: bridgeState.lastCommands,
              lines: bridgeState.lastLines,
            });
          };

          bootStockfish();
        </script>
      </head>
      <body></body>
    </html>
    """
  }

  private static func hashFEN(_ fen: String) -> String {
    let digest = SHA256.hash(data: Data(fen.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
  }
}

@MainActor
private final class PiecePersonalityDirector: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
  private enum EngineReplySelection {
    case best
    case reviewThirdBest
  }

  private static let preferredMovetimeMs = 80
  private static let preferredHardTimeoutMs = 600
  private static let substantialGainThreshold = 120
  private static let substantialDropThreshold = -140
  // The passive narrator ramps by 10 percentage points after each normal move where the
  // narrator stays silent. We evaluate the next move at `(storedTurns + 1) * increment`
  // so the first eligible post-narrator move starts at 10%.
  private static let narratorChanceRampIncrement = 0.10
  private static let ambientPieceVoiceLineChance = 0.35
  private static let underutilizedSnarkMinimumMovesPerPlayer = 6
  private static let underutilizedSnarkTriggerChance = 0.25
  private static let underutilizedSnarkPoolSize = 5
  private static let defaultPieceHistoryReactiveChancePercent = 60
  private static let defaultNarratorPieceReactiveChancePercent = 40
  private static let pieceDialogueHistoryWindow = 4
  private static let pieceVoiceLineCharacterLimit = 180
  private static let passiveNarratorCharacterLimit = 220
  private static let speechPrewarmDelayNanoseconds: UInt64 = 250_000_000
  private static let pieceVoicePrewarmDelayNanoseconds: UInt64 = experienceStartupRemoteWorkDelayNanoseconds
  private static let urgentPieceVoiceSFXOverlapAllowance: TimeInterval = 0.16
  private static let pieceVoiceWarmupContext = GeminiPieceVoiceLineContext(
    fen: ChessGameState.initial().fenString,
    pieceType: .pawn,
    pieceColor: .white,
    recentLines: [],
    dialogueMode: .independent,
    pieceDialogueHistory: [],
    latestPieceLine: nil,
    contextMode: .moved,
    fromSquare: BoardSquare(file: 4, rank: 1),
    toSquare: BoardSquare(file: 4, rank: 3),
    isCapture: false,
    isCheck: false,
    isNearEnemyKing: false,
    isAttacked: false,
    isAttackedByMultiple: false,
    isDefended: true,
    isWellDefended: false,
    isHanging: false,
    isPinned: false,
    isRetreat: false,
    isAggressiveAdvance: true,
    isForkThreat: false,
    attackerCount: 0,
    defenderCount: 1,
    evalBefore: 0,
    evalAfter: 18,
    evalDelta: 18,
    positionState: .equal,
    moveQuality: .aggressive,
    pieceMoveCount: 0,
    underutilizedReason: nil
  )

  struct ReactionCue {
    enum Kind {
      case enemyKingPrays(color: ChessColor)
      case currentKingCries(color: ChessColor)
      case knightFork(targets: [BoardSquare])
    }

    let kind: Kind
  }

  struct Caption {
    let speaker: PersonalitySpeaker?
    let speakerName: String
    let line: String
    let imageAssetName: String?

    init(speaker: PersonalitySpeaker, line: String) {
      self.speaker = speaker
      self.speakerName = speaker.displayName
      self.line = line
      self.imageAssetName = nil
    }

    init(title: String, line: String, imageAssetName: String) {
      self.speaker = nil
      self.speakerName = title
      self.line = line
      self.imageAssetName = imageAssetName
    }
  }

  private enum GeneratedNarrationStyle {
    case gemini(title: String)
    case automaticNarrator
    case pieceVoice(speaker: PersonalitySpeaker)
  }

  private struct PieceVoiceRequestPlan {
    let speaker: PersonalitySpeaker
    let context: GeminiPieceVoiceLineContext
    let label: String
  }

  private enum AutomaticCommentaryTrigger {
    case opening(state: ChessGameState)
    case move(move: ChessMove, before: ChessGameState, after: ChessGameState)
  }

  private struct AutomaticCommentaryDecision {
    enum Kind {
      case narrator
      case piece
      case silent
    }

    let kind: Kind
    let narratorContext: GeminiPassiveNarratorLineContext?
    let piecePlan: PieceVoiceRequestPlan?
    let piecePriority: SpeechPriority?
    let incrementsNarratorRamp: Bool
    let resetsNarratorRamp: Bool
    let marksOpeningNarrationDelivered: Bool
    let reason: String
  }

  private struct UnderutilizedPieceCandidate {
    let square: BoardSquare
    let piece: ChessPieceState
    let moveCount: Int
    let mobility: Int
    let underutilizedReason: String
  }

  private struct AutomaticDialoguePlaybackRecord {
    let entry: AutonomousDialogueMemoryEntry
    let stackLine: String
    let highlightedSquare: BoardSquare?
  }

  private struct PendingGeneratedNarration {
    let text: String
    let style: GeneratedNarrationStyle
    let playbackRecord: AutomaticDialoguePlaybackRecord?
  }

  private enum CommentaryCaptionOwner: Equatable {
    case none
    case utterance(ObjectIdentifier)
    case automaticPlayback(UUID)
  }

  private enum AutomaticPlaybackSource {
    case none
    case geminiPassiveNarrator
    case piperAutomatic
  }

  @Published private(set) var caption: Caption?
  @Published private(set) var analysisStatus = "Waiting for AR tracking to settle before warming Stockfish..."
  @Published private(set) var latestAssessment = "Waiting for initial analysis."
  @Published private(set) var suggestedMoveText = "Next best move: waiting on Stockfish..."
  @Published private(set) var whiteEvalText = "White eval: --"
  @Published private(set) var blackEvalText = "Black eval: --"
  @Published private(set) var analysisTimingText = "No completed analysis yet."
  @Published private(set) var hintStatusText = "Fun hints warm up in the background when it is your turn."
  @Published private(set) var visibleHintText: String?
  @Published private(set) var isHintLoading = false
  @Published private(set) var geminiDebugLines: [String] = []
  @Published private(set) var coachLines: [String] = []
  @Published private(set) var pieceVoiceLines: [String] = []
  @Published private(set) var pieceVoiceStatusText = "Waiting for a move."
  @Published private(set) var pieceDialogueModeStatusText = "Piece dialogue mode: waiting for a line."
  @Published private(set) var narratorDialogueModeStatusText = "Narrator dialogue mode: waiting for a line."
  @Published private(set) var pieceHistoryReactiveChancePercent = 60
  @Published private(set) var narratorPieceReactiveChancePercent = 40
  @Published private(set) var topWorkers: [GeminiPieceRole] = []
  @Published private(set) var topTraitors: [GeminiPieceRole] = []
  @Published private(set) var stockfishDebugStatusText = "Open Stockfish debug to inspect engine candidates."
  @Published private(set) var stockfishDebugWhiteMoves: [StockfishCandidate] = []
  @Published private(set) var stockfishDebugBlackMoves: [StockfishCandidate] = []
  @Published private(set) var geminiConnectionState: GeminiLiveStatusPayload.ConnectionState = .disconnected
  @Published private(set) var geminiConnectionLastError: String?
  @Published private(set) var geminiConnectionSince: String?

  private let analyzer = StockfishWASMAnalyzer()
  private let hintService = GeminiHintService()
  private let synthesizer = AVSpeechSynthesizer()
  private let narrator: NarratorType
  private let passiveNarratorLiveSpeaker: GeminiPassiveNarratorLiveSpeaker
  private let piperAutomaticSpeaker = PiperAutomaticSpeaker()
  private var utteranceCaptions: [ObjectIdentifier: Caption] = [:]
  private var utteranceStyles: [ObjectIdentifier: GeneratedNarrationStyle] = [:]
  private var utteranceAutomaticDialogueRecords: [ObjectIdentifier: AutomaticDialoguePlaybackRecord] = [:]
  private var narrationHighlightHandler: (([String], String?) -> Void)?
  private var pieceAudioBusyDurationProvider: (() -> TimeInterval)?
  private var passiveCommentarySuppressionProvider: (() -> Bool)?
  private var cachedAnalysis: CachedAnalysis?
  private var stockfishDebugAnalysisCache: [String: StockfishAnalysis] = [:]
  private var reactionHandler: ((ReactionCue) -> Void)?
  private var stateProvider: (() -> ChessGameState?)?
  private var hintAvailabilityProvider: (() -> Bool)?
  private var recentHistoryProvider: (() -> String?)?
  private var hintTask: Task<Void, Never>?
  private var geminiStatusTask: Task<Void, Never>?
  private var engineWarmupTask: Task<Void, Never>?
  private var hasPreparedEngine = false
  private var hintCache: [String: String] = [:]
  private var currentHintKey: String?
  private var pendingHintReveal = false
  private var pendingHintNarration = false
  private var narratedHintKeys: Set<String> = []
  private var pendingGeneratedNarrations: [PendingGeneratedNarration] = []
  private var narrationSessionID = 0
  private var geminiNarrationRetryWorkItem: DispatchWorkItem?
  private var lastGeminiStatusSnapshot: GeminiLiveStatusPayload?
  private var nextGeminiBackgroundRetryAt: Date?
  private var nextGeminiCoachRetryAt: Date?
  private var latestAnalyzedFEN: String?
  private var pendingCommentaryFEN: String?
  private var latestCommentaryRequestID = 0
  private var commentaryRequestTask: Task<Void, Never>?
  private var stockfishDebugVisible = false
  private var speechPrewarmTask: Task<Void, Never>?
  private var pieceVoicePrewarmTask: Task<Void, Never>?
  private var automaticCommentaryRequestTask: Task<Void, Never>?
  private var hasPrewarmedSpeechPath = false
  private var hasPrewarmedPieceVoicePath = false
  private var silentSpeechWarmupUtteranceIDs: Set<ObjectIdentifier> = []
  private var latestAutomaticCommentaryRequestID = 0
  private var turnsSinceNarratorLine = 0
  private var openingNarrationDelivered = false
  private var queuedAutomaticCommentaryDecision: AutomaticCommentaryDecision?
  private var activeAutomaticPlaybackSource: AutomaticPlaybackSource = .none
  private var liveNarratorPlaybackOwnsCaption = false
  private var activePassiveAutomaticPlaybackRecord: AutomaticDialoguePlaybackRecord?
  private var activePassiveAutomaticPlaybackDidStart = false
  private var activeAutomaticPlaybackCaptionToken: UUID?
  private var commentaryCaptionOwner: CommentaryCaptionOwner = .none
  private var autonomousDialogueMemory: [AutonomousDialogueMemoryEntry] = []
  private var trackedPieceInstanceIDsBySquare: [BoardSquare: String] = [:]
  private var trackedPieceMoveCountsByID: [String: Int] = [:]
  private var nextTrackedPieceInstanceSerial = 0

  init(narrator: NarratorType = .silky) {
    self.narrator = narrator
    self.passiveNarratorLiveSpeaker = GeminiPassiveNarratorLiveSpeaker(narrator: narrator)
    super.init()
    synthesizer.delegate = self
    hintStatusText = defaultHintStatus()
    passiveNarratorLiveSpeaker.onPlaybackActivityChange = { [weak self] _, isActive in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .geminiPassiveNarrator else {
          return
        }
        guard isActive,
              !self.activePassiveAutomaticPlaybackDidStart,
              let playbackRecord = self.activePassiveAutomaticPlaybackRecord else {
          return
        }
        self.activePassiveAutomaticPlaybackDidStart = true
        self.beginAutomaticDialoguePlayback(playbackRecord)
      }
    }
    passiveNarratorLiveSpeaker.onBusyStateChange = { [weak self] isBusy in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .geminiPassiveNarrator else {
          return
        }
        if !isBusy, self.liveNarratorPlaybackOwnsCaption {
          if self.activePassiveAutomaticPlaybackDidStart,
             let playbackRecord = self.activePassiveAutomaticPlaybackRecord {
            self.endAutomaticDialoguePlayback(playbackRecord)
          }
          self.activePassiveAutomaticPlaybackRecord = nil
          self.activePassiveAutomaticPlaybackDidStart = false
          self.liveNarratorPlaybackOwnsCaption = false
          if let captionToken = self.activeAutomaticPlaybackCaptionToken {
            self.clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
          }
          self.activeAutomaticPlaybackCaptionToken = nil
          self.activeAutomaticPlaybackSource = .none
          self.flushPendingGeneratedNarrationIfPossible()
          self.flushQueuedAutomaticCommentaryDecisionIfPossible()
        }
      }
    }
    passiveNarratorLiveSpeaker.onLineFailure = { [weak self] request, message in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .geminiPassiveNarrator else {
          return
        }
        self.appendGeminiDebug(
          "Gemini passive automatic audio failed: \(message). Falling back to local speech."
        )
        let playbackRecord = self.activePassiveAutomaticPlaybackRecord
        self.activePassiveAutomaticPlaybackRecord = nil
        self.activePassiveAutomaticPlaybackDidStart = false
        self.liveNarratorPlaybackOwnsCaption = false
        if let captionToken = self.activeAutomaticPlaybackCaptionToken {
          self.clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
        }
        self.activeAutomaticPlaybackCaptionToken = nil
        self.activeAutomaticPlaybackSource = .none
        switch request.role {
        case .narrator:
          self.pieceVoiceStatusText = "Narrator Gemini Live unavailable. Using local fallback."
          _ = self.startLocalAutomaticNarratorUtterance(
            text: request.line,
            playbackRecord: playbackRecord
          )
        case .piece:
          self.setSpeakingPieceHighlight(square: nil)
          guard let speakerName = request.speakerName,
                let speaker = self.personalitySpeaker(named: speakerName) else {
            self.pieceVoiceStatusText = "Piece Gemini Live unavailable."
            self.flushQueuedAutomaticCommentaryDecisionIfPossible()
            return
          }
          self.pieceVoiceStatusText = "\(speaker.displayName) Gemini Live unavailable. Using local fallback."
          _ = self.startLocalPieceVoiceUtterance(
            text: request.line,
            speaker: speaker,
            playbackRecord: playbackRecord
          )
        }
        self.flushQueuedAutomaticCommentaryDecisionIfPossible()
      }
    }
    piperAutomaticSpeaker.onPlaybackActivityChange = { [weak self] _, isActive in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .piperAutomatic else {
          return
        }
        guard isActive,
              !self.activePassiveAutomaticPlaybackDidStart,
              let playbackRecord = self.activePassiveAutomaticPlaybackRecord else {
          return
        }
        self.activePassiveAutomaticPlaybackDidStart = true
        self.beginAutomaticDialoguePlayback(playbackRecord)
      }
    }
    piperAutomaticSpeaker.onBusyStateChange = { [weak self] isBusy in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .piperAutomatic else {
          return
        }
        if !isBusy, self.liveNarratorPlaybackOwnsCaption {
          if self.activePassiveAutomaticPlaybackDidStart,
             let playbackRecord = self.activePassiveAutomaticPlaybackRecord {
            self.endAutomaticDialoguePlayback(playbackRecord)
          }
          self.activePassiveAutomaticPlaybackRecord = nil
          self.activePassiveAutomaticPlaybackDidStart = false
          self.liveNarratorPlaybackOwnsCaption = false
          if let captionToken = self.activeAutomaticPlaybackCaptionToken {
            self.clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
          }
          self.activeAutomaticPlaybackCaptionToken = nil
          self.activeAutomaticPlaybackSource = .none
          self.flushPendingGeneratedNarrationIfPossible()
          self.flushQueuedAutomaticCommentaryDecisionIfPossible()
        }
      }
    }
    piperAutomaticSpeaker.onVoicePrepared = { [weak self] request, preparedLine in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        let cacheSource = preparedLine.cacheHit ? "cache hit" : "fresh synth"
        self.appendGeminiDebug(
          "Piper ready for \(request.line.speakerType.rawValue) using \(preparedLine.resolvedSpeakerType.rawValue) voice (\(cacheSource))."
        )
        if preparedLine.usedFallbackVoice {
          self.appendGeminiDebug(
            "Piper fell back from \(request.line.speakerType.rawValue) to \(preparedLine.resolvedSpeakerType.rawValue) because the configured voice model was unavailable."
          )
        }
      }
    }
    piperAutomaticSpeaker.onLineFailure = { [weak self] request, message in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard self.activeAutomaticPlaybackSource == .piperAutomatic else {
          return
        }
        self.appendGeminiDebug(
          "Piper automatic audio failed: \(message). Falling back to local speech."
        )
        let playbackRecord = self.activePassiveAutomaticPlaybackRecord
        self.activePassiveAutomaticPlaybackRecord = nil
        self.activePassiveAutomaticPlaybackDidStart = false
        self.liveNarratorPlaybackOwnsCaption = false
        if let captionToken = self.activeAutomaticPlaybackCaptionToken {
          self.clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
        }
        self.activeAutomaticPlaybackCaptionToken = nil
        self.activeAutomaticPlaybackSource = .none

        switch request.line.speakerType {
        case .narrator:
          self.pieceVoiceStatusText = "Narrator Piper unavailable. Using local fallback."
          _ = self.startLocalAutomaticNarratorUtterance(
            text: request.line.text,
            playbackRecord: playbackRecord
          )
        case .pawn, .rook, .knight, .bishop, .queen, .king:
          self.setSpeakingPieceHighlight(square: nil)
          guard let speaker = self.personalitySpeaker(for: request.line.speakerType) else {
            self.pieceVoiceStatusText = "Piece Piper unavailable."
            self.flushQueuedAutomaticCommentaryDecisionIfPossible()
            return
          }
          self.pieceVoiceStatusText = "\(speaker.displayName) Piper unavailable. Using local fallback."
          _ = self.startLocalPieceVoiceUtterance(
            text: request.line.text,
            speaker: speaker,
            playbackRecord: playbackRecord
          )
        }
        self.flushQueuedAutomaticCommentaryDecisionIfPossible()
      }
    }
  }

  func attachEngineHost(to view: UIView) {
    analyzer.attach(to: view)
    prepareSpeechPathIfNeeded()
    preparePieceVoicePathIfNeeded()
  }

  func prepareEngineIfNeeded() {
    guard engineWarmupTask == nil, !hasPreparedEngine else {
      return
    }

    engineWarmupTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        self.engineWarmupTask = nil
      }

      do {
        try await self.analyzer.newGame()
        self.hasPreparedEngine = true
        guard self.cachedAnalysis == nil else {
          return
        }
        self.analysisStatus = "Local Stockfish is standing by."
        self.latestAssessment = "Board ready. Stockfish will wake on demand."
      } catch {
        guard self.cachedAnalysis == nil else {
          return
        }
        self.analysisStatus = "Stockfish will wake when needed."
        self.latestAssessment = "Board ready."
      }
    }
  }

  private func prepareSpeechPathIfNeeded() {
    guard speechPrewarmTask == nil, !hasPrewarmedSpeechPath else {
      return
    }

    speechPrewarmTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        self.speechPrewarmTask = nil
      }

      try? await Task.sleep(nanoseconds: Self.speechPrewarmDelayNanoseconds)
      do {
        try AudioSessionCoordinator.shared.activatePlaybackSession()
        _ = AVSpeechSynthesisVoice(language: "en-US")
        self.prewarmSpeechSynthesizerIfNeeded()
        self.passiveNarratorLiveSpeaker.prewarmIfNeeded()
        self.piperAutomaticSpeaker.prepareIfNeeded()
        self.hasPrewarmedSpeechPath = true
      } catch {
        return
      }
    }
  }

  private func preparePieceVoicePathIfNeeded() {
    guard hintService.isConfigured,
          pieceVoicePrewarmTask == nil,
          !hasPrewarmedPieceVoicePath else {
      return
    }

    pieceVoicePrewarmTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        self.pieceVoicePrewarmTask = nil
      }

      try? await Task.sleep(nanoseconds: Self.pieceVoicePrewarmDelayNanoseconds)
      guard !Task.isCancelled else {
        return
      }

      do {
        _ = try await self.hintService.fetchPieceVoiceLine(for: Self.pieceVoiceWarmupContext)
        self.hasPrewarmedPieceVoicePath = true
        self.appendGeminiDebug("Prewarmed Gemini piece voice path during startup.")
      } catch is CancellationError {
        return
      } catch {
        self.appendGeminiDebug("Gemini piece voice prewarm skipped: \(error.localizedDescription)")
      }
    }
  }

  private func prewarmSpeechSynthesizerIfNeeded() {
    guard !synthesizer.isSpeaking else {
      return
    }

    let utterance = AVSpeechUtterance(string: "Voice systems ready.")
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.pitchMultiplier = 1.0
    utterance.rate = 0.47
    utterance.volume = 0.0
    utterance.preUtteranceDelay = 0

    let utteranceID = ObjectIdentifier(utterance)
    silentSpeechWarmupUtteranceIDs.insert(utteranceID)
    synthesizer.speak(utterance)
  }

  func prepare(with state: ChessGameState, force: Bool = false) async {
    let fen = state.fenString
    guard force || cachedAnalysis?.fen != fen else {
      return
    }

    do {
      let analysis = try await analyzer.analyze(
        fen: fen,
        options: .realtime(
          movetimeMs: Self.preferredMovetimeMs,
          hardTimeoutMs: Self.preferredHardTimeoutMs,
          multiPV: StockfishAnalysisDefaults.multiPV
        )
      )
      cachedAnalysis = CachedAnalysis(fen: fen, analysis: analysis)
      updateAnalysisPresentation(analysis)
      analysisStatus = "Stockfish movetime \(Self.preferredMovetimeMs)ms ready."
      latestAssessment = "Prep eval: \(describe(analysis: analysis, moverColor: state.turn))."
      await refreshStockfishDebugMoves(for: state, currentAnalysis: analysis, force: force)
      prefetchHint(for: state, analysis: analysis)
      scheduleCoachCommentary(for: state)
    } catch {
      let message = analyzer.lastError ?? error.localizedDescription
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(message)"
      suggestedMoveText = "Next best move unavailable."
      whiteEvalText = "White eval: --"
      blackEvalText = "Black eval: --"
      analysisTimingText = "Analysis failed."
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = hintService.isConfigured
        ? "Hint unavailable until Stockfish finishes."
        : defaultHintStatus()
      if stockfishDebugVisible {
        stockfishDebugStatusText = "Stockfish debug unavailable: \(message)"
        stockfishDebugWhiteMoves = []
        stockfishDebugBlackMoves = []
      }
    }
  }

  func resetSession() {
    synthesizer.stopSpeaking(at: .immediate)
    piperAutomaticSpeaker.stop()
    utteranceCaptions.removeAll()
    utteranceStyles.removeAll()
    utteranceAutomaticDialogueRecords.removeAll()
    passiveNarratorLiveSpeaker.disconnect()
    geminiNarrationRetryWorkItem?.cancel()
    geminiNarrationRetryWorkItem = nil
    pendingGeneratedNarrations.removeAll()
    narrationSessionID += 1
    clearCommentaryCaption()
    narrationHighlightHandler?([], "Speaking piece")
    cachedAnalysis = nil
    stockfishDebugAnalysisCache.removeAll()
    hintTask?.cancel()
    hintTask = nil
    commentaryRequestTask?.cancel()
    commentaryRequestTask = nil
    automaticCommentaryRequestTask?.cancel()
    automaticCommentaryRequestTask = nil
    geminiStatusTask?.cancel()
    geminiStatusTask = nil
    engineWarmupTask?.cancel()
    engineWarmupTask = nil
    hasPreparedEngine = false
    recentHistoryProvider = nil
    hintCache.removeAll()
    currentHintKey = nil
    pendingHintReveal = false
    pendingHintNarration = false
    narratedHintKeys.removeAll()
    lastGeminiStatusSnapshot = nil
    geminiDebugLines = []
    coachLines = []
    pieceVoiceLines = []
    pieceVoiceStatusText = "Waiting for a move."
    pieceDialogueModeStatusText = "Piece dialogue mode: waiting for a line."
    narratorDialogueModeStatusText = "Narrator dialogue mode: waiting for a line."
    autonomousDialogueMemory = []
    trackedPieceInstanceIDsBySquare = [:]
    trackedPieceMoveCountsByID = [:]
    nextTrackedPieceInstanceSerial = 0
    latestAutomaticCommentaryRequestID = 0
    queuedAutomaticCommentaryDecision = nil
    activeAutomaticPlaybackSource = .none
    liveNarratorPlaybackOwnsCaption = false
    activePassiveAutomaticPlaybackRecord = nil
    activePassiveAutomaticPlaybackDidStart = false
    activeAutomaticPlaybackCaptionToken = nil
    topWorkers = []
    topTraitors = []
    stockfishDebugStatusText = "Open Stockfish debug to inspect engine candidates."
    stockfishDebugWhiteMoves = []
    stockfishDebugBlackMoves = []
    visibleHintText = nil
    isHintLoading = false
    turnsSinceNarratorLine = 0
    openingNarrationDelivered = false
    nextGeminiCoachRetryAt = nil
    latestAnalyzedFEN = nil
    pendingCommentaryFEN = nil
    latestCommentaryRequestID = 0
    analyzer.reset()
    analysisStatus = "Waiting for AR tracking to settle before warming Stockfish..."
    latestAssessment = "Waiting for initial analysis."
    suggestedMoveText = "Next best move: waiting on Stockfish..."
    whiteEvalText = "White eval: --"
    blackEvalText = "Black eval: --"
    analysisTimingText = "No completed analysis yet."
    hintStatusText = defaultHintStatus()
    geminiConnectionState = hintService.isConfigured ? .disconnected : .error
    geminiConnectionLastError = hintService.isConfigured ? nil : "ARChessAPIBaseURL is not configured."
    geminiConnectionSince = nil
    stockfishDebugVisible = false
  }

  func noteExternalStatus(_ message: String) {
    latestAssessment = message
  }

  func noteWarmupStatus(_ message: String) {
    guard cachedAnalysis == nil else {
      return
    }

    analysisStatus = message
  }

  func bindStateProvider(_ provider: @escaping () -> ChessGameState?) {
    stateProvider = provider
    startGeminiStatusMonitoring()
  }

  func unbindStateProvider() {
    stateProvider = nil
    geminiStatusTask?.cancel()
    geminiStatusTask = nil
  }

  func bindHintAvailabilityProvider(_ provider: @escaping () -> Bool) {
    hintAvailabilityProvider = provider
  }

  func unbindHintAvailabilityProvider() {
    hintAvailabilityProvider = nil
  }

  func bindRecentHistoryProvider(_ provider: @escaping () -> String?) {
    recentHistoryProvider = provider
  }

  func unbindRecentHistoryProvider() {
    recentHistoryProvider = nil
  }

  func bindPassiveCommentarySuppressionProvider(_ provider: @escaping () -> Bool) {
    passiveCommentarySuppressionProvider = provider
  }

  func unbindPassiveCommentarySuppressionProvider() {
    passiveCommentarySuppressionProvider = nil
  }

  func bindPieceAudioBusyDurationProvider(_ provider: @escaping () -> TimeInterval) {
    pieceAudioBusyDurationProvider = provider
  }

  func unbindPieceAudioBusyDurationProvider() {
    pieceAudioBusyDurationProvider = nil
    geminiNarrationRetryWorkItem?.cancel()
    geminiNarrationRetryWorkItem = nil
    pendingGeneratedNarrations.removeAll()
  }

  func analyzeCurrentPosition() async {
    guard let state = stateProvider?() else {
      latestAssessment = "No board state available for manual analysis."
      return
    }

    analysisStatus = "Manual analysis requested..."
    await prepare(with: state, force: true)
  }

  func fishingRewardMoveLines(limit: Int = 5) async -> [String] {
    guard let state = stateProvider?() else {
      return [
        "1. No board state was available for Stockfish.",
        "2. Try casting again after the board settles.",
      ]
    }

    guard let analysis = await analysisForCurrentTurn(state: state) else {
      return [
        "1. Stockfish is still thinking.",
        "2. Cast again once the engine has a fresh line.",
      ]
    }

    let candidates = Array(analysis.topUniqueMoves.prefix(max(1, limit)))
    guard !candidates.isEmpty else {
      return [
        "1. Stockfish returned no candidate moves.",
        "2. Try another cast from a new position.",
      ]
    }

    return candidates.map { candidate in
      let move = fishingReadableMove(candidate.move ?? "(none)")
      let preview = candidate.pvPreview.prefix(3).map(fishingReadableMove).joined(separator: " -> ")
      let pvSuffix = preview.isEmpty ? "pv: —" : "pv: \(preview)"
      return "\(candidate.rank). \(move) | \(candidate.formattedScore) | \(pvSuffix)"
    }
  }

  func stockfishRank(for move: ChessMove, before state: ChessGameState) async -> Int? {
    guard let analysis = await analysisForCurrentTurn(state: state) else {
      return nil
    }

    return analysis.topUniqueMoves.first(where: { $0.move == move.uciString })?.rank
  }

  func isTopFiveStockfishMove(_ move: ChessMove, before state: ChessGameState) async -> Bool {
    await stockfishRank(for: move, before: state) != nil
  }

  func gameplayReplyMove(for state: ChessGameState) async -> ChessMove? {
    await engineReplyMove(for: state, selection: .best)
  }

  func reviewReplyMove(for state: ChessGameState) async -> ChessMove? {
    await engineReplyMove(for: state, selection: .reviewThirdBest)
  }

  private func fishingReadableMove(_ uci: String) -> String {
    guard uci.count >= 4 else {
      return uci
    }

    let from = String(uci.prefix(2))
    let to = String(uci.dropFirst(2).prefix(2))
    guard uci.count > 4 else {
      return "\(from) to \(to)"
    }

    let promotion = String(uci.suffix(1)).lowercased()
    let promotionName: String
    switch promotion {
    case "q":
      promotionName = "queen"
    case "r":
      promotionName = "rook"
    case "b":
      promotionName = "bishop"
    case "n":
      promotionName = "knight"
    default:
      promotionName = promotion
    }

    return "\(from) to \(to) = \(promotionName)"
  }

  private func engineReplyMove(
    for state: ChessGameState,
    selection: EngineReplySelection
  ) async -> ChessMove? {
    do {
      let analysis = try await analyzer.analyze(
        fen: state.fenString,
        options: .realtime(
          movetimeMs: Self.preferredMovetimeMs,
          hardTimeoutMs: Self.preferredHardTimeoutMs,
          multiPV: StockfishAnalysisDefaults.multiPV
        )
      )
      let preferredMove = preferredEngineCandidateMove(from: analysis, selection: selection)
      return preferredMove.flatMap { state.move(forUCI: $0) }
    } catch {
      return nil
    }
  }

  func setStockfishDebugVisible(_ isVisible: Bool) {
    stockfishDebugVisible = isVisible
    guard isVisible else {
      return
    }

    Task { @MainActor [weak self] in
      await self?.refreshStockfishDebugMoves(force: false)
    }
  }

  func setGeminiDebugVisible(_ isVisible: Bool) {
    setStockfishDebugVisible(isVisible)
  }

  func revealHint() {
    guard hintService.isConfigured else {
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = "Set ARChessAPIBaseURL to enable Gemini hints."
      appendGeminiDebug("Hint tap ignored because ARChessAPIBaseURL is not configured.")
      return
    }

    guard let state = stateProvider?() else {
      visibleHintText = nil
      hintStatusText = "No board state available for a hint yet."
      appendGeminiDebug("Hint tap ignored because there is no board state.")
      return
    }

    guard shouldPrefetchHint(for: state) else {
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = "Hints wake up when it is your turn."
      appendGeminiDebug("Hint tap ignored because it is not the local player's turn.")
      return
    }

    pendingHintReveal = true
    pendingHintNarration = true

    if let analysis = cachedAnalysis?.analysis, cachedAnalysis?.fen == state.fenString {
      appendGeminiDebug("Hint tapped with cached Stockfish analysis ready; attempting instant reveal and narration.")
      prefetchHint(for: state, analysis: analysis, revealWhenReady: true, narrateWhenReady: true, allowRepeatNarration: true)
      return
    }

    visibleHintText = nil
    isHintLoading = true
    hintStatusText = "Loading hint..."
    appendGeminiDebug("Hint tapped before cached analysis was ready; forcing analysis first.")
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      await self.prepare(with: state, force: true)
      if let analysis = self.cachedAnalysis?.analysis, self.cachedAnalysis?.fen == state.fenString {
        self.prefetchHint(for: state, analysis: analysis, revealWhenReady: true, narrateWhenReady: true, allowRepeatNarration: true)
      }
    }
  }

  func bindReactionHandler(_ handler: @escaping (ReactionCue) -> Void) {
    reactionHandler = handler
  }

  func unbindReactionHandler() {
    reactionHandler = nil
  }

  func bindNarrationHighlightHandler(_ handler: @escaping ([String], String?) -> Void) {
    narrationHighlightHandler = handler
  }

  func unbindNarrationHighlightHandler() {
    narrationHighlightHandler = nil
  }

  func maybeStartOpeningNarration(for state: ChessGameState) {
    triggerAutomaticCommentary(for: .opening(state: state))
  }

  func triggerAutomaticCommentaryForMove(
    move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState
  ) {
    triggerAutomaticCommentary(
      for: .move(move: move, before: beforeState, after: afterState)
    )
  }

  private func triggerAutomaticCommentary(for trigger: AutomaticCommentaryTrigger) {
    if case .move = trigger {
      discardPendingAutomaticCommentaryForNewMove()
    }
    prepareAutomaticCommentaryState(for: trigger)

    // Passive automatic commentary is mutually exclusive per event: narrator, piece, or silence.
    // The mic-driven coach flow remains separate and intentionally untouched.
    let decision = decideCommentaryEvent(for: trigger)
    guard !shouldQueueAutomaticCommentaryDecision(decision) else {
      queueAutomaticCommentaryDecision(decision)
      return
    }
    applyAutomaticCommentaryDecision(decision)
  }

  private func discardPendingAutomaticCommentaryForNewMove() {
    if automaticCommentaryRequestTask != nil {
      automaticCommentaryRequestTask?.cancel()
      automaticCommentaryRequestTask = nil
      latestAutomaticCommentaryRequestID += 1
      appendGeminiDebug("Cancelled stale automatic commentary request because a newer move arrived first.")
    }

    if queuedAutomaticCommentaryDecision != nil {
      queuedAutomaticCommentaryDecision = nil
      appendGeminiDebug("Dropped queued automatic commentary decision because a newer move superseded it.")
    }

    discardPendingAutomaticNarrations()
  }

  private func prepareAutomaticCommentaryState(for trigger: AutomaticCommentaryTrigger) {
    switch trigger {
    case .opening(let state):
      ensurePieceMoveTrackingMatches(state)
    case .move(let move, let beforeState, let afterState):
      ensurePieceMoveTrackingMatches(beforeState)
      applyMoveToPieceTracking(move: move, after: afterState)
    }
  }

  private func ensurePieceMoveTrackingMatches(_ state: ChessGameState) {
    let occupiedSquares = Set(state.board.keys)
    let trackedSquares = Set(trackedPieceInstanceIDsBySquare.keys)
    guard occupiedSquares == trackedSquares else {
      rebuildPieceMoveTracking(for: state)
      return
    }

    for square in occupiedSquares where trackedPieceInstanceIDsBySquare[square] == nil {
      rebuildPieceMoveTracking(for: state)
      return
    }
  }

  private func rebuildPieceMoveTracking(for state: ChessGameState) {
    trackedPieceInstanceIDsBySquare = [:]
    trackedPieceMoveCountsByID = [:]

    let orderedSquares = state.board.keys.sorted {
      if $0.rank == $1.rank {
        return $0.file < $1.file
      }
      return $0.rank < $1.rank
    }

    for square in orderedSquares {
      let pieceID = makeTrackedPieceInstanceID()
      trackedPieceInstanceIDsBySquare[square] = pieceID
      trackedPieceMoveCountsByID[pieceID] = 0
    }
  }

  private func makeTrackedPieceInstanceID() -> String {
    nextTrackedPieceInstanceSerial += 1
    return "piece_\(nextTrackedPieceInstanceSerial)"
  }

  private func applyMoveToPieceTracking(move: ChessMove, after afterState: ChessGameState) {
    guard let movingPieceID = trackedPieceInstanceIDsBySquare.removeValue(forKey: move.from) else {
      rebuildPieceMoveTracking(for: afterState)
      return
    }

    if let capturedSquare = trackingCapturedSquare(for: move) {
      trackedPieceInstanceIDsBySquare.removeValue(forKey: capturedSquare)
    }

    trackedPieceMoveCountsByID[movingPieceID, default: 0] += 1
    trackedPieceInstanceIDsBySquare[move.to] = movingPieceID

    if let rookMove = move.rookMove,
       let rookID = trackedPieceInstanceIDsBySquare.removeValue(forKey: rookMove.from) {
      trackedPieceMoveCountsByID[rookID, default: 0] += 1
      trackedPieceInstanceIDsBySquare[rookMove.to] = rookID
    }

    let survivingSquares = Set(afterState.board.keys)
    trackedPieceInstanceIDsBySquare = Dictionary(
      uniqueKeysWithValues: trackedPieceInstanceIDsBySquare.filter { survivingSquares.contains($0.key) }
    )

    if Set(trackedPieceInstanceIDsBySquare.keys) != survivingSquares {
      rebuildPieceMoveTracking(for: afterState)
    }
  }

  private func trackingCapturedSquare(for move: ChessMove) -> BoardSquare? {
    if move.isEnPassant {
      return BoardSquare(file: move.to.file, rank: move.from.rank)
    }
    return move.captured == nil ? nil : move.to
  }

  private func decideCommentaryEvent(for trigger: AutomaticCommentaryTrigger) -> AutomaticCommentaryDecision {
    switch trigger {
    case .opening(let state):
      guard !openingNarrationDelivered else {
        return silentAutomaticCommentaryDecision(reason: "Opening narration already delivered.")
      }
      guard !shouldSuppressPassiveCommentaryForCoach() else {
        return silentAutomaticCommentaryDecision(reason: "Coach is active; opening narration backed off.")
      }
      return AutomaticCommentaryDecision(
        kind: .narrator,
        narratorContext: buildPassiveNarratorLineContext(forOpening: state),
        piecePlan: nil,
        piecePriority: nil,
        incrementsNarratorRamp: false,
        resetsNarratorRamp: true,
        marksOpeningNarrationDelivered: true,
        reason: "Opening narration introduces the match."
      )
    case .move(let move, let beforeState, let afterState):
      let isCapture = move.captured != nil || move.isEnPassant
      if isCapture {
        // Captures exclusively use piece dialogue and do not reset the narrator ramp.
        // This keeps combat reactive while the narrator cadence continues across exchanges.
        return AutomaticCommentaryDecision(
          kind: .piece,
          narratorContext: nil,
          piecePlan: makePieceVoiceRequestPlan(
            move: move,
            before: beforeState,
            after: afterState,
            allowAmbient: false,
            allowUnderutilizedSnark: false
          ),
          piecePriority: .normal,
          incrementsNarratorRamp: false,
          resetsNarratorRamp: false,
          marksOpeningNarrationDelivered: false,
          reason: "Capture override forced piece dialogue."
        )
      }

      guard !shouldSuppressPassiveCommentaryForCoach() else {
        return silentAutomaticCommentaryDecision(
          incrementsNarratorRamp: true,
          reason: "Coach is active; passive commentary skipped for this turn."
        )
      }

      if !openingNarrationDelivered {
        return AutomaticCommentaryDecision(
          kind: .narrator,
          narratorContext: buildPassiveNarratorLineContext(forOpening: afterState),
          piecePlan: nil,
          piecePriority: nil,
          incrementsNarratorRamp: false,
          resetsNarratorRamp: true,
          marksOpeningNarrationDelivered: true,
          reason: "Opening narration had not fired yet, so this turn delivers it."
        )
      }

      if Double.random(in: 0..<1) < narratorChanceForNextEligibleTurn() {
        return AutomaticCommentaryDecision(
          kind: .narrator,
          narratorContext: buildPassiveNarratorLineContext(
            for: move,
            before: beforeState,
            after: afterState
          ),
          piecePlan: nil,
          piecePriority: nil,
          incrementsNarratorRamp: false,
          resetsNarratorRamp: true,
          marksOpeningNarrationDelivered: false,
          reason: "Narrator won the passive commentary ramp roll."
        )
      }

      // When the narrator does not win a normal move, the moved piece now always gets the line.
      let piecePlan = makePieceVoiceRequestPlan(
        move: move,
        before: beforeState,
        after: afterState,
        allowAmbient: false,
        allowUnderutilizedSnark: true
      )
      return AutomaticCommentaryDecision(
        kind: .piece,
        narratorContext: nil,
        piecePlan: piecePlan,
        piecePriority: .normal,
        incrementsNarratorRamp: true,
        resetsNarratorRamp: false,
        marksOpeningNarrationDelivered: false,
        reason: piecePlan.context.dialogueMode == .underutilizedSnark
          ? "Narrator passed; a neglected piece cuts in with underutilized snark."
          : "Narrator passed; the moved piece takes the line."
      )
    }
  }

  private func applyAutomaticCommentaryDecision(_ decision: AutomaticCommentaryDecision) {
    switch decision.kind {
    case .silent:
      if decision.incrementsNarratorRamp {
        turnsSinceNarratorLine += 1
      }
      pieceVoiceStatusText = "Silent turn."
      appendGeminiDebug("Automatic commentary silent: \(decision.reason)")
    case .piece:
      if decision.incrementsNarratorRamp {
        turnsSinceNarratorLine += 1
      }
      guard let plan = decision.piecePlan,
            let priority = decision.piecePriority else {
        return
      }
      requestPieceVoiceLine(plan, priority: priority, reason: decision.reason)
    case .narrator:
      guard let context = decision.narratorContext else {
        return
      }
      requestPassiveNarratorLine(
        context,
        resetsNarratorRamp: decision.resetsNarratorRamp,
        marksOpeningNarrationDelivered: decision.marksOpeningNarrationDelivered,
        reason: decision.reason
      )
    }
  }

  private func silentAutomaticCommentaryDecision(
    incrementsNarratorRamp: Bool = false,
    reason: String
  ) -> AutomaticCommentaryDecision {
    AutomaticCommentaryDecision(
      kind: .silent,
      narratorContext: nil,
      piecePlan: nil,
      piecePriority: nil,
      incrementsNarratorRamp: incrementsNarratorRamp,
      resetsNarratorRamp: false,
      marksOpeningNarrationDelivered: false,
      reason: reason
    )
  }

  private func narratorChanceForNextEligibleTurn() -> Double {
    min(1.0, Double(turnsSinceNarratorLine + 1) * Self.narratorChanceRampIncrement)
  }

  private func shouldSuppressPassiveCommentaryForCoach() -> Bool {
    passiveCommentarySuppressionProvider?() ?? false
  }

  private func shouldQueueAutomaticCommentaryDecision(_ decision: AutomaticCommentaryDecision) -> Bool {
    guard automaticCommentaryDecisionCanProduceSpeech(decision) else {
      return false
    }
    return hasAutomaticCommentaryInFlightOrQueued()
  }

  private func queueAutomaticCommentaryDecision(_ decision: AutomaticCommentaryDecision) {
    if decision.incrementsNarratorRamp {
      turnsSinceNarratorLine += 1
    }
    if decision.kind == .narrator, !decision.marksOpeningNarrationDelivered {
      turnsSinceNarratorLine += 1
    }

    // Passive automatic commentary never overlaps itself. Normal turns simply back off when another
    // auto line is already generating or speaking. Capture turns remain mandatory, so we retain only
    // the latest forced piece line and flush it once the active automatic line fully clears.
    if decision.kind == .piece, decision.piecePlan?.context.isCapture == true {
      queuedAutomaticCommentaryDecision = decision
      pieceVoiceStatusText = "Queued capture voice behind active commentary."
      appendGeminiDebug("Queued latest forced capture piece line because automatic commentary is already busy.")
      return
    }

    pieceVoiceStatusText = "Skipped overlapping auto commentary."
    appendGeminiDebug("Skipped automatic commentary because another passive line is already in flight.")
  }

  private func automaticCommentaryDecisionCanProduceSpeech(_ decision: AutomaticCommentaryDecision) -> Bool {
    switch decision.kind {
    case .silent:
      return false
    case .narrator, .piece:
      return true
    }
  }

  private func hasAutomaticCommentaryInFlightOrQueued() -> Bool {
    if automaticCommentaryRequestTask != nil {
      return true
    }

    if passiveNarratorLiveSpeaker.isBusy {
      return true
    }

    if piperAutomaticSpeaker.isBusy {
      return true
    }

    if pendingGeneratedNarrations.contains(where: { isPassiveAutomaticNarrationStyle($0.style) }) {
      return true
    }

    return utteranceStyles.values.contains(where: isPassiveAutomaticNarrationStyle)
  }

  private func isPassiveAutomaticNarrationStyle(_ style: GeneratedNarrationStyle) -> Bool {
    switch style {
    case .automaticNarrator, .pieceVoice:
      return true
    case .gemini:
      return false
    }
  }

  private func flushQueuedAutomaticCommentaryDecisionIfPossible() {
    guard automaticCommentaryRequestTask == nil,
          !hasAutomaticCommentaryInFlightOrQueued(),
          let queuedDecision = queuedAutomaticCommentaryDecision else {
      return
    }

    queuedAutomaticCommentaryDecision = nil
    guard !shouldSuppressPassiveCommentaryForCoach() else {
      appendGeminiDebug("Dropped queued automatic commentary because coach interaction is active.")
      pieceVoiceStatusText = "Queued auto commentary dropped for coach activity."
      return
    }
    appendGeminiDebug("Flushing queued automatic commentary once the passive lane cleared.")
    applyAutomaticCommentaryDecision(queuedDecision)
  }

  func handleMove(
    move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState
  ) async -> MoveEvaluationDelta? {
    if afterState.isCheckmate(for: afterState.turn) {
      latestAssessment = "Checkmate."
    }

    let beforeAnalysis = await analysisForCurrentTurn(state: beforeState)
    let afterAnalysis = await analysisForCurrentTurn(state: afterState)
    let evaluationDelta = moveEvaluationDelta(
      before: beforeAnalysis,
      after: afterAnalysis,
      moverColor: beforeState.turn
    )

    if let afterAnalysis {
      cachedAnalysis = CachedAnalysis(fen: afterState.fenString, analysis: afterAnalysis)
      updateAnalysisPresentation(afterAnalysis)
      analysisStatus = "Stockfish movetime \(Self.preferredMovetimeMs)ms live."
      await refreshStockfishDebugMoves(for: afterState, currentAnalysis: afterAnalysis)
      let shouldNarrateHintOnDrop = (evaluationDelta?.deltaW ?? 0) >= Self.substantialGainThreshold
      prefetchHint(for: afterState, analysis: afterAnalysis, narrateWhenReady: shouldNarrateHintOnDrop)
      scheduleCoachCommentary(for: afterState)
    } else if analyzer.lastError != nil {
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(analyzer.lastError ?? analyzer.lastStatus)"
      suggestedMoveText = "Next best move unavailable."
      whiteEvalText = "White eval: --"
      blackEvalText = "Black eval: --"
      analysisTimingText = "Analysis failed."
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = hintService.isConfigured
        ? "Hint unavailable until Stockfish finishes."
        : defaultHintStatus()
    }

    let assessment = classifyMove(
      before: beforeAnalysis,
      after: afterAnalysis,
      moverColor: beforeState.turn
    )

    if let assessment {
      latestAssessment = "\(assessment.label): \(swingDescription(before: beforeAnalysis, after: afterAnalysis, moverColor: beforeState.turn))"
    } else {
      let stockfishMessage = analyzer.lastError ?? analyzer.lastStatus
      if beforeAnalysis == nil || afterAnalysis == nil {
        latestAssessment = "Stockfish error: \(stockfishMessage)"
      } else {
        latestAssessment = "Local event commentary only."
      }
    }

    if afterState.isCheckmate(for: afterState.turn) {
      return evaluationDelta
    }

    if let swing = evaluationDelta?.deltaW {
      if swing >= Self.substantialGainThreshold {
        reactionHandler?(ReactionCue(kind: .enemyKingPrays(color: beforeState.turn.opponent)))
      } else if swing <= Self.substantialDropThreshold {
        reactionHandler?(ReactionCue(kind: .currentKingCries(color: beforeState.turn)))
      }
    }

    let knightForkTargets = knightForkTargets(after: move, in: afterState)
    if knightForkTargets.count >= 2 {
      reactionHandler?(ReactionCue(kind: .knightFork(targets: knightForkTargets)))
    }

    return evaluationDelta
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let utteranceID = ObjectIdentifier(utterance)
    guard !silentSpeechWarmupUtteranceIDs.contains(utteranceID) else {
      return
    }

    AmbientMusicController.shared.setSpeechActive(true)
    if let caption = utteranceCaptions[utteranceID] {
      showCommentaryCaption(caption, owner: .utterance(utteranceID))
    }
    if let playbackRecord = utteranceAutomaticDialogueRecords[utteranceID] {
      beginAutomaticDialoguePlayback(playbackRecord)
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let utteranceID = ObjectIdentifier(utterance)
    if silentSpeechWarmupUtteranceIDs.remove(utteranceID) != nil {
      if !synthesizer.isSpeaking {
        flushPendingGeneratedNarrationIfPossible()
        flushQueuedAutomaticCommentaryDecisionIfPossible()
      }
      return
    }

    utteranceCaptions[utteranceID] = nil
    utteranceStyles[utteranceID] = nil
    if let playbackRecord = utteranceAutomaticDialogueRecords.removeValue(forKey: utteranceID) {
      endAutomaticDialoguePlayback(playbackRecord)
    }
    if !synthesizer.isSpeaking {
      let otherSpeechActive = passiveNarratorLiveSpeaker.isBusy || piperAutomaticSpeaker.isBusy
      if !otherSpeechActive {
        AmbientMusicController.shared.setSpeechActive(false)
        clearCommentaryCaption(ifOwnedBy: .utterance(utteranceID))
      }
      flushPendingGeneratedNarrationIfPossible()
      flushQueuedAutomaticCommentaryDecisionIfPossible()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let utteranceID = ObjectIdentifier(utterance)
    if silentSpeechWarmupUtteranceIDs.remove(utteranceID) != nil {
      if !synthesizer.isSpeaking {
        flushPendingGeneratedNarrationIfPossible()
        flushQueuedAutomaticCommentaryDecisionIfPossible()
      }
      return
    }

    utteranceCaptions[utteranceID] = nil
    utteranceStyles[utteranceID] = nil
    if let playbackRecord = utteranceAutomaticDialogueRecords.removeValue(forKey: utteranceID) {
      endAutomaticDialoguePlayback(playbackRecord)
    }
    if !synthesizer.isSpeaking {
      let otherSpeechActive = passiveNarratorLiveSpeaker.isBusy || piperAutomaticSpeaker.isBusy
      if !otherSpeechActive {
        AmbientMusicController.shared.setSpeechActive(false)
        clearCommentaryCaption(ifOwnedBy: .utterance(utteranceID))
      }
      flushPendingGeneratedNarrationIfPossible()
      flushQueuedAutomaticCommentaryDecisionIfPossible()
    }
  }

  private func analysisForCurrentTurn(state: ChessGameState) async -> StockfishAnalysis? {
    let fen = state.fenString

    if cachedAnalysis?.fen == fen {
      return cachedAnalysis?.analysis
    }

    do {
      let analysis = try await analyzer.analyze(
        fen: fen,
        options: .realtime(
          movetimeMs: Self.preferredMovetimeMs,
          hardTimeoutMs: Self.preferredHardTimeoutMs,
          multiPV: StockfishAnalysisDefaults.multiPV
        )
      )
      cachedAnalysis = CachedAnalysis(fen: fen, analysis: analysis)
      return analysis
    } catch {
      return nil
    }
  }

  private func refreshStockfishDebugMoves(
    for state: ChessGameState? = nil,
    currentAnalysis: StockfishAnalysis? = nil,
    force: Bool = false
  ) async {
    guard stockfishDebugVisible else {
      return
    }

    guard let state = state ?? stateProvider?() else {
      stockfishDebugStatusText = "Stockfish debug requires a board state."
      stockfishDebugWhiteMoves = []
      stockfishDebugBlackMoves = []
      return
    }

    stockfishDebugStatusText = "Refreshing Stockfish MultiPV root moves..."
    let whiteState = stateByReplacingTurn(in: state, with: .white)
    let blackState = stateByReplacingTurn(in: state, with: .black)

    let whiteAnalysis = await debugAnalysis(
      for: whiteState,
      currentAnalysis: currentAnalysis,
      force: force
    )
    let blackAnalysis = await debugAnalysis(
      for: blackState,
      currentAnalysis: currentAnalysis,
      force: force
    )

    stockfishDebugWhiteMoves = whiteAnalysis?.topUniqueMoves ?? []
    stockfishDebugBlackMoves = blackAnalysis?.topUniqueMoves ?? []

    if !stockfishDebugWhiteMoves.isEmpty || !stockfishDebugBlackMoves.isEmpty {
      stockfishDebugStatusText = "Stockfish ready. Showing final MultiPV root moves."
    } else {
      stockfishDebugStatusText = "Stockfish top lines unavailable."
    }
  }

  private func debugAnalysis(
    for state: ChessGameState,
    currentAnalysis: StockfishAnalysis? = nil,
    force: Bool
  ) async -> StockfishAnalysis? {
    let fen = state.fenString

    if !force, let cached = stockfishDebugAnalysisCache[fen] {
      return cached
    }

    if let currentAnalysis, currentAnalysis.fen == fen {
      stockfishDebugAnalysisCache[fen] = currentAnalysis
      return currentAnalysis
    }

    do {
      let analysis = try await analyzer.analyze(
        fen: fen,
        options: .realtime(
          movetimeMs: Self.preferredMovetimeMs,
          hardTimeoutMs: Self.preferredHardTimeoutMs,
          multiPV: StockfishAnalysisDefaults.multiPV
        )
      )
      stockfishDebugAnalysisCache[fen] = analysis
      return analysis
    } catch {
      return nil
    }
  }

  private func stateByReplacingTurn(in state: ChessGameState, with side: ChessColor) -> ChessGameState {
    var updated = state
    updated.turn = side
    return updated
  }

  private func knightForkTargets(after move: ChessMove, in state: ChessGameState) -> [BoardSquare] {
    guard move.piece.kind == .knight,
          let attacker = state.board[move.to],
          attacker.color == move.piece.color,
          attacker.kind == .knight else {
      return []
    }

    let offsets = [
      (1, 2), (2, 1), (2, -1), (1, -2),
      (-1, -2), (-2, -1), (-2, 1), (-1, 2),
    ]

    // A knight can hit more than two pieces; for the visual cue we prioritize the two most
    // important attacked enemy pieces so the fork reads clearly on the board.
    return offsets
      .compactMap { move.to.offset(file: $0.0, rank: $0.1) }
      .compactMap { square -> (BoardSquare, ChessPieceState)? in
        guard let target = state.board[square], target.color == attacker.color.opponent else {
          return nil
        }
        return (square, target)
      }
      .sorted { left, right in
        if left.1.kind.forkThreatPriority == right.1.kind.forkThreatPriority {
          if left.0.rank == right.0.rank {
            return left.0.file < right.0.file
          }
          return left.0.rank < right.0.rank
        }
        return left.1.kind.forkThreatPriority > right.1.kind.forkThreatPriority
      }
      .map(\.0)
  }

  private func requestPieceVoiceLine(
    _ plan: PieceVoiceRequestPlan,
    priority: SpeechPriority,
    reason: String
  ) {
    guard hintService.isConfigured else {
      pieceVoiceStatusText = "Piece voice disabled: ARChessAPIBaseURL missing."
      return
    }

    let sessionID = narrationSessionID
    latestAutomaticCommentaryRequestID += 1
    let requestID = latestAutomaticCommentaryRequestID
    queuedAutomaticCommentaryDecision = nil

    pieceVoiceStatusText = "Requesting \(plan.label)..."
    appendGeminiDebug("Automatic commentary chose piece: \(reason)")
    appendGeminiDebug("Triggering Gemini piece voice for \(plan.label).")
    appendGeminiDebug(
      "Piece voice context piece=\(plan.speaker.displayName.lowercased()) context=\(plan.context.contextMode.rawValue) " +
        "dialogue=\(plan.context.dialogueMode.rawValue) " +
        "move=\(plan.context.fromSquare.algebraic)->\(plan.context.toSquare.algebraic) " +
        "capture=\(plan.context.isCapture) check=\(plan.context.isCheck) nearKing=\(plan.context.isNearEnemyKing) " +
        "attacked=\(plan.context.attackerCount) defended=\(plan.context.defenderCount) " +
        "state=\(plan.context.positionState.rawValue) quality=\(plan.context.moveQuality.rawValue)" +
        (plan.context.underutilizedReason.map { " cue=\($0)" } ?? "")
    )

    automaticCommentaryRequestTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        if self.latestAutomaticCommentaryRequestID == requestID {
          self.automaticCommentaryRequestTask = nil
        }
        self.flushQueuedAutomaticCommentaryDecisionIfPossible()
      }

      do {
        let line = try await self.hintService.fetchPieceVoiceLine(for: plan.context)
        guard self.narrationSessionID == sessionID else {
          self.pieceVoiceStatusText = "Dropped after session reset."
          self.appendGeminiDebug("Dropped stale Gemini piece voice line because the session reset.")
          return
        }
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          self.appendGeminiDebug("Dropped stale Gemini piece voice line because a newer move requested speech.")
          return
        }

        let sanitizedLine = self.cappedPieceVoiceLineText(line)
        if sanitizedLine.isEmpty {
          self.appendGeminiDebug("Gemini piece voice line came back empty after sanitization. Using local fallback.")
          self.emitPieceVoiceLine(
            self.fallbackPieceVoiceLine(for: plan),
            for: plan,
            statusPrefix: "Fallback",
            priority: priority
          )
          return
        }

        self.emitPieceVoiceLine(
          sanitizedLine,
          for: plan,
          statusPrefix: "Generated",
          priority: priority
        )
      } catch is CancellationError {
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          return
        }
        self.pieceVoiceStatusText = "Automatic piece line request cancelled."
        return
      } catch {
        guard self.narrationSessionID == sessionID else {
          self.pieceVoiceStatusText = "Dropped after session reset."
          self.appendGeminiDebug("Dropped stale fallback piece voice line because the session reset.")
          return
        }
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          self.appendGeminiDebug("Dropped stale fallback piece voice line because a newer move requested speech.")
          return
        }
        self.appendGeminiDebug("Gemini piece voice request failed: \(error.localizedDescription). Using local fallback.")
        self.emitPieceVoiceLine(
          self.fallbackPieceVoiceLine(for: plan),
          for: plan,
          statusPrefix: "Fallback",
          priority: priority
        )
      }
    }
  }

  private func requestPassiveNarratorLine(
    _ context: GeminiPassiveNarratorLineContext,
    resetsNarratorRamp: Bool,
    marksOpeningNarrationDelivered: Bool,
    reason: String
  ) {
    let sessionID = narrationSessionID
    latestAutomaticCommentaryRequestID += 1
    let requestID = latestAutomaticCommentaryRequestID
    queuedAutomaticCommentaryDecision = nil

    pieceVoiceStatusText = context.phase == .opening
      ? "Requesting opening narration..."
      : "Requesting narrator line..."
    appendGeminiDebug("Automatic commentary chose narrator: \(reason)")

    automaticCommentaryRequestTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        if self.latestAutomaticCommentaryRequestID == requestID {
          self.automaticCommentaryRequestTask = nil
        }
        self.flushQueuedAutomaticCommentaryDecisionIfPossible()
      }

      let finalizeNarratorState = {
        if marksOpeningNarrationDelivered {
          self.openingNarrationDelivered = true
        }
        if resetsNarratorRamp {
          self.turnsSinceNarratorLine = 0
        }
      }

      do {
        let line = try await self.hintService.fetchPassiveNarratorLine(for: context)
        guard self.narrationSessionID == sessionID else {
          self.pieceVoiceStatusText = "Dropped after session reset."
          self.appendGeminiDebug("Dropped stale narrator line because the session reset.")
          return
        }
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          self.appendGeminiDebug("Dropped stale narrator line because a newer move requested speech.")
          return
        }

        let sanitizedLine = cappedNarrationText(
          line,
          maxSentences: 2,
          maxCharacters: Self.passiveNarratorCharacterLimit
        ).text
        let resolvedLine = sanitizedLine.isEmpty
          ? self.fallbackPassiveNarratorLine(for: context)
          : self.resolveDistinctPassiveNarratorLine(sanitizedLine, for: context)
        guard !resolvedLine.isEmpty else {
          self.pieceVoiceStatusText = "Narrator stayed silent."
          return
        }
        finalizeNarratorState()
        self.emitPassiveNarratorLine(
          resolvedLine,
          context: context,
          statusPrefix: sanitizedLine.isEmpty ? "Fallback" : "Generated"
        )
      } catch is CancellationError {
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          return
        }
        self.pieceVoiceStatusText = "Narrator request cancelled."
      } catch {
        guard self.narrationSessionID == sessionID else {
          self.pieceVoiceStatusText = "Dropped after session reset."
          self.appendGeminiDebug("Dropped stale narrator fallback because the session reset.")
          return
        }
        guard self.latestAutomaticCommentaryRequestID == requestID else {
          self.appendGeminiDebug("Dropped stale narrator fallback because a newer move requested speech.")
          return
        }
        let fallbackLine = self.fallbackPassiveNarratorLine(for: context)
        guard !fallbackLine.isEmpty else {
          self.pieceVoiceStatusText = "Narrator stayed silent."
          return
        }
        finalizeNarratorState()
        self.appendGeminiDebug("Gemini passive narrator request failed: \(error.localizedDescription). Using local fallback.")
        self.emitPassiveNarratorLine(fallbackLine, context: context, statusPrefix: "Fallback")
      }
    }
  }

  private func buildPassiveNarratorLineContext(forOpening state: ChessGameState) -> GeminiPassiveNarratorLineContext {
    narratorDialogueModeStatusText = "Narrator dialogue mode: independent opening line."
    return GeminiPassiveNarratorLineContext(
      fen: state.fenString,
      recentHistory: recentHistoryProvider?(),
      recentLines: recentPassiveNarratorLines(),
      dialogueMode: .independent,
      latestPieceLine: nil,
      phase: .opening,
      turnsSinceLastNarratorLine: turnsSinceNarratorLine,
      moveSAN: nil,
      movingPiece: nil,
      movingColor: nil,
      fromSquare: nil,
      toSquare: nil,
      isCapture: false,
      isCheck: false,
      isCheckmate: false,
      isNearEnemyKing: false,
      isAttacked: false,
      isPinned: false,
      isRetreat: false,
      isAggressiveAdvance: false,
      isForkThreat: false,
      attackerCount: 0,
      defenderCount: 0,
      evalBefore: nil,
      evalAfter: nil,
      evalDelta: nil,
      positionState: nil,
      moveQuality: nil
    )
  }

  private func buildPassiveNarratorLineContext(
    for move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState
  ) -> GeminiPassiveNarratorLineContext {
    let movedPieceContext = buildPieceVoiceLineContext(
      speakingSquare: move.to,
      piece: move.piece,
      contextMode: .moved,
      before: beforeState,
      after: afterState,
      referenceMove: move
    )
    let latestPieceLine = latestPieceDialoguePayload()
    let dialogueMode = chooseNarratorDialogueMode(hasLatestPieceLine: latestPieceLine != nil)
    let reactivePieceLine = dialogueMode == .pieceReactive ? latestPieceLine : nil

    return GeminiPassiveNarratorLineContext(
      fen: afterState.fenString,
      recentHistory: recentHistoryProvider?(),
      recentLines: recentPassiveNarratorLines(),
      dialogueMode: dialogueMode,
      latestPieceLine: reactivePieceLine,
      phase: .move,
      turnsSinceLastNarratorLine: turnsSinceNarratorLine,
      moveSAN: beforeState.sanNotation(for: move),
      movingPiece: move.piece.kind,
      movingColor: move.piece.color,
      fromSquare: move.from,
      toSquare: move.to,
      isCapture: movedPieceContext.isCapture,
      isCheck: movedPieceContext.isCheck,
      isCheckmate: afterState.isCheckmate(for: afterState.turn),
      isNearEnemyKing: movedPieceContext.isNearEnemyKing,
      isAttacked: movedPieceContext.isAttacked,
      isPinned: movedPieceContext.isPinned,
      isRetreat: movedPieceContext.isRetreat,
      isAggressiveAdvance: movedPieceContext.isAggressiveAdvance,
      isForkThreat: movedPieceContext.isForkThreat,
      attackerCount: movedPieceContext.attackerCount,
      defenderCount: movedPieceContext.defenderCount,
      evalBefore: movedPieceContext.evalBefore,
      evalAfter: movedPieceContext.evalAfter,
      evalDelta: movedPieceContext.evalDelta,
      positionState: movedPieceContext.positionState,
      moveQuality: movedPieceContext.moveQuality
    )
  }

  private func makePieceVoiceRequestPlan(
    move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState,
    allowAmbient: Bool,
    allowUnderutilizedSnark: Bool
  ) -> PieceVoiceRequestPlan {
    if allowAmbient,
       shouldTriggerAmbientPieceVoiceLine(),
       let ambientSpeaker = selectAmbientPieceVoiceSpeaker(
        in: afterState,
        excluding: move.to
       ) {
      let speaker = personalitySpeaker(for: ambientSpeaker.piece.kind)
      let recentLines = recentPieceVoiceLines(for: speaker)
      let pieceHistory = recentPieceDialogueHistory()
      let dialogueMode = choosePieceDialogueMode(hasHistory: !pieceHistory.isEmpty)
      let latestPieceLine = dialogueMode == .historyReactive ? latestPieceDialoguePayload() : nil
      let context = buildPieceVoiceLineContext(
        speakingSquare: ambientSpeaker.square,
        piece: ambientSpeaker.piece,
        contextMode: .ambient,
        before: beforeState,
        after: afterState,
        referenceMove: move,
        recentLines: recentLines,
        dialogueMode: dialogueMode,
        pieceDialogueHistory: dialogueMode == .historyReactive ? pieceHistory : [],
        latestPieceLine: latestPieceLine
      )
      return PieceVoiceRequestPlan(
        speaker: speaker,
        context: context,
        label: "\(speaker.displayName.lowercased()) observing from \(ambientSpeaker.square.algebraic)"
      )
    }

    if allowUnderutilizedSnark,
       let underutilizedPlan = makeUnderutilizedPieceVoiceRequestPlan(
        move: move,
        before: beforeState,
        after: afterState
       ) {
      return underutilizedPlan
    }

    let speaker = personalitySpeaker(for: move.piece.kind)
    let recentLines = recentPieceVoiceLines(for: speaker)
    let pieceHistory = recentPieceDialogueHistory()
    let dialogueMode = choosePieceDialogueMode(hasHistory: !pieceHistory.isEmpty)
    let latestPieceLine = dialogueMode == .historyReactive ? latestPieceDialoguePayload() : nil
    let context = buildPieceVoiceLineContext(
      speakingSquare: move.to,
      piece: move.piece,
      contextMode: .moved,
      before: beforeState,
      after: afterState,
      referenceMove: move,
      recentLines: recentLines,
      dialogueMode: dialogueMode,
      pieceDialogueHistory: dialogueMode == .historyReactive ? pieceHistory : [],
      latestPieceLine: latestPieceLine
    )
    return PieceVoiceRequestPlan(
      speaker: speaker,
      context: context,
      label: "\(speaker.displayName.lowercased()) moved \(move.from.algebraic)-\(move.to.algebraic)"
    )
  }

  private func makeUnderutilizedPieceVoiceRequestPlan(
    move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState
  ) -> PieceVoiceRequestPlan? {
    guard hasReachedUnderutilizedSnarkMoveFloor(after: afterState) else {
      return nil
    }

    // Once both players have reached the minimum move count, neglected pieces occasionally cut in.
    guard Double.random(in: 0..<1) < Self.underutilizedSnarkTriggerChance else {
      return nil
    }

    let eligibleCandidates = underutilizedPieceCandidates(
      in: afterState,
      for: move.piece.color,
      excluding: move.to
    )
    let pool = Array(eligibleCandidates.prefix(Self.underutilizedSnarkPoolSize))
    guard let selected = selectWeightedUnderutilizedPieceCandidate(from: pool) else {
      return nil
    }

    let speaker = personalitySpeaker(for: selected.piece.kind)
    let recentLines = recentPieceVoiceLines(for: speaker)
    pieceDialogueModeStatusText = (
      "Piece dialogue mode: underutilized snark from \(speaker.displayName.lowercased()) on \(selected.square.algebraic)."
    )

    let context = buildPieceVoiceLineContext(
      speakingSquare: selected.square,
      piece: selected.piece,
      contextMode: .ambient,
      before: beforeState,
      after: afterState,
      referenceMove: move,
      recentLines: recentLines,
      dialogueMode: .underutilizedSnark,
      pieceMoveCount: selected.moveCount,
      underutilizedReason: selected.underutilizedReason
    )
    return PieceVoiceRequestPlan(
      speaker: speaker,
      context: context,
      label: "\(speaker.displayName.lowercased()) snarking from \(selected.square.algebraic)"
    )
  }

  private func hasReachedUnderutilizedSnarkMoveFloor(after state: ChessGameState) -> Bool {
    movesPlayedBy(.white, in: state) >= Self.underutilizedSnarkMinimumMovesPerPlayer
      && movesPlayedBy(.black, in: state) >= Self.underutilizedSnarkMinimumMovesPerPlayer
  }

  private func movesPlayedBy(_ color: ChessColor, in state: ChessGameState) -> Int {
    let completedFullMoves = max(0, state.fullmoveNumber - 1)
    switch color {
    case .white:
      return completedFullMoves + (state.turn == .black ? 1 : 0)
    case .black:
      return completedFullMoves
    }
  }

  private func underutilizedPieceCandidates(
    in state: ChessGameState,
    for color: ChessColor,
    excluding movedSquare: BoardSquare
  ) -> [UnderutilizedPieceCandidate] {
    let speakerState = stateByReplacingTurn(in: state, with: color)

    return state.board
      .compactMap { square, piece -> UnderutilizedPieceCandidate? in
        guard piece.color == color,
              piece.kind != .king,
              square != movedSquare,
              let pieceID = trackedPieceInstanceIDsBySquare[square] else {
          return nil
        }

        let moveCount = trackedPieceMoveCountsByID[pieceID, default: 0]
        let mobility = speakerState.legalMoves(from: square).count
        let reason = underutilizedReason(
          for: square,
          piece: piece,
          moveCount: moveCount,
          mobility: mobility,
          in: state
        )
        return UnderutilizedPieceCandidate(
          square: square,
          piece: piece,
          moveCount: moveCount,
          mobility: mobility,
          underutilizedReason: reason
        )
      }
      .sorted { left, right in
        if left.moveCount != right.moveCount {
          return left.moveCount < right.moveCount
        }
        if left.mobility != right.mobility {
          return left.mobility < right.mobility
        }
        if left.piece.kind == .pawn, right.piece.kind != .pawn {
          return false
        }
        if left.piece.kind != .pawn, right.piece.kind == .pawn {
          return true
        }
        if left.square.rank == right.square.rank {
          return left.square.file < right.square.file
        }
        return left.square.rank < right.square.rank
      }
  }

  private func selectWeightedUnderutilizedPieceCandidate(
    from candidates: [UnderutilizedPieceCandidate]
  ) -> UnderutilizedPieceCandidate? {
    guard !candidates.isEmpty else {
      return nil
    }

    let weightedCandidates = candidates.map { candidate in
      (candidate: candidate, weight: underutilizedPieceWeight(for: candidate.piece.kind))
    }
    let totalWeight = weightedCandidates.reduce(0) { $0 + $1.weight }
    guard totalWeight > 0 else {
      return candidates.randomElement()
    }

    var threshold = Double.random(in: 0..<totalWeight)
    for candidate in weightedCandidates {
      threshold -= candidate.weight
      if threshold <= 0 {
        return candidate.candidate
      }
    }

    return weightedCandidates.last?.candidate
  }

  private func underutilizedPieceWeight(for kind: ChessPieceKind) -> Double {
    // Non-pawns are intentionally favored so idle minors and rooks speak more often than reserve pawns.
    switch kind {
    case .pawn:
      return 1.0
    case .knight, .bishop:
      return 3.2
    case .rook:
      return 3.6
    case .queen:
      return 2.8
    case .king:
      return 0.0
    }
  }

  private func underutilizedReason(
    for square: BoardSquare,
    piece: ChessPieceState,
    moveCount: Int,
    mobility: Int,
    in state: ChessGameState
  ) -> String {
    let isBackRank = piece.color == .white ? square.rank == 0 : square.rank == 7
    let ownBlockersAhead = ownBlockersInFront(of: square, piece: piece, in: state)

    switch piece.kind {
    case .pawn:
      if moveCount == 0 {
        return "still waiting for the march order"
      }
      return "left idle while the battle keeps moving"
    case .knight:
      if moveCount == 0 {
        return "kept in reserve while the fight begins"
      }
      if mobility <= 2 {
        return "stabled without a proper jump"
      }
      return "left waiting while clumsier pieces get the glory"
    case .bishop:
      if mobility <= 2 || ownBlockersAhead >= 1 {
        return "boxed in with no clean diagonal"
      }
      return "left preaching from the back while the lines stay closed"
    case .rook:
      if isBackRank {
        return mobility <= 2 ? "stuck on the back rank with no open file" : "kept on the back rank without a real file"
      }
      return mobility <= 2 ? "waiting for an open file" : "left idle while the files stay shut"
    case .queen:
      if moveCount == 0 {
        return "left on the bench while lesser pieces fumble"
      }
      return mobility <= 3 ? "stuck behind my own traffic" : "kept waiting while others make a meal of this"
    case .king:
      return "left sulking behind the line"
    }
  }

  private func ownBlockersInFront(
    of square: BoardSquare,
    piece: ChessPieceState,
    in state: ChessGameState
  ) -> Int {
    switch piece.kind {
    case .pawn:
      let direction = piece.color == .white ? 1 : -1
      guard let oneForward = square.offset(file: 0, rank: direction),
            let blocker = state.piece(at: oneForward),
            blocker.color == piece.color else {
        return 0
      }
      return 1
    case .bishop:
      return [(-1, 1), (1, 1), (-1, -1), (1, -1)].reduce(0) { count, delta in
        guard let target = square.offset(file: delta.0, rank: delta.1),
              let blocker = state.piece(at: target),
              blocker.color == piece.color else {
          return count
        }
        return count + 1
      }
    case .rook:
      return [(0, 1), (0, -1), (-1, 0), (1, 0)].reduce(0) { count, delta in
        guard let target = square.offset(file: delta.0, rank: delta.1),
              let blocker = state.piece(at: target),
              blocker.color == piece.color else {
          return count
        }
        return count + 1
      }
    case .queen:
      return ownBlockersInFront(of: square, piece: ChessPieceState(color: piece.color, kind: .rook), in: state)
        + ownBlockersInFront(of: square, piece: ChessPieceState(color: piece.color, kind: .bishop), in: state)
    case .knight, .king:
      return 0
    }
  }

  private func shouldTriggerAmbientPieceVoiceLine() -> Bool {
    Double.random(in: 0..<1) < Self.ambientPieceVoiceLineChance
  }

  private func selectAmbientPieceVoiceSpeaker(
    in state: ChessGameState,
    excluding movedSquare: BoardSquare
  ) -> (square: BoardSquare, piece: ChessPieceState)? {
    let pieces = state.board
      .filter { entry in
        let isMovedPiece = entry.key == movedSquare
        return !isMovedPiece || state.board.count == 1
      }
      .map { (square: $0.key, piece: $0.value) }

    guard !pieces.isEmpty else {
      return nil
    }

    let weightedPieces = pieces.map { candidate in
      (
        candidate: candidate,
        weight: ambientPieceVoiceWeight(
          for: candidate.square,
          piece: candidate.piece,
          in: state
        )
      )
    }
    let totalWeight = weightedPieces.reduce(0) { $0 + $1.weight }
    guard totalWeight > 0 else {
      return weightedPieces.randomElement()?.candidate
    }

    var roll = Int.random(in: 0..<totalWeight)
    for weightedPiece in weightedPieces {
      if roll < weightedPiece.weight {
        return weightedPiece.candidate
      }
      roll -= weightedPiece.weight
    }

    return weightedPieces.last?.candidate
  }

  private func ambientPieceVoiceWeight(
    for square: BoardSquare,
    piece: ChessPieceState,
    in state: ChessGameState
  ) -> Int {
    let opponent = piece.color.opponent
    let attackerCount = state.attackOrigins(on: square, by: opponent).count
    let defenderCount = max(
      0,
      state.attackOrigins(on: square, by: piece.color).filter { $0 != square }.count
    )
    let activeState = stateByReplacingTurn(in: state, with: piece.color)
    let legalMoves = activeState.legalMoves(from: square)
    let enemyKingSquare = state.kingSquare(for: opponent)
    let nearEnemyKing = enemyKingSquare.map { chebyshevDistance(from: square, to: $0) <= 2 } ?? false
    let attacksEnemyKing = enemyKingSquare.map { state.attackOrigins(on: $0, by: piece.color).contains(square) } ?? false
    let isPinned = state.isPiecePinned(at: square)
    let threatensEnemyMaterial = legalMoves.contains { candidate in
      guard let target = state.piece(at: candidate.to) else {
        return false
      }
      return target.color == opponent
    }

    var weight = 1
    weight += min(attackerCount, 3)
    weight += min(defenderCount, 2)
    weight += nearEnemyKing ? 3 : 0
    weight += attacksEnemyKing ? 3 : 0
    weight += threatensEnemyMaterial ? 2 : 0
    weight += isPinned ? 2 : 0
    weight += legalMoves.isEmpty ? 1 : 2
    if piece.kind != .pawn {
      weight += 1
    }
    return max(weight, 1)
  }

  private func buildPieceVoiceLineContext(
    speakingSquare: BoardSquare,
    piece: ChessPieceState,
    contextMode: PieceVoiceContextMode,
    before beforeState: ChessGameState,
    after afterState: ChessGameState,
    referenceMove: ChessMove? = nil,
    beforeAnalysis: StockfishAnalysis? = nil,
    afterAnalysis: StockfishAnalysis? = nil,
    recentLines: [String] = [],
    dialogueMode: PieceDialogueMode = .independent,
    pieceDialogueHistory: [GeminiDialogueUtterancePayload] = [],
    latestPieceLine: GeminiDialogueUtterancePayload? = nil,
    pieceMoveCount: Int = 0,
    underutilizedReason: String? = nil
  ) -> GeminiPieceVoiceLineContext {
    let moverColor = piece.color
    let opponent = moverColor.opponent
    let enemyKingSquare = afterState.kingSquare(for: opponent)
    let beforeEnemyKingSquare = beforeState.kingSquare(for: opponent)
    let fromSquare = contextMode == .moved ? (referenceMove?.from ?? speakingSquare) : speakingSquare
    let attackerOrigins = afterState.attackOrigins(on: speakingSquare, by: opponent)
    let defenderOrigins = afterState.attackOrigins(on: speakingSquare, by: moverColor)
    let beforeAttackerOrigins = beforeState.attackOrigins(on: fromSquare, by: opponent)
    let movedPieceState = stateByReplacingTurn(in: afterState, with: moverColor)
    let movedPieceLegalMoves = movedPieceState.legalMoves(from: speakingSquare)
    let movedPieceThreatTargets = Set(
      movedPieceLegalMoves.compactMap { candidate -> BoardSquare? in
        guard let target = afterState.piece(at: candidate.to),
              target.color == opponent else {
          return nil
        }
        return candidate.to
      }
    )

    let beforeEnemyKingDistance = beforeEnemyKingSquare.map { chebyshevDistance(from: fromSquare, to: $0) } ?? 8
    let afterEnemyKingDistance = enemyKingSquare.map { chebyshevDistance(from: speakingSquare, to: $0) } ?? 8
    let kingZoneThreat = enemyKingSquare.map { kingSquare in
      movedPieceLegalMoves.contains { candidate in
        max(abs(candidate.to.file - kingSquare.file), abs(candidate.to.rank - kingSquare.rank)) <= 1
      }
    } ?? false
    let attacksEnemyKing = enemyKingSquare.map {
      afterState.attackOrigins(on: $0, by: moverColor).contains(speakingSquare)
    } ?? false
    let isNearEnemyKing = piece.kind != .king
      && (afterEnemyKingDistance <= 2 || kingZoneThreat || attacksEnemyKing)
    let defenderCount = defenderOrigins.filter { $0 != speakingSquare }.count
    let attackerCount = attackerOrigins.count
    let isAttacked = attackerCount > 0
    let isDefended = defenderCount > 0
    let isHanging = isAttacked && !isDefended
    let isPinned = afterState.isPiecePinned(at: speakingSquare)
    let isCapture = contextMode == .moved ? (referenceMove?.captured != nil || referenceMove?.isEnPassant == true) : false
    let isCheck = afterState.isInCheck(for: opponent) && attacksEnemyKing
    let isRetreat = contextMode == .moved
      && !isCapture
      && !isCheck
      && referenceMove?.isEnPassant != true
      && beforeAttackerOrigins.count > 0
      && afterEnemyKingDistance > beforeEnemyKingDistance
    let isAggressiveAdvance = contextMode == .moved
      ? (
        isCheck
          || isCapture
          || afterEnemyKingDistance < beforeEnemyKingDistance
          || (referenceMove.map { movedDeeperIntoEnemyHalf($0) } ?? false)
      )
      : (isCheck || isNearEnemyKing || !movedPieceThreatTargets.isEmpty)
    let isForkThreat = threatensFork(
      movedPiece: piece,
      targetSquares: movedPieceThreatTargets,
      in: afterState,
      enemyKingSquare: enemyKingSquare
    )
    let evalBefore = beforeAnalysis?.perspectiveScore(for: moverColor) ?? fastPieceVoiceEvaluation(for: moverColor, in: beforeState)
    let evalAfter = afterAnalysis?.perspectiveScore(for: moverColor) ?? fastPieceVoiceEvaluation(for: moverColor, in: afterState)
    let evalDelta = evalAfter - evalBefore

    return GeminiPieceVoiceLineContext(
      fen: afterState.fenString,
      pieceType: piece.kind,
      pieceColor: moverColor,
      recentLines: recentLines,
      dialogueMode: dialogueMode,
      pieceDialogueHistory: pieceDialogueHistory,
      latestPieceLine: latestPieceLine,
      contextMode: contextMode,
      fromSquare: fromSquare,
      toSquare: speakingSquare,
      isCapture: isCapture,
      isCheck: isCheck,
      isNearEnemyKing: isNearEnemyKing,
      isAttacked: isAttacked,
      isAttackedByMultiple: attackerCount >= 2,
      isDefended: isDefended,
      isWellDefended: defenderCount >= 2,
      isHanging: isHanging,
      isPinned: isPinned,
      isRetreat: isRetreat,
      isAggressiveAdvance: isAggressiveAdvance,
      isForkThreat: isForkThreat,
      attackerCount: attackerCount,
      defenderCount: defenderCount,
      evalBefore: evalBefore,
      evalAfter: evalAfter,
      evalDelta: evalDelta,
      positionState: pieceVoicePositionState(evalAfter),
      moveQuality: pieceVoiceMoveQuality(
        piece: piece,
        evalDelta: evalDelta,
        isCheck: isCheck,
        isCapture: isCapture,
        isAttacked: isAttacked,
        isRetreat: isRetreat,
        isForkThreat: isForkThreat
      ),
      pieceMoveCount: pieceMoveCount,
      underutilizedReason: underutilizedReason
    )
  }

  private func pieceVoicePositionState(_ evalAfter: Int?) -> PieceVoicePositionState {
    guard let evalAfter else {
      return .equal
    }

    switch evalAfter {
    case 120...:
      return .winning
    case ...(-120):
      return .losing
    default:
      return .equal
    }
  }

  private func pieceVoiceMoveQuality(
    piece: ChessPieceState,
    evalDelta: Int?,
    isCheck: Bool,
    isCapture: Bool,
    isAttacked: Bool,
    isRetreat: Bool,
    isForkThreat: Bool
  ) -> PieceVoiceMoveQuality {
    if let evalDelta, evalDelta >= 140 {
      return .strong
    }
    if isCheck || isForkThreat {
      return .tactical
    }
    if let evalDelta, evalDelta <= -140 {
      return .poor
    }
    if let evalDelta, evalDelta >= 60, isAttacked {
      return .desperate
    }
    if isRetreat || (isAttacked && !isCapture) {
      return .defensive
    }
    if isCapture || piece.kind == .pawn {
      return .aggressive
    }
    return .routine
  }

  private func fastPieceVoiceEvaluation(
    for color: ChessColor,
    in state: ChessGameState
  ) -> Int {
    var score = 0
    for piece in state.board.values {
      let value: Int
      switch piece.kind {
      case .pawn:
        value = 100
      case .knight:
        value = 320
      case .bishop:
        value = 330
      case .rook:
        value = 500
      case .queen:
        value = 900
      case .king:
        value = 0
      }

      score += piece.color == color ? value : -value
    }
    return score
  }

  private func personalitySpeaker(for kind: ChessPieceKind) -> PersonalitySpeaker {
    switch kind {
    case .pawn:
      return .pawn
    case .rook:
      return .rook
    case .knight:
      return .knight
    case .bishop:
      return .bishop
    case .queen:
      return .queen
    case .king:
      return .king
    }
  }

  private func personalitySpeaker(for speakerType: PiperSpeakerType) -> PersonalitySpeaker? {
    switch speakerType {
    case .pawn:
      return .pawn
    case .rook:
      return .rook
    case .knight:
      return .knight
    case .bishop:
      return .bishop
    case .queen:
      return .queen
    case .king:
      return .king
    case .narrator:
      return nil
    }
  }

  private func personalitySpeaker(named displayName: String) -> PersonalitySpeaker? {
    switch displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "pawn":
      return .pawn
    case "rook":
      return .rook
    case "knight":
      return .knight
    case "bishop":
      return .bishop
    case "queen":
      return .queen
    case "king":
      return .king
    default:
      return nil
    }
  }

  private func pieceVoiceFingerprint(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func recentPieceDialogueEntries(limit: Int = 4) -> [AutonomousDialogueMemoryEntry] {
    Array(
      autonomousDialogueMemory
        .filter { $0.speakerClass == .piece }
        .suffix(limit)
    )
  }

  private func pieceDialogueSpeakerKey(_ entry: AutonomousDialogueMemoryEntry) -> String {
    if let identity = entry.pieceIdentity?.lowercased(), !identity.isEmpty {
      return identity
    }
    let color = entry.pieceColor?.displayName.lowercased() ?? "unknown"
    let type = entry.pieceType?.displayName.lowercased() ?? entry.speakerName.lowercased()
    return "\(color):\(type)"
  }

  private func isDirectAddressPieceLine(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return false
    }

    let leadInPattern =
      #"^(?:ok(?:ay)?|listen|bold words|easy there|quiet|steady|careful|hey|look|look here|say what)\s+(?:(?:white|black)\s+)?(?:pawn|knight|bishop|rook|queen|king)\b"#
    let namePattern = #"^(?:(?:white|black)\s+)?(?:pawn|knight|bishop|rook|queen|king)\b[,:]"#
    return trimmed.range(of: leadInPattern, options: [.regularExpression, .caseInsensitive]) != nil
      || trimmed.range(of: namePattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func isFirstPersonPieceVoiceLine(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return false
    }

    let pattern = #"\b(?:i|i'm|i’ve|i'll|i’ll|i'd|i’d|me|my|mine|myself|we|we're|we’ve|we'll|we’ll|we'd|we’d|us|our|ours)\b"#
    return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func recentPieceDialogueLoopSignals(limit: Int = 4) -> (directAddressCount: Int, loopDetected: Bool) {
    let entries = recentPieceDialogueEntries(limit: limit)
    let directAddressCount = entries.reduce(into: 0) { count, entry in
      if isDirectAddressPieceLine(entry.text) {
        count += 1
      }
    }
    let speakerKeys = entries.map(pieceDialogueSpeakerKey)
    let loopDetected = entries.count >= 4
      && Set(speakerKeys).count == 2
      && speakerKeys[0] == speakerKeys[2]
      && speakerKeys[1] == speakerKeys[3]
      && speakerKeys[0] != speakerKeys[1]
    return (directAddressCount, loopDetected)
  }

  private func shouldSuppressLoopLikePieceLine(_ text: String) -> Bool {
    guard isDirectAddressPieceLine(text) else {
      return false
    }
    let signals = recentPieceDialogueLoopSignals()
    return signals.loopDetected || signals.directAddressCount >= 2
  }

  private func firstPersonEmergencyPieceVoiceLine(
    for plan: PieceVoiceRequestPlan,
    avoiding additionalLines: [String] = []
  ) -> String {
    let options: [String]
    switch plan.speaker {
    case .pawn:
      options = [
        "I push forward and make this square mine.",
        "I want blood, and I want it up close.",
        "I keep marching until this file breaks.",
      ]
    case .rook:
      options = [
        "I grind forward and crush what stands here.",
        "I own this lane now, and I mean to keep it.",
        "I hit this file like a falling wall.",
      ]
    case .knight:
      options = [
        "I choose my angle, then I strike from it.",
        "I leap where I please and call it elegance.",
        "I turn one jump into real trouble.",
      ]
    case .bishop:
      options = [
        "I bring judgment down this diagonal myself.",
        "I keep my faith and fire through it.",
        "I claim this line in righteous force.",
      ]
    case .queen:
      options = [
        "I arrive, and the board starts obeying me.",
        "I clean this mess up because clearly I must.",
        "I make the threat, and they live with it.",
      ]
    case .king:
      options = [
        "I step carefully because I intend to survive this.",
        "I move, and the whole fight bends around me.",
        "I keep the crown by staying alive one move longer.",
      ]
    }
    return pickDistinctPieceVoiceOption(options, for: plan.speaker, extraAvoiding: additionalLines)
  }

  private func autonomousDialoguePayload(
    from entry: AutonomousDialogueMemoryEntry
  ) -> GeminiDialogueUtterancePayload? {
    // This is the asymmetry boundary: only piece-tagged utterances can ever flow back into
    // autonomous dialogue prompts, so narrator lines never enter piece conversational memory.
    guard entry.speakerClass == .piece else {
      return nil
    }

    return GeminiDialogueUtterancePayload(
      speaker_class: entry.speakerClass.rawValue,
      piece_type: entry.pieceType?.displayName.lowercased(),
      piece_color: entry.pieceColor?.displayName.lowercased(),
      piece_identity: entry.pieceIdentity,
      text: entry.text
    )
  }

  private func recentPieceDialogueHistory(
    limit: Int? = nil
  ) -> [GeminiDialogueUtterancePayload] {
    let resolvedLimit = limit ?? Self.pieceDialogueHistoryWindow
    return Array(
      autonomousDialogueMemory
        .filter { $0.speakerClass == .piece }
        .suffix(resolvedLimit)
        .compactMap { autonomousDialoguePayload(from: $0) }
    )
  }

  private func latestPieceDialoguePayload() -> GeminiDialogueUtterancePayload? {
    autonomousDialogueMemory
      .last(where: { $0.speakerClass == .piece })
      .flatMap { autonomousDialoguePayload(from: $0) }
  }

  func setPieceHistoryReactiveChancePercent(_ percent: Int) {
    pieceHistoryReactiveChancePercent = min(max(percent, 0), 100)
  }

  func setNarratorPieceReactiveChancePercent(_ percent: Int) {
    narratorPieceReactiveChancePercent = min(max(percent, 0), 100)
  }

  func resetPassiveDialogueModeOddsToDefaults() {
    pieceHistoryReactiveChancePercent = Self.defaultPieceHistoryReactiveChancePercent
    narratorPieceReactiveChancePercent = Self.defaultNarratorPieceReactiveChancePercent
  }

  private func choosePieceDialogueMode(hasHistory: Bool) -> PieceDialogueMode {
    guard hasHistory else {
      pieceDialogueModeStatusText = "Piece dialogue mode: independent because no recent piece chatter is available."
      return .independent
    }

    let reactiveChance = Double(pieceHistoryReactiveChancePercent) / 100.0
    let mode: PieceDialogueMode = Double.random(in: 0..<1) < reactiveChance
      ? .historyReactive
      : .independent
    let independentChancePercent = max(0, 100 - pieceHistoryReactiveChancePercent)
    pieceDialogueModeStatusText = mode == .historyReactive
      ? "Piece dialogue mode: with context (\(pieceHistoryReactiveChancePercent)% setting)."
      : "Piece dialogue mode: fresh line (\(independentChancePercent)% complement)."
    return mode
  }

  private func chooseNarratorDialogueMode(hasLatestPieceLine: Bool) -> PassiveNarratorDialogueMode {
    guard hasLatestPieceLine else {
      narratorDialogueModeStatusText = "Narrator dialogue mode: independent because no recent piece line is available."
      return .independent
    }

    let reactiveChance = Double(narratorPieceReactiveChancePercent) / 100.0
    let mode: PassiveNarratorDialogueMode = Double.random(in: 0..<1) < reactiveChance
      ? .pieceReactive
      : .independent
    let independentChancePercent = max(0, 100 - narratorPieceReactiveChancePercent)
    narratorDialogueModeStatusText = mode == .pieceReactive
      ? "Narrator dialogue mode: reacting to a piece line (\(narratorPieceReactiveChancePercent)% setting)."
      : "Narrator dialogue mode: independent (\(independentChancePercent)% complement)."
    return mode
  }

  private func recentPieceVoiceLines(
    for speaker: PersonalitySpeaker,
    limit: Int = 4
  ) -> [String] {
    return Array(
      autonomousDialogueMemory
        .reversed()
        .compactMap { entry -> String? in
          guard entry.speakerClass == .piece,
                entry.speakerName == speaker.displayName else {
            return nil
          }
          let body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
          return body.isEmpty ? nil : body
        }
        .prefix(limit)
    )
  }

  private func hasRecentPieceVoiceLine(
    _ text: String,
    for speaker: PersonalitySpeaker,
    limit: Int = 4
  ) -> Bool {
    let fingerprint = pieceVoiceFingerprint(text)
    guard !fingerprint.isEmpty else {
      return false
    }

    return recentPieceVoiceLines(for: speaker, limit: limit).contains {
      pieceVoiceFingerprint($0) == fingerprint
    }
  }

  private func recentPassiveNarratorLines(limit: Int = 4) -> [String] {
    return Array(
      autonomousDialogueMemory
        .reversed()
        .compactMap { entry -> String? in
          guard entry.speakerClass == .narrator else {
            return nil
          }
          let body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
          return body.isEmpty ? nil : body
        }
        .prefix(limit)
    )
  }

  private func hasRecentPassiveNarratorLine(_ text: String, limit: Int = 4) -> Bool {
    let fingerprint = pieceVoiceFingerprint(text)
    guard !fingerprint.isEmpty else {
      return false
    }

    return recentPassiveNarratorLines(limit: limit).contains {
      pieceVoiceFingerprint($0) == fingerprint
    }
  }

  private func discardPendingAutomaticNarrations() {
    let originalCount = pendingGeneratedNarrations.count
    pendingGeneratedNarrations.removeAll { pending in
      switch pending.style {
      case .automaticNarrator, .pieceVoice:
        return true
      case .gemini:
        return false
      }
    }

    let droppedCount = originalCount - pendingGeneratedNarrations.count
    guard droppedCount > 0 else {
      return
    }

    appendGeminiDebug("Dropped \(droppedCount) queued stale passive commentary line(s).")
    if pendingGeneratedNarrations.isEmpty {
      geminiNarrationRetryWorkItem?.cancel()
      geminiNarrationRetryWorkItem = nil
    }
  }

  private func pickDistinctPieceVoiceOption(
    _ options: [String],
    for speaker: PersonalitySpeaker,
    extraAvoiding additionalLines: [String] = []
  ) -> String {
    let avoidFingerprints = Set(
      recentPieceVoiceLines(for: speaker, limit: 6)
        .map { pieceVoiceFingerprint($0) }
        .filter { !$0.isEmpty }
        + additionalLines.map { pieceVoiceFingerprint($0) }.filter { !$0.isEmpty }
    )
    let shuffledOptions = options.shuffled()

    if let distinctOption = shuffledOptions.first(where: { !avoidFingerprints.contains(pieceVoiceFingerprint($0)) }) {
      return distinctOption
    }

    return shuffledOptions.first ?? options.first ?? ""
  }

  private func automaticDialoguePlaybackRecord(
    for entry: AutonomousDialogueMemoryEntry,
    highlightedSquare: BoardSquare?
  ) -> AutomaticDialoguePlaybackRecord {
    AutomaticDialoguePlaybackRecord(
      entry: entry,
      stackLine: "\(entry.speakerName): \(entry.text)",
      highlightedSquare: highlightedSquare
    )
  }

  private func recordAutomaticDialogueUtterance(_ record: AutomaticDialoguePlaybackRecord) {
    autonomousDialogueMemory.append(record.entry)
    if autonomousDialogueMemory.count > 24 {
      autonomousDialogueMemory.removeFirst(autonomousDialogueMemory.count - 24)
    }

    pieceVoiceLines.append(record.stackLine)
    if pieceVoiceLines.count > 8 {
      pieceVoiceLines.removeFirst(pieceVoiceLines.count - 8)
    }
    appendGeminiDebug("Automatic commentary started: \(record.stackLine)")
  }

  private func setSpeakingPieceHighlight(square: BoardSquare?) {
    let squares = square.map { [$0.algebraic] } ?? []
    narrationHighlightHandler?(squares, "Speaking piece")
  }

  private func beginAutomaticDialoguePlayback(_ record: AutomaticDialoguePlaybackRecord) {
    recordAutomaticDialogueUtterance(record)
    setSpeakingPieceHighlight(square: record.highlightedSquare)
  }

  private func endAutomaticDialoguePlayback(_ record: AutomaticDialoguePlaybackRecord) {
    setSpeakingPieceHighlight(square: nil)
  }

  private func recordCoachDialogueLines(_ lines: [String]) {
    for line in lines {
      autonomousDialogueMemory.append(
        AutonomousDialogueMemoryEntry(
          speakerClass: .coach,
          speakerName: "Coach",
          text: line,
          pieceType: nil,
          pieceColor: nil,
          pieceIdentity: nil
        )
      )
    }
    if autonomousDialogueMemory.count > 24 {
      autonomousDialogueMemory.removeFirst(autonomousDialogueMemory.count - 24)
    }
  }

  private func emitPieceVoiceLine(
    _ text: String,
    for plan: PieceVoiceRequestPlan,
    statusPrefix: String,
    priority: SpeechPriority
  ) {
    var resolvedText = text
    var resolvedStatusPrefix = statusPrefix
    if !isFirstPersonPieceVoiceLine(resolvedText) {
      appendGeminiDebug(
        "Suppressed non-first-person piece line for \(plan.speaker.displayName.lowercased()); using a first-person local fallback."
      )
      resolvedText = firstPersonEmergencyPieceVoiceLine(for: plan, avoiding: [resolvedText])
      resolvedStatusPrefix = "Fallback"
    }
    if shouldSuppressLoopLikePieceLine(resolvedText) {
      appendGeminiDebug(
        "Suppressed loop-like direct-address piece line for \(plan.speaker.displayName.lowercased()); using a loop-safe local fallback."
      )
      resolvedText = fallbackPieceVoiceLine(for: plan, avoiding: [resolvedText])
      resolvedStatusPrefix = "Fallback"
    }
    if hasRecentPieceVoiceLine(resolvedText, for: plan.speaker) {
      appendGeminiDebug(
        "Piece voice line repeated recent wording for \(plan.speaker.displayName.lowercased()); using a varied local fallback."
      )
      resolvedText = fallbackPieceVoiceLine(for: plan, avoiding: [resolvedText])
      resolvedStatusPrefix = "Fallback"
    }

    let debugLine = "\(plan.speaker.displayName): \(resolvedText)"
    pieceVoiceStatusText = "\(resolvedStatusPrefix): \(debugLine)"
    let playbackRecord = automaticDialoguePlaybackRecord(
      for: AutonomousDialogueMemoryEntry(
        speakerClass: .piece,
        speakerName: plan.speaker.displayName,
        text: resolvedText,
        pieceType: plan.context.pieceType,
        pieceColor: plan.context.pieceColor,
        pieceIdentity: "\(plan.context.pieceColor.displayName.capitalized) \(plan.context.pieceType.displayName) on \(plan.context.toSquare.algebraic)"
      ),
      highlightedSquare: plan.context.toSquare
    )
    let spokeImmediately = speakGeneratedPieceVoiceLine(
      text: resolvedText,
      speaker: plan.speaker,
      priority: priority,
      playbackRecord: playbackRecord
    )
    appendGeminiDebug(
      spokeImmediately
        ? "Piece voice handed to speech engine for \(plan.speaker.displayName.lowercased())."
        : "Piece voice did not reach speech engine for \(plan.speaker.displayName.lowercased())."
    )
  }

  private func pickDistinctPassiveNarratorOption(
    _ options: [String],
    extraAvoiding additionalLines: [String] = []
  ) -> String {
    let avoidFingerprints = Set(
      recentPassiveNarratorLines(limit: 6)
        .map { pieceVoiceFingerprint($0) }
        .filter { !$0.isEmpty }
        + additionalLines.map { pieceVoiceFingerprint($0) }.filter { !$0.isEmpty }
    )
    let shuffledOptions = options.shuffled()
    if let distinctOption = shuffledOptions.first(where: { !avoidFingerprints.contains(pieceVoiceFingerprint($0)) }) {
      return distinctOption
    }
    return shuffledOptions.first ?? options.first ?? ""
  }

  private func resolveDistinctPassiveNarratorLine(
    _ text: String,
    for context: GeminiPassiveNarratorLineContext
  ) -> String {
    guard hasRecentPassiveNarratorLine(text) else {
      return text
    }
    appendGeminiDebug("Passive narrator line repeated recent wording; using a varied local fallback.")
    return fallbackPassiveNarratorLine(for: context, avoiding: [text])
  }

  private func emitPassiveNarratorLine(
    _ text: String,
    context: GeminiPassiveNarratorLineContext,
    statusPrefix: String
  ) {
    let resolvedText = resolveDistinctPassiveNarratorLine(text, for: context)
    let debugLine = "Narrator: \(resolvedText)"
    pieceVoiceStatusText = "\(statusPrefix): \(debugLine)"
    let playbackRecord = automaticDialoguePlaybackRecord(
      for: AutonomousDialogueMemoryEntry(
        speakerClass: .narrator,
        speakerName: "Narrator",
        text: resolvedText,
        pieceType: nil,
        pieceColor: nil,
        pieceIdentity: nil
      ),
      highlightedSquare: nil
    )
    let spokeImmediately = speakPassiveNarratorLine(
      text: resolvedText,
      playbackRecord: playbackRecord
    )
    appendGeminiDebug(
      spokeImmediately
        ? "Passive narrator handed to speech engine."
        : "Passive narrator did not reach speech engine."
    )
  }

  private func fallbackPassiveNarratorLine(
    for context: GeminiPassiveNarratorLineContext,
    avoiding additionalLines: [String] = []
  ) -> String {
    if context.phase == .opening {
      return pickDistinctPassiveNarratorOption(
        [
          "The center is still untouched, but both kings already have a future to answer for.",
          "Development has not begun, and already the center is waiting for a fight.",
          "Before the first clash, the center and the kings are already part of the story."
        ],
        extraAvoiding: additionalLines
      )
    }

    if context.isCheckmate {
      return pickDistinctPassiveNarratorOption(
        [
          "The king has no shelter left, and no square left worth naming.",
          "That king has run out of squares, and the whole position folds with him.",
          "The mating net closes because the king has nowhere clean to run."
        ],
        extraAvoiding: additionalLines
      )
    }

    if context.isCheck {
      return pickDistinctPassiveNarratorOption(
        [
          "The king is in check now, and the defenders are late to the square.",
          "That move reaches the king directly and leaves the defenders scrambling.",
          "The king has been forced into the conversation, and the cover around him is thinner."
        ],
        extraAvoiding: additionalLines
      )
    }

    if let evalDelta = context.evalDelta, abs(evalDelta) >= Self.substantialGainThreshold {
      return pickDistinctPassiveNarratorOption(
        evalDelta > 0
          ? [
            "That move improves the coordination, and now one side owns more of the center.",
            "The balance shifts because one army is suddenly working on the same squares.",
            "What looked tidy a moment ago now favors the side with the cleaner activity."
          ]
          : [
            "That slip loosens the coordination, and the better squares belong to the other side now.",
            "The position tilts because one side has ceded too much space and too much timing.",
            "A small error matters here because the loose piece and the weak squares arrive together."
          ],
        extraAvoiding: additionalLines
      )
    }

    if context.isNearEnemyKing || context.isForkThreat {
      return pickDistinctPassiveNarratorOption(
        [
          "The king and the loose pieces around him are beginning to share the same danger.",
          "That shape points straight at the king side, and the nearby defenders feel it too.",
          "The threat is real now: too many targets sit on the same line of fire."
        ],
        extraAvoiding: additionalLines
      )
    }

    if context.isRetreat {
      return pickDistinctPassiveNarratorOption(
        [
          "The retreat yields ground, but it keeps the piece tied to its defenders.",
          "That step back gives up space, yet it repairs a line that was starting to fray.",
          "The piece withdraws, but the real point is to keep the structure from cracking."
        ],
        extraAvoiding: additionalLines
      )
    }

    return pickDistinctPassiveNarratorOption(
      [
        "The center is still contested, and neither side has solved the coordination problem.",
        "No piece falls, but the fight for space and clean development keeps tightening.",
        "A quiet move, but it still changes which side owns the cleaner squares."
      ],
      extraAvoiding: additionalLines
    )
  }

  private func fallbackPieceVoiceLine(
    for plan: PieceVoiceRequestPlan,
    avoiding additionalLines: [String] = []
  ) -> String {
    let context = plan.context
    let underutilizedCue = context.underutilizedReason?.lowercased() ?? ""

    if context.dialogueMode == .underutilizedSnark {
      switch plan.speaker {
      case .pawn:
        return pickDistinctPieceVoiceOption(
          [
            "Point me at something worth dying for.",
            "I am still here waiting for a proper march.",
            "I did not join this war to rot in place.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      case .rook:
        return pickDistinctPieceVoiceOption(
          underutilizedCue.contains("file")
            ? [
              "I have no file and no fight.",
              "I am still caged behind a dead file.",
              "Give me a file or stop pretending I matter.",
            ]
            : [
              "I am wasting away on the back rank.",
              "I was built for files, not bench duty.",
              "I am all tower and no battlefield.",
            ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      case .knight:
        return pickDistinctPieceVoiceOption(
          [
            "I am a noble steed, wasted in reserve.",
            "I remain leashed while plainer creatures blunder ahead.",
            "I was promised glory, not storage.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      case .bishop:
        return pickDistinctPieceVoiceOption(
          underutilizedCue.contains("diagonal")
            ? [
              "I have had ample time to study blocked diagonals.",
              "My diagonal is sealed, and still I wait.",
              "I preach to pawns because no line will open.",
            ]
            : [
              "I have had plenty of time to read the good book back here.",
              "I am all scripture and no battlefield.",
              "Even I tire of blessing traffic.",
            ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      case .queen:
        return pickDistinctPieceVoiceOption(
          [
            "Must I win this from the bench?",
            "I am still waiting while lesser pieces improvise.",
            "I do adore being ignored until disaster arrives.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      case .king:
        return pickDistinctPieceVoiceOption(
          [
            "I am safer when forgotten, frankly.",
            "I prefer neglect to catastrophe.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
    }

    let loopSignals = recentPieceDialogueLoopSignals()
    if context.dialogueMode == .historyReactive, context.latestPieceLine != nil {
      return pickDistinctPieceVoiceOption(
        loopSignals.loopDetected || loopSignals.directAddressCount > 0
          ? [
            "Enough chatter. The board answers now.",
            "The talk loops. The battle does not.",
            "Words stall. The position keeps moving.",
            "Let the move speak louder than the noise.",
          ]
          : [
            "Talk is cheap. The board answers now.",
            "The chatter is noted. The move matters more.",
            "Words travel fast. Steel travels farther.",
            "The square changes hands while the boasting continues.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    }

    switch plan.speaker {
    case .pawn:
      if context.isCapture {
        return pickDistinctPieceVoiceOption(
          [
            "Another body falls in the mud.",
            "The mud takes one more.",
            "One more fool sinks under my boots.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCheck {
        return pickDistinctPieceVoiceOption(
          [
            "Press on. Their king can smell me.",
            "Good. Their king finally smells the trench.",
            "Closer now. Let their king taste the mud.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isRetreat {
        return pickDistinctPieceVoiceOption(
          [
            "Back a step. Then back into blood.",
            "One pace back. Then straight into slaughter.",
            "I yield a step, not the fight.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "I am ready for the next brawl.",
            "Say the word. I will wade in again.",
            "The trench is quiet. I do not trust it.",
          ]
          : [
            "Forward. The trench still wants bodies.",
            "Forward again. Mud first, glory second.",
            "Boots forward. The killing field is hungry.",
            "Another square taken. The trench opens wider.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    case .rook:
      if context.isCapture {
        return pickDistinctPieceVoiceOption(
          [
            "I break their line and keep rolling.",
            "One wall down. I keep coming.",
            "Their line buckles under me.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCheck {
        return pickDistinctPieceVoiceOption(
          [
            "Their king hears the tower coming.",
            "The tower is at their king's door.",
            "Let their king hear the stones grind.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isPinned || context.isAttackedByMultiple {
        return pickDistinctPieceVoiceOption(
          [
            "Let them crowd me. I crush through crowds.",
            "Crowds are softer than stone.",
            "Pile them up. I flatten piles.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "Hold the file. I am not done here.",
            "This file stays mine until it splinters.",
            "I hold this lane and dare them closer.",
          ]
          : [
            "I move once. The whole file shudders.",
            "One shove from me shifts the board.",
            "The file groans when I advance.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    case .knight:
      if context.isForkThreat {
        return pickDistinctPieceVoiceOption(
          [
            "A graceful fork is already in motion.",
            "Two throats already fit this angle.",
            "I have prepared a very elegant fork.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCapture {
        return pickDistinctPieceVoiceOption(
          [
            "A neat cut. The dance continues.",
            "A lovely cut. The dance improves.",
            "A tidy little kill. Onward.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isRetreat {
        return pickDistinctPieceVoiceOption(
          [
            "A measured retreat sharpens the next strike.",
            "One courteous retreat, then mischief.",
            "I withdraw only to improve the angle.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "I circle quietly before the next flourish.",
            "Patience. The next leap should be prettier.",
            "I am merely choosing the most dramatic route.",
          ]
          : [
            "A stylish leap was overdue.",
            "At last, a square with some flair.",
            "I do prefer an entrance with shape.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    case .bishop:
      if context.isCheck {
        return pickDistinctPieceVoiceOption(
          [
            "Judgment reaches their king at last.",
            "At last, judgment touches their king.",
            "Their king stands inside the sermon now.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCapture {
        return pickDistinctPieceVoiceOption(
          [
            "Another sinner falls under holy fire.",
            "One more sinner burns on the diagonal.",
            "Holy fire claims another unbeliever.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isPinned {
        return pickDistinctPieceVoiceOption(
          [
            "Even pinned, I keep my faith and aim.",
            "My body is pinned. My judgment is not.",
            "Pin the flesh if you like. The faith still fires.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "I watch the diagonal and wait for sin.",
            "The diagonal is quiet. Sin rarely stays quiet.",
            "I keep the diagonal clean for judgment.",
          ]
          : [
            "This diagonal now belongs to judgment.",
            "I have claimed this diagonal in righteous fire.",
            "The diagonal bends toward judgment now.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    case .queen:
      if context.isCheck {
        return pickDistinctPieceVoiceOption(
          [
            "There. The king finally notices me.",
            "Good. Their king has learned my name.",
            "At last, their king pays attention.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCapture {
        return pickDistinctPieceVoiceOption(
          [
            "Cleanup, again. You are welcome.",
            "I clean up. As usual.",
            "Another mess fixed by the only competent piece.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isAttacked {
        return pickDistinctPieceVoiceOption(
          [
            "Honestly, this square had better be worth it.",
            "If I am taking fire, this had better matter.",
            "Charming. They finally noticed quality.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "I remain the only adult on this board.",
            "Someone on this board must stay competent.",
            "I supervise because clearly no one else can.",
          ]
          : [
            "Try to keep up with my standards.",
            "Do keep pace. I dislike waiting.",
            "I moved. The rest of you may now catch up.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    case .king:
      if context.positionState == .losing || context.isAttacked {
        return pickDistinctPieceVoiceOption(
          [
            "Keep them off me and we survive this.",
            "Hold them back and I may keep the crown.",
            "Stand between me and disaster, immediately.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      if context.isCheck {
        return pickDistinctPieceVoiceOption(
          [
            "Good. Let them feel the crown advance.",
            "Yes. Let them learn what the crown can do.",
            "The crown advances. They will answer for it.",
          ],
          for: plan.speaker,
          extraAvoiding: additionalLines
        )
      }
      return pickDistinctPieceVoiceOption(
        context.contextMode == .ambient
          ? [
            "Hold formation. The crown is still intact.",
            "Hold steady. The crown still stands.",
            "Keep rank. The throne still breathes.",
          ]
          : [
            "The crown steps forward. Behave accordingly.",
            "I advance. Let the board remember its king.",
            "The crown moves. Make yourselves useful.",
          ],
        for: plan.speaker,
        extraAvoiding: additionalLines
      )
    }
  }

  private func cappedPieceVoiceLineText(
    _ text: String,
    maxCharacters: Int? = nil
  ) -> String {
    let _ = maxCharacters
    let normalized = text
      .replacingOccurrences(of: "[“”\"]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return ""
    }

    let withoutLabel = normalized.replacingOccurrences(
      of: #"^[A-Za-z ]{2,20}:\s*"#,
      with: "",
      options: .regularExpression
    )
    let trimmed = withoutLabel.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,;:-"))
    guard !trimmed.isEmpty else {
      return ""
    }

    return trimmed
  }

  private func chebyshevDistance(from source: BoardSquare, to target: BoardSquare) -> Int {
    max(abs(source.file - target.file), abs(source.rank - target.rank))
  }

  private func movedDeeperIntoEnemyHalf(_ move: ChessMove) -> Bool {
    switch move.piece.color {
    case .white:
      return move.to.rank > move.from.rank
    case .black:
      return move.to.rank < move.from.rank
    }
  }

  private func threatensFork(
    movedPiece: ChessPieceState,
    targetSquares: Set<BoardSquare>,
    in state: ChessGameState,
    enemyKingSquare: BoardSquare?
  ) -> Bool {
    guard !targetSquares.isEmpty else {
      return false
    }

    var threatScore = 0
    for square in targetSquares {
      if square == enemyKingSquare {
        threatScore += 1
        continue
      }

      guard let target = state.piece(at: square) else {
        continue
      }

      switch target.kind {
      case .queen, .rook, .bishop, .knight:
        threatScore += 1
      case .king:
        threatScore += 1
      case .pawn:
        if movedPiece.kind == .knight || movedPiece.kind == .queen {
          threatScore += 1
        }
      }

      if threatScore >= 2 {
        return true
      }
    }

    return false
  }

  private func classifyMove(
    before: StockfishAnalysis?,
    after: StockfishAnalysis?,
    moverColor: ChessColor
  ) -> MoveClassification? {
    guard let swing = evalSwing(before: before, after: after, moverColor: moverColor) else {
      return nil
    }

    switch swing {
    case 160...:
      return .brilliant
    case 45...:
      return .good
    case -44...44:
      return .ok
    case -139 ... -45:
      return .inaccuracy
    case -299 ... -140:
      return .mistake
    default:
      return .blunder
    }
  }

  private func swingDescription(
    before: StockfishAnalysis?,
    after: StockfishAnalysis?,
    moverColor: ChessColor
  ) -> String {
    guard let swing = evalSwing(before: before, after: after, moverColor: moverColor) else {
      return "Stockfish unavailable"
    }
    let sign = swing >= 0 ? "+" : ""
    return "\(sign)\(swing) cp swing"
  }

  private func evalSwing(
    before: StockfishAnalysis?,
    after: StockfishAnalysis?,
    moverColor: ChessColor
  ) -> Int? {
    moveEvaluationDelta(before: before, after: after, moverColor: moverColor)?.deltaW
  }

  private func moveEvaluationDelta(
    before: StockfishAnalysis?,
    after: StockfishAnalysis?,
    moverColor: ChessColor
  ) -> MoveEvaluationDelta? {
    guard let before, let after else {
      return nil
    }

    return MoveEvaluationDelta(
      evalBefore: before.perspectiveScore(for: moverColor),
      evalAfter: after.perspectiveScore(for: moverColor)
    )
  }

  private func preferredEngineCandidateMove(
    from analysis: StockfishAnalysis,
    selection: EngineReplySelection
  ) -> String? {
    let rankedMoves = analysis.topUniqueMoves.compactMap(\.move)
    switch selection {
    case .best:
      return rankedMoves.first ?? analysis.bestMove
    case .reviewThirdBest:
      // Review mode deliberately chooses a softer engine reply so the player can
      // continue the position instead of getting crushed by the top line every time.
      return rankedMoves.dropFirst(2).first
        ?? rankedMoves.dropFirst().first
        ?? rankedMoves.first
        ?? analysis.bestMove
    }
  }

  private func describe(analysis: StockfishAnalysis, moverColor: ChessColor) -> String {
    if let mateIn = analysis.mateIn {
      return moverColor == .white
        ? "mate \(mateIn)"
        : "mate \(mateIn)"
    }

    let cp = analysis.scoreCp ?? 0
    return "\(cp) cp"
  }

  private func updateAnalysisPresentation(_ analysis: StockfishAnalysis) {
    suggestedMoveText = analysis.bestMove == nil || analysis.bestMove == "(none)"
      ? "Engine suggestion unavailable."
      : "Engine suggestion prepared."
    whiteEvalText = "White eval: \(analysis.formattedEval(for: .white))"
    blackEvalText = "Black eval: \(analysis.formattedEval(for: .black))"
    analysisTimingText = "Last analysis: \(analysis.durationMs)ms"
  }

  private func prefetchHint(
    for state: ChessGameState,
    analysis: StockfishAnalysis,
    revealWhenReady: Bool = false,
    narrateWhenReady: Bool = false,
    allowRepeatNarration: Bool = false
  ) {
    guard hintService.isConfigured else {
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = defaultHintStatus()
      appendGeminiDebug("Skipped prefetch because ARChessAPIBaseURL is not configured.")
      return
    }

    guard shouldPrefetchHint(for: state) else {
      hintTask?.cancel()
      hintTask = nil
      currentHintKey = nil
      pendingHintReveal = false
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = "Hints wake up when it is your turn."
      appendGeminiDebug("Skipped prefetch because it is not the local player's turn.")
      return
    }

    guard let context = makeHintContext(for: state, analysis: analysis) else {
      visibleHintText = nil
      isHintLoading = false
      hintStatusText = "Hint unavailable for this position."
      appendGeminiDebug("Skipped prefetch because the Stockfish best move could not be converted into a hint context.")
      return
    }

    let key = hintKey(for: context)
    let keyChanged = currentHintKey != key
    if keyChanged {
      visibleHintText = nil
      pendingHintReveal = false
      pendingHintNarration = false
    }

    currentHintKey = key
    pendingHintReveal = pendingHintReveal || revealWhenReady
    pendingHintNarration = pendingHintNarration || narrateWhenReady

    if let cached = hintCache[key] {
      isHintLoading = false
      hintStatusText = "Hint ready. Tap Hint."
      appendGeminiDebug("Served cached Gemini hint for current turn.")
      if pendingHintReveal {
        visibleHintText = cached
        pendingHintReveal = false
      }
      if pendingHintNarration {
        pendingHintNarration = false
        narrateGeminiHintIfNeeded(text: cached, key: key, allowRepeat: allowRepeatNarration)
      }
      return
    }

    if geminiConnectionState == .error, geminiLooksTerminal(geminiConnectionLastError) {
      isHintLoading = false
      hintStatusText = "Hint unavailable right now."
      appendGeminiDebug("Skipped hint request because Gemini Live reported a terminal auth/config error.")
      return
    }

    let shouldFetchImmediately = revealWhenReady || narrateWhenReady || pendingHintNarration

    if !shouldFetchImmediately {
      if let retryAt = nextGeminiBackgroundRetryAt, retryAt > Date() {
        isHintLoading = false
        hintStatusText = geminiConnectionState == .connected
          ? "Fun hints warm up in the background when it is your turn."
          : "Hint warming up in the background."
        appendGeminiDebug("Skipped Gemini prefetch because the retry cooldown is still active.")
        return
      }

      guard geminiConnectionState == .connected else {
        isHintLoading = false
        hintStatusText = geminiConnectionState == .error
          ? "Hint unavailable right now."
          : "Hint warming up in the background."
        appendGeminiDebug("Deferred Gemini prefetch until Live finishes connecting.")
        return
      }
    }

    isHintLoading = true
    hintStatusText = shouldFetchImmediately ? "Loading hint..." : "Preparing a playful hint..."
    appendGeminiDebug("Prefetching Gemini hint in background for move \(context.bestMove).")

    hintTask?.cancel()
    hintTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        let hint = try await self.hintService.fetchHint(for: context)
        await MainActor.run {
          guard self.currentHintKey == key else {
            return
          }

          self.hintTask = nil
          self.hintCache[key] = hint
          self.nextGeminiBackgroundRetryAt = nil
          self.isHintLoading = false
          self.hintStatusText = "Hint ready. Tap Hint."
          self.appendGeminiDebug("Gemini hint ready and cached for the current turn.")
          if self.pendingHintReveal {
            self.visibleHintText = hint
            self.pendingHintReveal = false
            self.appendGeminiDebug("Gemini hint revealed instantly from the completed prefetch.")
          }
          if self.pendingHintNarration {
            self.pendingHintNarration = false
            self.narrateGeminiHintIfNeeded(text: hint, key: key, allowRepeat: allowRepeatNarration)
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          self.appendGeminiDebug("Gemini hint request was cancelled because a newer turn replaced it.")
        }
        return
      } catch {
        await MainActor.run {
          guard self.currentHintKey == key else {
            return
          }

          self.hintTask = nil
          self.recordGeminiHintFailure(error)
          self.isHintLoading = false
          self.visibleHintText = nil
          self.pendingHintReveal = false
          self.hintStatusText = "Hint unavailable right now."
          self.appendGeminiDebug("Gemini hint request failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func scheduleCoachCommentary(for state: ChessGameState) {
    guard hintService.isConfigured else {
      return
    }

    guard geminiConnectionState == .connected else {
      return
    }

    if geminiConnectionState == .error, geminiLooksTerminal(geminiConnectionLastError) {
      return
    }

    if let retryAt = nextGeminiCoachRetryAt, retryAt > Date() {
      return
    }

    let context = GeminiCoachCommentaryContext(
      fen: state.fenString,
      narrator: narrator
    )
    if latestAnalyzedFEN == context.fen || pendingCommentaryFEN == context.fen {
      return
    }

    latestCommentaryRequestID += 1
    let requestID = latestCommentaryRequestID
    pendingCommentaryFEN = context.fen

    commentaryRequestTask?.cancel()
    commentaryRequestTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        try await Task.sleep(nanoseconds: 350_000_000)
        let commentary = try await self.hintService.fetchCoachCommentary(for: context)
        await MainActor.run {
          guard self.latestCommentaryRequestID == requestID else {
            return
          }

          self.commentaryRequestTask = nil
          self.pendingCommentaryFEN = nil
          self.nextGeminiCoachRetryAt = nil
          self.latestAnalyzedFEN = context.fen
          self.applyCoachCommentary(commentary)
          self.appendGeminiDebug("Gemini coach commentary updated for the current position.")
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run {
          guard self.latestCommentaryRequestID == requestID else {
            return
          }

          self.commentaryRequestTask = nil
          self.pendingCommentaryFEN = nil
          self.nextGeminiCoachRetryAt = Date().addingTimeInterval(
            self.geminiLooksTerminal(error.localizedDescription) ? 60 : 15
          )
          self.appendGeminiDebug("Gemini coach commentary request failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func applyCoachCommentary(_ commentary: GeminiCoachCommentary) {
    let normalizedLines = uniquePreservingOrder(
      commentary.coachLines.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
    )
    coachLines = normalizedLines
    recordCoachDialogueLines(normalizedLines)
    topWorkers = Array(commentary.topWorkers.prefix(3))
    topTraitors = Array(commentary.topTraitors.prefix(3))
  }

  private func narrateGeminiHintIfNeeded(text: String, key: String, allowRepeat: Bool = false) {
    guard allowRepeat || !narratedHintKeys.contains(key) else {
      appendGeminiDebug("Skipped Gemini narration because this hint was already narrated for the current turn.")
      return
    }

    narratedHintKeys.insert(key)
    appendGeminiDebug(
      allowRepeat
        ? "Narrating Gemini hint because the hint button was pressed."
        : "Narrating Gemini hint because the side to move just lost eval."
    )
    _ = speakHintNarration(text: text, priority: allowRepeat ? .urgent : .normal)
  }

  private func startGeminiStatusMonitoring() {
    geminiStatusTask?.cancel()
    geminiStatusTask = nil

    guard hintService.isConfigured else {
      let unavailable = GeminiLiveStatusPayload(
        state: .error,
        lastError: "ARChessAPIBaseURL is not configured.",
        since: nil
      )
      applyGeminiStatus(unavailable, emitDebugLog: false)
      return
    }

    geminiStatusTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        await self.refreshGeminiStatus()
        try? await Task.sleep(nanoseconds: self.geminiStatusPollInterval())
      }
    }
  }

  private func refreshGeminiStatus(emitDebugLog: Bool = true) async {
    guard hintService.isConfigured else {
      return
    }

    do {
      let status = try await hintService.fetchConnectionStatus()
      applyGeminiStatus(status, emitDebugLog: emitDebugLog)
    } catch {
      let failed = GeminiLiveStatusPayload(
        state: .error,
        lastError: error.localizedDescription,
        since: nil
      )
      applyGeminiStatus(failed, emitDebugLog: emitDebugLog)
    }
  }

  private func applyGeminiStatus(_ status: GeminiLiveStatusPayload, emitDebugLog: Bool) {
    let previous = lastGeminiStatusSnapshot
    lastGeminiStatusSnapshot = status
    geminiConnectionState = status.state
    geminiConnectionLastError = status.lastError
    geminiConnectionSince = status.since

    guard emitDebugLog, previous != status else {
      return
    }

    if let error = status.lastError, !error.isEmpty {
      appendGeminiDebug("Gemini Live status -> \(status.state.rawValue): \(error)")
    } else {
      appendGeminiDebug("Gemini Live status -> \(status.state.rawValue)")
    }

    if status.state == .connected {
      nextGeminiBackgroundRetryAt = nil
      maybeResumeGeminiPrefetch(after: previous, status: status)
      maybeResumeGeminiCoachCommentary(after: previous, status: status)
    }
  }

  private func defaultHintStatus() -> String {
    hintService.isConfigured
      ? "Fun hints warm up in the background when it is your turn."
      : "Set ARChessAPIBaseURL to enable Gemini hints."
  }

  private func appendGeminiDebug(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let stamped = "[\(formatter.string(from: Date()))] \(message)"
    geminiDebugLines.append(stamped)
    if geminiDebugLines.count > 36 {
      geminiDebugLines.removeFirst(geminiDebugLines.count - 36)
    }
  }

  private func geminiStatusPollInterval() -> UInt64 {
    let seconds: UInt64
    switch geminiConnectionState {
    case .connected:
      seconds = 15
    case .connecting:
      seconds = 3
    case .disconnected:
      seconds = 5
    case .error:
      seconds = geminiLooksTerminal(geminiConnectionLastError) ? 30 : 10
    }

    return seconds * 1_000_000_000
  }

  private func recordGeminiHintFailure(_ error: Error) {
    let description = error.localizedDescription
    let cooldownSeconds: TimeInterval = geminiLooksTerminal(description) ? 60 : 12
    nextGeminiBackgroundRetryAt = Date().addingTimeInterval(cooldownSeconds)
  }

  private func geminiLooksTerminal(_ message: String?) -> Bool {
    let lowered = message?.lowercased() ?? ""
    guard !lowered.isEmpty else {
      return false
    }

    if lowered.contains("api key") && (lowered.contains("expir") || lowered.contains("invalid")) {
      return true
    }

    return lowered.contains("permission_denied")
      || lowered.contains("unauthenticated")
      || lowered.contains("forbidden")
      || lowered.contains("invalid frame payload data")
  }

  private func maybeResumeGeminiPrefetch(
    after previous: GeminiLiveStatusPayload?,
    status: GeminiLiveStatusPayload
  ) {
    guard previous?.state != status.state else {
      return
    }

    guard status.state == .connected else {
      return
    }

    guard hintTask == nil else {
      return
    }

    guard let state = stateProvider?(),
          let cached = cachedAnalysis,
          cached.fen == state.fenString,
          shouldPrefetchHint(for: state) else {
      return
    }

    appendGeminiDebug("Gemini Live connected; resuming background hint prefetch for the current turn.")
    prefetchHint(for: state, analysis: cached.analysis)
  }

  private func maybeResumeGeminiCoachCommentary(
    after previous: GeminiLiveStatusPayload?,
    status: GeminiLiveStatusPayload
  ) {
    guard previous?.state != status.state else {
      return
    }

    guard status.state == .connected else {
      return
    }

    guard commentaryRequestTask == nil else {
      return
    }

    guard let state = stateProvider?() else {
      return
    }

    scheduleCoachCommentary(for: state)
  }

  private func uniquePreservingOrder(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for value in values {
      if seen.insert(value).inserted {
        ordered.append(value)
      }
    }
    return ordered
  }

  private func shouldPrefetchHint(for _: ChessGameState) -> Bool {
    hintAvailabilityProvider?() ?? true
  }

  private func makeHintContext(for state: ChessGameState, analysis: StockfishAnalysis) -> GeminiHintContext? {
    guard let bestMove = analysis.bestMove, bestMove != "(none)",
          let move = state.move(forUCI: bestMove) else {
      return nil
    }

    let afterState = state.applying(move)
    return GeminiHintContext(
      fen: state.fenString,
      recentHistory: recentHistoryProvider?(),
      bestMove: bestMove,
      sideToMove: state.turn,
      narrator: narrator,
      movingPiece: move.piece.kind,
      isCapture: move.captured != nil || move.isEnPassant,
      givesCheck: afterState.isInCheck(for: afterState.turn),
      themes: hintThemes(for: move, before: state, after: afterState)
    )
  }

  private func hintKey(for context: GeminiHintContext) -> String {
    context.fen + "|" + (context.recentHistory ?? "") + "|" + context.bestMove
  }

  private func hintThemes(
    for move: ChessMove,
    before: ChessGameState,
    after: ChessGameState
  ) -> [String] {
    var themes: [String] = []

    let centralFiles = 2...5
    let centralRanks = 2...5
    if centralFiles.contains(move.to.file), centralRanks.contains(move.to.rank) {
      themes.append("fight for the center")
    }

    if move.captured != nil || move.isEnPassant {
      themes.append("win material")
    }

    if move.rookMove != nil {
      themes.append("improve king safety")
    }

    if [.knight, .bishop, .rook, .queen].contains(move.piece.kind),
       before.fullmoveNumber <= 10,
       move.captured == nil {
      themes.append("develop a new piece")
    }

    if move.piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
      themes.append("gain space")
    }

    if after.isInCheck(for: after.turn) {
      themes.append("pressure the enemy king")
    }

    if themes.isEmpty {
      themes.append("improve piece activity")
    }

    return Array(Set(themes)).sorted()
  }


  private func bestMoveDescription(from analysis: StockfishAnalysis) -> String {
    guard let bestMove = analysis.bestMove, bestMove != "(none)" else {
      return "Next best move unavailable."
    }

    return "Next best move: \(humanReadableMove(bestMove))"
  }

  private func humanReadableMove(_ uci: String) -> String {
    guard uci.count >= 4 else {
      return uci
    }

    let from = String(uci.prefix(2))
    let to = String(uci.dropFirst(2).prefix(2))

    guard uci.count > 4 else {
      return "\(from) to \(to)"
    }

    let promotionCode = uci.suffix(1).lowercased()
    let promotionName: String
    switch promotionCode {
    case "q":
      promotionName = "queen"
    case "r":
      promotionName = "rook"
    case "b":
      promotionName = "bishop"
    case "n":
      promotionName = "knight"
    default:
      promotionName = String(promotionCode)
    }

    return "\(from) to \(to), promoting to \(promotionName)"
  }

  private func lines(for classification: MoveClassification) -> [SpokenLine] {
    switch classification {
    case .brilliant:
      return [
        SpokenLine(speaker: .knight, text: "That line was savage. I hunt, I strike, I feast.", pitch: 1.56, rate: 0.63, volume: 0.98),
        SpokenLine(speaker: .queen, text: "A gorgeous move. Power suits me, does it suit you?", pitch: 0.72, rate: 0.30, volume: 0.94),
      ]
    case .good:
      return [
        SpokenLine(speaker: .knight, text: "Clean kill. I like where this trail is going.", pitch: 1.46, rate: 0.60, volume: 0.96),
        SpokenLine(speaker: .queen, text: "Naturally. The board bends when I arrive.", pitch: 0.70, rate: 0.29, volume: 0.92),
      ]
    case .ok:
      return [
        SpokenLine(speaker: .pawn, text: "I'll gladly die for my country.", pitch: 0.98, rate: 0.44, volume: 0.84),
        SpokenLine(speaker: .king, text: "Good work, my subject.", pitch: 1.34, rate: 0.46, volume: 0.96),
      ]
    case .inaccuracy:
      return [
        SpokenLine(speaker: .bishop, text: "Only Christ can save sloppy plans like that.", pitch: 0.82, rate: 0.35, volume: 0.90),
      ]
    case .mistake:
      return [
        SpokenLine(speaker: .bishop, text: "Did you even study the board? Repent and recalculate.", pitch: 0.74, rate: 0.31, volume: 0.92),
      ]
    case .blunder:
      return [
        SpokenLine(speaker: .bishop, text: "That was heresy. Only prayer explains this blunder.", pitch: 0.70, rate: 0.27, volume: 0.96),
      ]
    }
  }

  private func captureLines(for kind: ChessPieceKind) -> [SpokenLine] {
    switch kind {
    case .rook:
      return [
        SpokenLine(speaker: .rook, text: "This beast was not ready to fall.", pitch: 1.52, rate: 0.52, volume: 1.0),
        SpokenLine(speaker: .rook, text: "You do not cage a beast for long.", pitch: 1.44, rate: 0.50, volume: 1.0),
      ]
    case .queen:
      return [
        SpokenLine(speaker: .queen, text: "Can I leave this king and be your queen instead?", pitch: 0.74, rate: 0.27, volume: 0.95),
        SpokenLine(speaker: .queen, text: "How cruel. I had so much more to offer.", pitch: 0.70, rate: 0.24, volume: 0.94),
      ]
    case .bishop:
      return [
        SpokenLine(speaker: .bishop, text: "I go now to Christ. Remember the lesson.", pitch: 0.88, rate: 0.35, volume: 0.88),
        SpokenLine(speaker: .bishop, text: "The heavens witness this capture.", pitch: 0.86, rate: 0.36, volume: 0.88),
      ]
    case .knight:
      return [
        SpokenLine(speaker: .knight, text: "I would have killed you first.", pitch: 1.50, rate: 0.64, volume: 0.98),
        SpokenLine(speaker: .knight, text: "The wolf bleeds, but the hunt remembers.", pitch: 1.44, rate: 0.58, volume: 0.96),
      ]
    case .pawn:
      return [
        SpokenLine(speaker: .pawn, text: "Goodbye my friends.", pitch: 0.98, rate: 0.42, volume: 0.86),
        SpokenLine(speaker: .pawn, text: "A soldier falls. The file stays thirsty.", pitch: 0.96, rate: 0.40, volume: 0.84),
      ]
    case .king:
      return [
        SpokenLine(speaker: .king, text: "This outcome was never approved by the crown.", pitch: 1.16, rate: 0.36, volume: 0.96),
      ]
    }
  }

  private func checkLines() -> [SpokenLine] {
    [
      SpokenLine(speaker: .king, text: "Wait. Wait. Leave me one pawn and we can make a deal.", pitch: 1.46, rate: 0.48, volume: 1.0),
      SpokenLine(speaker: .king, text: "Can we take this to a back room and negotiate?", pitch: 1.42, rate: 0.46, volume: 1.0),
    ]
  }

  private func checkmateLines() -> [SpokenLine] {
    [
      SpokenLine(speaker: .king, text: "No. No, no, this is not the official result.", pitch: 1.16, rate: 0.33, volume: 1.0),
      SpokenLine(speaker: .king, text: "My office collapses... and no deal saved it.", pitch: 0.96, rate: 0.26, volume: 0.92),
      SpokenLine(speaker: .king, text: "Tell history I was cornered, not weak.", pitch: 0.82, rate: 0.22, volume: 0.88),
    ]
  }

  private func moveFlavorLines(for kind: ChessPieceKind) -> [SpokenLine] {
    switch kind {
    case .king:
      return [
        SpokenLine(speaker: .king, text: "I'm the boss around here.", pitch: 1.20, rate: 0.38, volume: 0.96),
        SpokenLine(speaker: .king, text: "Stay calm. We can still broker a deal.", pitch: 1.16, rate: 0.36, volume: 0.94),
      ]
    case .queen:
      return [
        SpokenLine(speaker: .queen, text: "HAHAHAHAHA.", pitch: 0.72, rate: 0.28, volume: 0.94),
        SpokenLine(speaker: .queen, text: "I could rule either side, but this one wears me well.", pitch: 0.70, rate: 0.27, volume: 0.92),
      ]
    case .bishop:
      return [
        SpokenLine(speaker: .bishop, text: "Only Christ can save us.", pitch: 0.84, rate: 0.34, volume: 0.90),
        SpokenLine(speaker: .bishop, text: "This diagonal is safe under the watchful eye of my holy glock.", pitch: 0.86, rate: 0.35, volume: 0.88),
      ]
    case .knight:
      return [
        SpokenLine(speaker: .knight, text: "Let me off the leash.", pitch: 1.48, rate: 0.60, volume: 0.98),
        SpokenLine(speaker: .knight, text: "Tis not a challenge for me.", pitch: 1.44, rate: 0.58, volume: 0.96),
      ]
    case .rook:
      return [
        SpokenLine(speaker: .rook, text: "I guard the file. Nothing escapes.", pitch: 1.34, rate: 0.48, volume: 1.0),
        SpokenLine(speaker: .rook, text: "I am the largest.", pitch: 1.30, rate: 0.46, volume: 0.98),
      ]
    case .pawn:
      return [
        SpokenLine(speaker: .pawn, text: "I'll gladly die for my country.", pitch: 0.98, rate: 0.43, volume: 0.86),
        SpokenLine(speaker: .pawn, text: "Coming through!", pitch: 0.96, rate: 0.41, volume: 0.84),
      ]
    }
  }

  private func ambientMoveFlavorLines() -> [SpokenLine] {
    let weightedKinds: [(ChessPieceKind, Int)] = [
      (.pawn, 1),
      (.rook, 3),
      (.knight, 3),
      (.bishop, 3),
      (.queen, 3),
      (.king, 3),
    ]

    let totalWeight = weightedKinds.reduce(0) { $0 + $1.1 }
    var roll = Int.random(in: 0..<max(totalWeight, 1))

    for (kind, weight) in weightedKinds {
      if roll < weight {
        return moveFlavorLines(for: kind)
      }
      roll -= weight
    }

    return moveFlavorLines(for: .knight)
  }

  private func weightedRandomLine(from lines: [SpokenLine]) -> SpokenLine? {
    guard !lines.isEmpty else {
      return nil
    }

    let weightedLines = lines.map { line in
      (line: line, weight: line.speaker == .pawn ? 1 : 3)
    }
    let totalWeight = weightedLines.reduce(0) { $0 + $1.weight }
    var roll = Int.random(in: 0..<max(totalWeight, 1))

    for weightedLine in weightedLines {
      if roll < weightedLine.weight {
        return weightedLine.line
      }
      roll -= weightedLine.weight
    }

    return weightedLines.last?.line
  }

  private func speakRandomLine(from lines: [SpokenLine], priority: SpeechPriority) -> Bool {
    guard let line = weightedRandomLine(from: lines) else {
      return false
    }

    if priority == .urgent {
      _ = synthesizer.stopSpeaking(at: .immediate)
      utteranceCaptions.removeAll()
    } else if synthesizer.isSpeaking {
      return false
    }

    let utterance = AVSpeechUtterance(string: line.text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.pitchMultiplier = min(max(resolvedPitch(for: line), 0.5), 2.0)
    utterance.rate = min(max(line.rate ?? line.speaker.defaultRate, 0.1), 0.65)
    utterance.volume = min(max(line.volume ?? line.speaker.defaultVolume, 0.0), 1.0)
    utterance.preUtteranceDelay = 0.02
    utteranceCaptions[ObjectIdentifier(utterance)] = Caption(speaker: line.speaker, line: line.text)
    maybeHighlightNarrationFocus(line.text)
    synthesizer.speak(utterance)
    return true
  }

  private func speakHintNarration(text: String, priority: SpeechPriority) -> Bool {
    speakGeminiNarration(text: text, title: "Gemini Hint", priority: priority)
  }

  private func speakPassiveNarratorLine(
    text: String,
    playbackRecord: AutomaticDialoguePlaybackRecord?
  ) -> Bool {
    appendGeminiDebug("Preparing passive narrator Gemini Live speech.")
    return speakGeneratedNarration(
      text: text,
      style: .automaticNarrator,
      priority: .normal,
      maxCharacters: Self.passiveNarratorCharacterLimit,
      playbackRecord: playbackRecord
    )
  }

  private func speakGeminiNarration(text: String, title: String, priority: SpeechPriority) -> Bool {
    speakGeneratedNarration(
      text: text,
      style: .gemini(title: title),
      priority: priority,
      maxCharacters: geminiNarrationCharacterLimit
    )
  }

  private func speakGeneratedPieceVoiceLine(
    text: String,
    speaker: PersonalitySpeaker,
    priority: SpeechPriority,
    playbackRecord: AutomaticDialoguePlaybackRecord?
  ) -> Bool {
    appendGeminiDebug("Preparing piece voice speech for \(speaker.displayName.lowercased()).")
    return speakGeneratedNarration(
      text: text,
      style: .pieceVoice(speaker: speaker),
      priority: priority,
      maxCharacters: Self.pieceVoiceLineCharacterLimit,
      playbackRecord: playbackRecord
    )
  }

  private func speakGeneratedNarration(
    text: String,
    style: GeneratedNarrationStyle,
    priority: SpeechPriority,
    maxCharacters: Int,
    playbackRecord: AutomaticDialoguePlaybackRecord? = nil
  ) -> Bool {
    let sanitizedText: String
    switch style {
    case .gemini:
      sanitizedText = cappedNarrationText(text, maxCharacters: maxCharacters).text
    case .automaticNarrator:
      sanitizedText = cappedNarrationText(text, maxSentences: 2, maxCharacters: maxCharacters).text
    case .pieceVoice:
      sanitizedText = cappedPieceVoiceLineText(text, maxCharacters: maxCharacters)
    }

    guard !sanitizedText.isEmpty else {
      return false
    }

    if priority == .urgent, synthesizer.isSpeaking {
      appendGeminiDebug("Interrupting current speech so \(generatedNarrationDebugLabel(style)) can land on the move.")
      _ = synthesizer.stopSpeaking(at: .immediate)
      utteranceCaptions.removeAll()
    }

    let pieceAudioBusyDuration = blockingPieceAudioBusyDuration(
      for: style,
      priority: priority,
      rawDuration: pieceAudioBusyDurationProvider?() ?? 0
    )
    let narratorLiveBusy = passiveNarratorLiveSpeaker.isBusy
    let piperBusy = piperAutomaticSpeaker.isBusy
    if synthesizer.isSpeaking || pieceAudioBusyDuration > 0.05 || narratorLiveBusy || piperBusy {
      let retryDelay = max(pieceAudioBusyDuration, priority == .urgent ? 0.05 : 0.08)
      if case .pieceVoice(let speaker) = style {
        pieceVoiceStatusText = "Queued \(speaker.displayName) voice behind speech/SFX."
      }
      appendGeminiDebug(
        "Queued \(generatedNarrationDebugLabel(style)) speech. synthesizer=\(synthesizer.isSpeaking) narrator_busy=\(narratorLiveBusy) piper_busy=\(piperBusy) sfx_busy=\(String(format: "%.2f", pieceAudioBusyDuration)) retry=\(String(format: "%.2f", retryDelay))"
      )
      queuePendingGeneratedNarration(
        text: sanitizedText,
        style: style,
        playbackRecord: playbackRecord,
        retryAfter: retryDelay
      )
      return true
    }

    appendGeminiDebug("Starting \(generatedNarrationDebugLabel(style)) speech immediately.")
    return startGeneratedNarrationNow(
      text: sanitizedText,
      style: style,
      playbackRecord: playbackRecord
    )
  }

  private func startGeneratedNarrationNow(
    text: String,
    style: GeneratedNarrationStyle,
    playbackRecord: AutomaticDialoguePlaybackRecord? = nil
  ) -> Bool {
    do {
      try AudioSessionCoordinator.shared.activatePlaybackSession()
    } catch {
      appendGeminiDebug("Failed to activate playback session for \(generatedNarrationDebugLabel(style)): \(error.localizedDescription)")
    }

    switch style {
    case .automaticNarrator:
      return startAutomaticNarratorPlayback(
        text: text,
        playbackRecord: playbackRecord
      )
    case .pieceVoice:
      return startPiperAutomaticPlayback(
        text: text,
        style: style,
        playbackRecord: playbackRecord
      )
    case .gemini:
      break
    }

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

    switch style {
    case .gemini(let title):
      utterance.pitchMultiplier = 1.02
      utterance.rate = 0.47
      utterance.volume = 0.92
      utteranceCaptions[ObjectIdentifier(utterance)] = Caption(
        title: title,
        line: text,
        imageAssetName: "GeminiNarratorPortrait"
      )
      utteranceStyles[ObjectIdentifier(utterance)] = style
    case .pieceVoice(let speaker):
      utterance.pitchMultiplier = min(max(speaker.defaultPitch, 0.5), 2.0)
      utterance.rate = min(max(speaker.defaultRate, 0.1), 0.65)
      utterance.volume = min(max(speaker.defaultVolume, 0.0), 1.0)
      utteranceCaptions[ObjectIdentifier(utterance)] = Caption(speaker: speaker, line: text)
      utteranceStyles[ObjectIdentifier(utterance)] = style
    case .automaticNarrator:
      return false
    }

    if let playbackRecord {
      utteranceAutomaticDialogueRecords[ObjectIdentifier(utterance)] = playbackRecord
    }

    utterance.preUtteranceDelay = 0.02
    if case .pieceVoice(let speaker) = style {
      pieceVoiceStatusText = "Speaking \(speaker.displayName) voice."
    } else if case .automaticNarrator = style {
      pieceVoiceStatusText = "Speaking narrator line."
    }
    appendGeminiDebug("Speech start: \(generatedNarrationDebugLabel(style)) -> \(text)")
    maybeHighlightNarrationFocus(text)
    synthesizer.speak(utterance)
    return true
  }

  private func startAutomaticNarratorPlayback(
    text: String,
    playbackRecord: AutomaticDialoguePlaybackRecord?
  ) -> Bool {
    maybeHighlightNarrationFocus(text)
    let captionToken = UUID()
    showCommentaryCaption(
      Caption(
        title: "Narrator",
        line: text,
        imageAssetName: "GeminiNarratorPortrait"
      ),
      owner: .automaticPlayback(captionToken)
    )
    activeAutomaticPlaybackCaptionToken = captionToken
    pieceVoiceStatusText = "Speaking narrator line via Gemini Live."
    appendGeminiDebug("Speech start: Narrator via Gemini Live -> \(text)")

    if geminiConnectionState != .connected {
      appendGeminiDebug(
        "Gemini narrator audio skipped because Live is \(geminiConnectionState.rawValue). Using local fallback."
      )
      activePassiveAutomaticPlaybackRecord = nil
      activePassiveAutomaticPlaybackDidStart = false
      liveNarratorPlaybackOwnsCaption = false
      clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
      activeAutomaticPlaybackCaptionToken = nil
      activeAutomaticPlaybackSource = .none
      return startLocalAutomaticNarratorUtterance(
        text: text,
        playbackRecord: playbackRecord
      )
    }

    guard passiveNarratorLiveSpeaker.speak(line: text, role: .narrator) else {
      appendGeminiDebug("Gemini Live narrator audio unavailable right now; using local speech fallback.")
      activePassiveAutomaticPlaybackRecord = nil
      activePassiveAutomaticPlaybackDidStart = false
      liveNarratorPlaybackOwnsCaption = false
      clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
      activeAutomaticPlaybackCaptionToken = nil
      activeAutomaticPlaybackSource = .none
      return startLocalAutomaticNarratorUtterance(
        text: text,
        playbackRecord: playbackRecord
      )
    }

    activeAutomaticPlaybackSource = .geminiPassiveNarrator
    activePassiveAutomaticPlaybackRecord = playbackRecord
    activePassiveAutomaticPlaybackDidStart = false
    liveNarratorPlaybackOwnsCaption = true
    return true
  }

  private func startPiperAutomaticPlayback(
    text: String,
    style: GeneratedNarrationStyle,
    playbackRecord: AutomaticDialoguePlaybackRecord?
  ) -> Bool {
    maybeHighlightNarrationFocus(text)

    let captionToken = UUID()
    let speechLine: PiperAutomaticSpeaker.SpeechLine
    switch style {
    case .automaticNarrator:
      speechLine = PiperAutomaticSpeaker.SpeechLine(
        speakerType: .narrator,
        text: text
      )
      showCommentaryCaption(
        Caption(
          title: "Narrator",
          line: text,
          imageAssetName: "GeminiNarratorPortrait"
        ),
        owner: .automaticPlayback(captionToken)
      )
      pieceVoiceStatusText = "Speaking narrator line via Piper."
    case .pieceVoice(let speaker):
      speechLine = PiperAutomaticSpeaker.SpeechLine(
        speakerType: speaker.piperSpeakerType,
        text: text
      )
      showCommentaryCaption(
        Caption(speaker: speaker, line: text),
        owner: .automaticPlayback(captionToken)
      )
      pieceVoiceStatusText = "Speaking \(speaker.displayName) voice via Piper."
      setSpeakingPieceHighlight(square: playbackRecord?.highlightedSquare)
    case .gemini:
      return false
    }
    activeAutomaticPlaybackCaptionToken = captionToken

    appendGeminiDebug("Speech start: \(generatedNarrationDebugLabel(style)) via Piper -> \(text)")
    guard piperAutomaticSpeaker.speakLine(speechLine) else {
      appendGeminiDebug("Piper automatic audio unavailable right now; using local speech fallback.")
      activePassiveAutomaticPlaybackRecord = nil
      activePassiveAutomaticPlaybackDidStart = false
      liveNarratorPlaybackOwnsCaption = false
      clearCommentaryCaption(ifOwnedBy: .automaticPlayback(captionToken))
      activeAutomaticPlaybackCaptionToken = nil
      activeAutomaticPlaybackSource = .none
      switch style {
      case .automaticNarrator:
        return startLocalAutomaticNarratorUtterance(
          text: text,
          playbackRecord: playbackRecord
        )
      case .pieceVoice(let speaker):
        return startLocalPieceVoiceUtterance(
          text: text,
          speaker: speaker,
          playbackRecord: playbackRecord
        )
      case .gemini:
        return false
      }
    }

    activeAutomaticPlaybackSource = .piperAutomatic
    activePassiveAutomaticPlaybackRecord = playbackRecord
    activePassiveAutomaticPlaybackDidStart = false
    liveNarratorPlaybackOwnsCaption = true
    return true
  }

  private func showCommentaryCaption(
    _ caption: Caption,
    owner: CommentaryCaptionOwner
  ) {
    self.caption = caption
    commentaryCaptionOwner = owner
  }

  private func clearCommentaryCaption(ifOwnedBy owner: CommentaryCaptionOwner? = nil) {
    if let owner, commentaryCaptionOwner != owner {
      return
    }
    caption = nil
    commentaryCaptionOwner = .none
  }

  private func startLocalAutomaticNarratorUtterance(
    text: String,
    playbackRecord: AutomaticDialoguePlaybackRecord? = nil
  ) -> Bool {
    activeAutomaticPlaybackSource = .none
    liveNarratorPlaybackOwnsCaption = false
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.pitchMultiplier = 0.98
    utterance.rate = 0.45
    utterance.volume = 0.94
    utterance.preUtteranceDelay = 0.02
    utteranceCaptions[ObjectIdentifier(utterance)] = Caption(
      title: "Narrator",
      line: text,
      imageAssetName: "GeminiNarratorPortrait"
    )
    utteranceStyles[ObjectIdentifier(utterance)] = .automaticNarrator
    if let playbackRecord {
      utteranceAutomaticDialogueRecords[ObjectIdentifier(utterance)] = playbackRecord
    }
    pieceVoiceStatusText = "Speaking narrator line via local fallback."
    appendGeminiDebug("Speech start: Narrator (local fallback) -> \(text)")
    maybeHighlightNarrationFocus(text)
    synthesizer.speak(utterance)
    return true
  }

  private func startLocalPieceVoiceUtterance(
    text: String,
    speaker: PersonalitySpeaker,
    playbackRecord: AutomaticDialoguePlaybackRecord? = nil
  ) -> Bool {
    activeAutomaticPlaybackSource = .none
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.pitchMultiplier = min(max(speaker.defaultPitch, 0.5), 2.0)
    utterance.rate = min(max(speaker.defaultRate, 0.1), 0.65)
    utterance.volume = min(max(speaker.defaultVolume, 0.0), 1.0)
    utterance.preUtteranceDelay = 0.02
    utteranceCaptions[ObjectIdentifier(utterance)] = Caption(speaker: speaker, line: text)
    utteranceStyles[ObjectIdentifier(utterance)] = .pieceVoice(speaker: speaker)
    if let playbackRecord {
      utteranceAutomaticDialogueRecords[ObjectIdentifier(utterance)] = playbackRecord
    }
    pieceVoiceStatusText = "Speaking \(speaker.displayName) voice via local fallback."
    appendGeminiDebug("Speech start: \(speaker.displayName) piece voice (local fallback) -> \(text)")
    maybeHighlightNarrationFocus(text)
    synthesizer.speak(utterance)
    return true
  }

  private func queuePendingGeneratedNarration(
    text: String,
    style: GeneratedNarrationStyle,
    playbackRecord: AutomaticDialoguePlaybackRecord?,
    retryAfter delay: TimeInterval
  ) {
    let pending = PendingGeneratedNarration(
      text: text,
      style: style,
      playbackRecord: playbackRecord
    )
    switch style {
    case .automaticNarrator, .pieceVoice:
      pendingGeneratedNarrations.removeAll { existing in
        switch existing.style {
        case .automaticNarrator, .pieceVoice:
          return true
        case .gemini:
          return false
        }
      }
      pendingGeneratedNarrations.insert(pending, at: 0)
    case .gemini:
      pendingGeneratedNarrations.append(pending)
    }
    schedulePendingGeneratedNarrationFlush(after: delay)
  }

  private func schedulePendingGeneratedNarrationFlush(after delay: TimeInterval) {
    geminiNarrationRetryWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.flushPendingGeneratedNarrationIfPossible()
    }
    geminiNarrationRetryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: workItem)
  }

  private func flushPendingGeneratedNarrationIfPossible() {
    guard let pendingGeneratedNarration = pendingGeneratedNarrations.first else {
      return
    }

    let pieceAudioBusyDuration = blockingPieceAudioBusyDuration(
      for: pendingGeneratedNarration.style,
      priority: .urgent,
      rawDuration: pieceAudioBusyDurationProvider?() ?? 0
    )
    let narratorLiveBusy = passiveNarratorLiveSpeaker.isBusy
    guard !synthesizer.isSpeaking,
          !narratorLiveBusy,
          !piperAutomaticSpeaker.isBusy,
          pieceAudioBusyDuration <= 0.05 else {
      appendGeminiDebug(
        "Pending speech blocked for \(generatedNarrationDebugLabel(pendingGeneratedNarration.style)). synthesizer=\(synthesizer.isSpeaking) narrator_busy=\(narratorLiveBusy) piper_busy=\(piperAutomaticSpeaker.isBusy) sfx_busy=\(String(format: "%.2f", pieceAudioBusyDuration))"
      )
      schedulePendingGeneratedNarrationFlush(after: max(pieceAudioBusyDuration, 0.08))
      return
    }

    pendingGeneratedNarrations.removeFirst()
    geminiNarrationRetryWorkItem?.cancel()
    geminiNarrationRetryWorkItem = nil
    appendGeminiDebug("Flushing queued \(generatedNarrationDebugLabel(pendingGeneratedNarration.style)) speech.")
    _ = startGeneratedNarrationNow(
      text: pendingGeneratedNarration.text,
      style: pendingGeneratedNarration.style,
      playbackRecord: pendingGeneratedNarration.playbackRecord
    )
  }

  private func blockingPieceAudioBusyDuration(
    for style: GeneratedNarrationStyle,
    priority: SpeechPriority,
    rawDuration: TimeInterval
  ) -> TimeInterval {
    guard rawDuration > 0 else {
      return 0
    }

    if priority == .urgent,
       case .pieceVoice = style,
       rawDuration <= Self.urgentPieceVoiceSFXOverlapAllowance {
      return 0
    }

    return rawDuration
  }

  private func generatedNarrationDebugLabel(_ style: GeneratedNarrationStyle) -> String {
    switch style {
    case .gemini(let title):
      return title
    case .automaticNarrator:
      return "Narrator"
    case .pieceVoice(let speaker):
      return "\(speaker.displayName) piece voice"
    }
  }

  private func maybeHighlightNarrationFocus(_ text: String) {
    guard let squares = narrationHighlightSquares(for: text) else {
      return
    }
    narrationHighlightHandler?(squares, "Central focus")
  }

  private func resolvedPitch(for line: SpokenLine) -> Float {
    let base = line.speaker.defaultPitch
    guard let linePitch = line.pitch else {
      return base
    }

    // Keep each piece's core voice identity stable while allowing slight per-line variation.
    let blended = base + ((linePitch - base) * 0.10)
    return blended
  }
}

private struct PieceSpeechBubble: View {
  let caption: PiecePersonalityDirector.Caption

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      if let imageAssetName = caption.imageAssetName {
        NarrationPortraitView(imageAssetName: imageAssetName)
      } else if let speaker = caption.speaker {
        PiecePortraitView(speaker: speaker)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(caption.speakerName)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.74))

        Text(caption.line)
          .font(.system(size: 17, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineSpacing(2)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.92))
        .overlay(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    )
  }
}

private struct NarrationPortraitView: View {
  let imageAssetName: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.10))

      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.16), lineWidth: 1)

      Image(imageAssetName)
        .resizable()
        .scaledToFill()
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .frame(width: 66, height: 66)
  }
}

private struct PiecePortraitView: View {
  let speaker: PersonalitySpeaker

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              speaker.portraitTint.opacity(0.95),
              Color(red: 0.15, green: 0.17, blue: 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.18), lineWidth: 1)

      Text(speaker.portraitGlyph)
        .font(.system(size: 34, weight: .bold, design: .serif))
        .foregroundStyle(Color.white.opacity(0.96))
        .rotationEffect(.degrees(speaker.portraitRotation))
        .rotation3DEffect(.degrees(-18), axis: (x: 0, y: 1, z: 0))
        .offset(x: 1, y: -1)
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 5)
    }
    .frame(width: 66, height: 66)
  }
}

private struct ARChessRootView: View {
  @State private var screen: NativeScreen = .modeSelection
  @StateObject private var queueMatch = QueueMatchStore()
  @State private var completedLessonIDs: Set<String> = []
  @State private var selectedNarrator: NarratorType = .silky

  var body: some View {
    ZStack {
      switch screen {
      case .modeSelection:
        ModeSelectionView(selectedNarrator: $selectedNarrator) { mode in
          withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            switch mode {
            case .course:
              screen = .course
            case .passAndPlay:
              screen = .landing
            case .queueMatch:
              screen = .queueMatch
            case .playVsStockfish:
              screen = .stockfishSetup
            }
          }
        }
      case .course:
        CourseLibraryView(
          completedLessonIDs: completedLessonIDs,
          openLesson: { lesson in
            beginExperienceLaunch(.lesson(lesson))
          },
          goBack: {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .modeSelection
            }
          }
        )
      case .stockfishSetup:
        StockfishSetupView(
          openExperience: { configuration in
            beginExperienceLaunch(.playVsStockfish(configuration))
          },
          goBack: {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .modeSelection
            }
          }
        )
      case .landing:
        LandingView { mode in
          withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            screen = .lobby(mode)
          }
        }
      case .lobby(let mode):
        LobbyView(
          mode: mode,
          openExperience: {
            beginExperienceLaunch(.passAndPlay(mode))
          },
          goBack: {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .modeSelection
            }
          }
        )
      case .queueMatch:
        QueueMatchView(
          queueMatch: queueMatch,
          openExperience: {
            beginExperienceLaunch(.queueMatch)
          },
          goBack: {
            Task {
              await queueMatch.exitQueueFlow()
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .modeSelection
            }
          }
        )
      case .experienceLoading(let mode):
        ExperienceLoadingView(
          mode: mode,
          narrator: selectedNarrator,
          openExperience: {
            finishExperienceLaunch(mode)
          },
          cancel: {
            cancelExperienceLaunch(mode)
          }
        )
      case .experience(let mode):
        NativeARExperienceView(
          mode: mode,
          narrator: selectedNarrator,
          queueMatch: queueMatch,
          closeExperience: {
            switch mode {
            case .lesson:
              withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                screen = .course
              }
            case .passAndPlay(let playerMode):
              withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                screen = .lobby(playerMode)
              }
            case .queueMatch:
              Task {
                await queueMatch.exitQueueFlow()
              }
              withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                screen = .queueMatch
              }
            case .playVsStockfish:
              withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                screen = .stockfishSetup
              }
            }
          },
          returnHome: {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              switch mode {
              case .lesson:
                screen = .course
              case .queueMatch:
                screen = .modeSelection
              case .passAndPlay, .playVsStockfish:
                screen = .modeSelection
              }
            }
            if case .queueMatch = mode {
              Task {
                await queueMatch.exitQueueFlow()
              }
            }
          },
          markLessonComplete: { lessonID in
            completedLessonIDs.insert(lessonID)
          }
        )
      }
    }
  }

  private func beginExperienceLaunch(_ mode: ExperienceMode) {
    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
      screen = .experienceLoading(mode)
    }
  }

  private func finishExperienceLaunch(_ mode: ExperienceMode) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      screen = .experience(mode)
    }
  }

  private func cancelExperienceLaunch(_ mode: ExperienceMode) {
    withAnimation(.spring(response: 0.38, dampingFraction: 0.90)) {
      switch mode {
      case .lesson:
        screen = .course
      case .passAndPlay(let playerMode):
        screen = .lobby(playerMode)
      case .queueMatch:
        screen = .queueMatch
      case .playVsStockfish:
        screen = .stockfishSetup
      }
    }
  }
}

private struct ExperienceLoadingView: View {
  let mode: ExperienceMode
  let narrator: NarratorType
  let openExperience: () -> Void
  let cancel: () -> Void

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      LinearGradient(
        colors: [
          Color.black.opacity(0.36),
          Color(red: 0.04, green: 0.07, blue: 0.10).opacity(0.90),
          Color.black.opacity(0.86),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 22) {
        Spacer()

        VStack(alignment: .leading, spacing: 16) {
          Text("AR Boot")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(Color(red: 0.84, green: 0.78, blue: 0.66))

          Text(mode.loadingTitle)
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text(mode.loadingSummary)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
            .lineSpacing(4)

          HStack(spacing: 12) {
            ProgressView()
              .tint(Color.white.opacity(0.94))

            Text("Narrator: \(narrator.displayName)")
              .font(.system(size: 14, weight: .bold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.92))
          }

          VStack(alignment: .leading, spacing: 10) {
            loadingStep("Starting camera pipeline")
            loadingStep("Staging board assets")
            loadingStep("Holding heavy sync until after entry")
          }
          .padding(.top, 2)

          NativeActionButton(title: "Back", style: .outline) {
            cancel()
          }
          .padding(.top, 6)
        }
        .padding(24)
        .background(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.90))
            .overlay(
              RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
    }
    .task(id: mode) {
      try? await Task.sleep(nanoseconds: experienceLaunchDelayNanoseconds)
      guard !Task.isCancelled else {
        return
      }
      openExperience()
    }
  }

  private func loadingStep(_ text: String) -> some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Color(red: 0.93, green: 0.84, blue: 0.62))
        .frame(width: 8, height: 8)

      Text(text)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.78))
    }
  }
}

private struct ModeSelectionView: View {
  @Binding var selectedNarrator: NarratorType
  let onSelect: (PlayModeChoice) -> Void
  @State private var isPiperAuditionPresented = false

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      LinearGradient(
        colors: [
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.18),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.74),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.95),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 26) {
        Spacer()

        VStack(spacing: 12) {
          Text("Native iOS")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(Color(red: 0.85, green: 0.78, blue: 0.64))

          WarChessTitle()

          Text("Choose Course, pass-and-play, a full game versus Stockfish, or a synced queue match.")
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }

        NarratorSelectionCard(selectedNarrator: $selectedNarrator)
          .frame(maxWidth: 340)

        NativeActionButton(title: "Piper Voice Lab", style: .outline) {
          isPiperAuditionPresented = true
        }
        .frame(maxWidth: 340)

        VStack(spacing: 14) {
          NativeActionButton(title: "Course", style: .solid) {
            onSelect(.course)
          }

          NativeActionButton(title: "Pass & Play", style: .solid) {
            onSelect(.passAndPlay)
          }

          NativeActionButton(title: "Play vs Stockfish", style: .outline) {
            onSelect(.playVsStockfish)
          }

          NativeActionButton(title: "Queue Match", style: .outline) {
            onSelect(.queueMatch)
          }
        }
        .frame(maxWidth: 340)

        Text("Post-game review runs after Queue Match and full Play vs Stockfish games only. Course opens the mock lesson catalog.")
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.72))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
    }
    .sheet(isPresented: $isPiperAuditionPresented) {
      PiperVoiceAuditionView()
        .piperVoiceLabSheetPresentation()
    }
  }
}

private extension View {
  @ViewBuilder
  func piperVoiceLabSheetPresentation() -> some View {
    if #available(iOS 16.0, *) {
      self
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    } else {
      self
    }
  }
}

private struct PiperVoiceAuditionView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = PiperVoiceAuditionStore()

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      LinearGradient(
        colors: [
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.16),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.82),
          Color.black.opacity(0.96),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 18) {
          header

          auditionCard {
            VStack(alignment: .leading, spacing: 10) {
              Text("Status")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))

              Text(store.statusText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(2)

              HStack(spacing: 10) {
                statusPill(
                  title: store.hasConfiguredAPIBaseURL ? "Backend ready" : "Backend missing",
                  accent: store.hasConfiguredAPIBaseURL
                    ? Color(red: 0.64, green: 0.90, blue: 0.74)
                    : Color(red: 0.96, green: 0.72, blue: 0.68)
                )
                statusPill(
                  title: store.isPreviewing ? "Previewing" : "Idle",
                  accent: store.isPreviewing
                    ? Color(red: 0.82, green: 0.90, blue: 0.98)
                    : Color.white.opacity(0.66)
                )
              }
            }
          }

          auditionCard {
            VStack(alignment: .leading, spacing: 12) {
              Text("Voice Navigator")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

              if let selectedVoice = store.selectedVoice {
                Text(selectedVoice.displayName)
                  .font(.system(size: 26, weight: .heavy, design: .rounded))
                  .foregroundStyle(.white)

                Text(selectedVoice.voice_id)
                  .font(.system(size: 11, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.white.opacity(0.66))
                  .textSelection(.enabled)

                if !selectedVoice.metadataLine.isEmpty {
                  Text(selectedVoice.metadataLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.82, green: 0.90, blue: 0.98))
                }

                if !selectedVoice.configured_speaker_types.isEmpty {
                  Text("Assigned now: \(selectedVoice.configured_speaker_types.map(\.capitalized).joined(separator: ", "))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                }

                HStack(spacing: 10) {
                  compactActionButton(title: "Previous", systemImage: "chevron.left") {
                    store.selectPreviousVoice()
                  }

                  compactActionButton(
                    title: store.isPreviewing ? "Playing" : "Preview sample",
                    systemImage: "speaker.wave.2.fill",
                    isDisabled: store.selectedVoice == nil || store.isLoadingVoices
                  ) {
                    store.previewSelectedSample()
                  }

                  compactActionButton(title: "Next", systemImage: "chevron.right") {
                    store.selectNextVoice()
                  }
                }

                Toggle("Auto preview on voice switch", isOn: $store.autoPreviewOnVoiceChange)
                  .tint(Color(red: 0.95, green: 0.88, blue: 0.73))
                  .foregroundStyle(Color.white.opacity(0.82))
              } else {
                Text("No installed Piper voices found yet.")
                  .font(.system(size: 14, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.76))
              }
            }
          }

          auditionCard {
            VStack(alignment: .leading, spacing: 12) {
              Text("Installed Voices")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

              if store.voices.isEmpty {
                Text("The current backend did not report any installed Piper models.")
                  .font(.system(size: 14, weight: .medium, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.72))
              } else {
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 12) {
                    ForEach(store.voices) { voice in
                      Button {
                        store.selectVoice(voice.voice_id, autoplay: true)
                      } label: {
                        VStack(alignment: .leading, spacing: 8) {
                          Text(voice.displayName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                          if !voice.metadataLine.isEmpty {
                            Text(voice.metadataLine)
                              .font(.system(size: 12, weight: .semibold, design: .rounded))
                              .foregroundStyle(Color(red: 0.84, green: 0.90, blue: 0.98))
                              .lineLimit(1)
                          }

                          Text(voice.voice_id)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(2)

                          if !voice.configured_speaker_types.isEmpty {
                            Text("Assigned: \(voice.configured_speaker_types.map(\.capitalized).joined(separator: ", "))")
                              .font(.system(size: 11, weight: .medium, design: .rounded))
                              .foregroundStyle(Color.white.opacity(0.72))
                              .lineLimit(2)
                          }
                        }
                        .frame(width: 230, alignment: .leading)
                        .padding(14)
                        .background(
                          RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                              store.selectedVoiceID == voice.voice_id
                                ? Color(red: 0.20, green: 0.28, blue: 0.36).opacity(0.96)
                                : Color.white.opacity(0.05)
                            )
                            .overlay(
                              RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(
                                  store.selectedVoiceID == voice.voice_id
                                    ? Color(red: 0.95, green: 0.88, blue: 0.73)
                                    : Color.white.opacity(0.10),
                                  lineWidth: 1
                                )
                            )
                        )
                      }
                      .buttonStyle(.plain)
                    }
                  }
                  .padding(.vertical, 2)
                }
              }
            }
          }

          auditionCard {
            VStack(alignment: .leading, spacing: 12) {
              Text("Sample Lines")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

              Text("Keep one sample selected, then move across voices with Previous/Next for fast A/B testing.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(2)

              ForEach(Array(PiperVoiceAuditionStore.builtInSamples.enumerated()), id: \.offset) { index, line in
                Button {
                  store.selectedSampleIndex = index
                  store.previewSelectedSample()
                } label: {
                  HStack(alignment: .top, spacing: 10) {
                    Image(systemName: store.selectedSampleIndex == index ? "speaker.wave.3.fill" : "text.quote")
                      .font(.system(size: 14, weight: .bold))
                      .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))
                      .frame(width: 20, height: 20)

                    Text(line)
                      .font(.system(size: 14, weight: .semibold, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.90))
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .multilineTextAlignment(.leading)
                      .lineSpacing(2)
                  }
                  .padding(14)
                  .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                      .fill(
                        store.selectedSampleIndex == index
                          ? Color(red: 0.18, green: 0.24, blue: 0.32).opacity(0.96)
                          : Color.white.opacity(0.04)
                      )
                      .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                          .stroke(Color.white.opacity(store.selectedSampleIndex == index ? 0.18 : 0.08), lineWidth: 1)
                      )
                  )
                }
                .buttonStyle(.plain)
              }
            }
          }

          auditionCard {
            VStack(alignment: .leading, spacing: 12) {
              Text("Custom Line")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

              TextField("Type a short custom line", text: $store.customText)
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(false)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                  RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                      RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                )

              HStack {
                Text("\(store.trimmedCustomText.count)/200")
                  .font(.system(size: 11, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.white.opacity(0.62))

                Spacer(minLength: 8)

                compactActionButton(
                  title: "Preview custom",
                  systemImage: "waveform.and.mic",
                  isDisabled: store.trimmedCustomText.isEmpty
                ) {
                  store.previewCustomText()
                }
              }
            }
          }

          auditionCard {
            VStack(alignment: .leading, spacing: 12) {
              Text("Character Assignments")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

              Text("These assignment actions update the current backend Piper config so live piece commentary uses the chosen voice next time it speaks. Narrator stays on Gemini Live.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(2)

              ForEach(PiperSpeakerType.allCases) { speakerType in
                HStack(alignment: .center, spacing: 12) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(speakerType.displayName)
                      .font(.system(size: 14, weight: .bold, design: .rounded))
                      .foregroundStyle(.white)

                    Text(store.assignmentLabel(for: speakerType))
                      .font(.system(size: 12, weight: .medium, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.70))
                      .lineLimit(2)
                  }

                  Spacer(minLength: 8)

                  compactActionButton(
                    title: speakerType.usesGeminiLiveNarrator ? "Gemini Live" : "Use selected",
                    systemImage: "checkmark",
                    isDisabled: speakerType.usesGeminiLiveNarrator || store.selectedVoice == nil || store.isAssigning
                  ) {
                    Task {
                      await store.assignSelectedVoice(to: speakerType)
                    }
                  }
                  .frame(width: 140)
                }
                .padding(.vertical, 4)
              }
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
      }
    }
    .task {
      await store.loadIfNeeded()
    }
    .onDisappear {
      store.stop()
    }
    .onChange(of: store.customText) { newValue in
      if newValue.count > 200 {
        store.customText = String(newValue.prefix(200))
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Voice Lab")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(2.0)
          .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))

        Text("Piper Voice Audition")
          .font(.system(size: 32, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)

        Text("Listen to installed voices on game-flavored lines, compare them quickly, and assign the best fit to each chess character.")
          .font(.system(size: 15, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.82))
          .lineSpacing(3)
      }

      Spacer(minLength: 12)

      VStack(spacing: 10) {
        compactActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
          Task {
            await store.refreshVoices(keeping: store.selectedVoiceID)
          }
        }

        compactActionButton(title: "Done", systemImage: "xmark") {
          dismiss()
        }
      }
      .frame(width: 126)
    }
  }

  private func auditionCard<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      content()
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.90))
        .overlay(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    )
  }

  private func statusPill(title: String, accent: Color) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .bold, design: .rounded))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .foregroundStyle(accent)
      .background(
        Capsule(style: .continuous)
          .fill(accent.opacity(0.12))
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(accent.opacity(0.20), lineWidth: 1)
      )
  }

  private func compactActionButton(
    title: String,
    systemImage: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .bold))
        Text(title)
          .font(.system(size: 13, weight: .bold, design: .rounded))
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .foregroundStyle(Color.white.opacity(isDisabled ? 0.58 : 0.92))
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.white.opacity(isDisabled ? 0.04 : 0.08))
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(Color.white.opacity(isDisabled ? 0.06 : 0.12), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
  }
}

private struct NarratorSelectionCard: View {
  @Binding var selectedNarrator: NarratorType

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Narrator")
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .tracking(1.8)
        .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))

      Picker("Narrator", selection: $selectedNarrator) {
        ForEach(NarratorType.allCases) { narrator in
          Text(narrator.displayName).tag(narrator)
        }
      }
      .pickerStyle(.segmented)

      Text(selectedNarrator.summary)
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.76))
        .lineSpacing(2)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.88))
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    )
  }
}

private struct CourseLibraryView: View {
  let completedLessonIDs: Set<String>
  let openLesson: (OpeningLessonDefinition) -> Void
  let goBack: () -> Void
  @State private var selectedPage = 0
  @State private var unavailableCourseTitle = ""
  @State private var isUnavailableCourseAlertPresented = false

  private let pages = CourseCatalogEntry.mockPages

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      LinearGradient(
        colors: [
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.26),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.78),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.96),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Lessons")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(Color(red: 0.84, green: 0.78, blue: 0.66))

          Text("Opening Lessons")
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text("Swipe between pages. The Italian Opening lesson is live; the other boxes are mock entries for the current catalog layout.")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.80))
            .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)

        TabView(selection: $selectedPage) {
          ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
            CoursePageGrid(
              courses: page,
              pageIndex: index,
              pageCount: pages.count,
              completedLessonIDs: completedLessonIDs,
              openLesson: openLesson,
              showUnavailableCourse: { course in
                unavailableCourseTitle = course.title
                isUnavailableCourseAlertPresented = true
              }
            )
            .tag(index)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))

        NativeActionButton(title: "Back", style: .outline) {
          goBack()
        }
        .padding(.bottom, 26)
      }
      .padding(.horizontal, 20)
    }
    .alert(isPresented: $isUnavailableCourseAlertPresented) {
      Alert(
        title: Text(unavailableCourseTitle),
        message: Text("This lesson card is still a mock entry. Only Learn the Italian Opening is interactive right now."),
        dismissButton: .default(Text("OK"))
      )
    }
  }
}

private struct CoursePageGrid: View {
  let courses: [CourseCatalogEntry]
  let pageIndex: Int
  let pageCount: Int
  let completedLessonIDs: Set<String>
  let openLesson: (OpeningLessonDefinition) -> Void
  let showUnavailableCourse: (CourseCatalogEntry) -> Void

  private let columnCount = 9
  private let gridSpacing: CGFloat = 4

  var body: some View {
    GeometryReader { geometry in
      let horizontalPadding: CGFloat = 18
      let cellSide = max(
        28,
        floor((geometry.size.width - (horizontalPadding * 2) - (gridSpacing * CGFloat(columnCount - 1))) / CGFloat(columnCount))
      )
      let columns = Array(repeating: GridItem(.fixed(cellSide), spacing: gridSpacing), count: columnCount)

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Page \(pageIndex + 1) of \(pageCount)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))

          Spacer(minLength: 12)

          Text("\(courses.count) courses")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
        }

        LazyVGrid(columns: columns, spacing: gridSpacing) {
          ForEach(courses) { course in
            Button {
              handleSelection(for: course)
            } label: {
              CourseBoxView(
                course: course,
                isCompleted: course.lessonID.map(completedLessonIDs.contains) ?? false
              )
              .frame(width: cellSide, height: cellSide)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, 18)
      .background(
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.90))
          .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .stroke(Color.white.opacity(0.12), lineWidth: 1)
          )
      )
      .padding(.bottom, 16)
    }
  }

  private func handleSelection(for course: CourseCatalogEntry) {
    switch course.kind {
    case .italianOpening:
      openLesson(.italianOpening)
    case .mock:
      showUnavailableCourse(course)
    }
  }
}

private struct CourseBoxView: View {
  let course: CourseCatalogEntry
  let isCompleted: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(
        LinearGradient(
          colors: [
            course.kind == .italianOpening
              ? Color(red: 0.24, green: 0.20, blue: 0.10)
              : Color(red: 0.14, green: 0.20, blue: 0.28),
            course.kind == .italianOpening
              ? Color(red: 0.12, green: 0.10, blue: 0.05)
              : Color(red: 0.08, green: 0.11, blue: 0.16),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isCompleted
              ? Color(red: 0.57, green: 0.90, blue: 0.68)
              : (course.kind == .italianOpening
                ? Color(red: 0.95, green: 0.88, blue: 0.73).opacity(0.72)
                : Color.white.opacity(0.14)),
            lineWidth: 1
          )
      )
      .overlay {
        Text(course.title)
          .font(.system(size: 7, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .lineLimit(4)
          .minimumScaleFactor(0.58)
          .padding(4)
      }
      .overlay(alignment: .topTrailing) {
        if isCompleted {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(red: 0.57, green: 0.90, blue: 0.68))
            .padding(4)
        }
      }
  }
}

private struct StockfishSetupView: View {
  let openExperience: (StockfishMatchConfiguration) -> Void
  let goBack: () -> Void

  @State private var devCheckFEN = ""
  @State private var devCheckError: String?

  private let exampleFEN = "2r4k/p3q1pp/3p1p2/1R1Pp3/n3P3/5P2/P1rBQ1PP/5RK1 w"

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      Color.black.opacity(0.60).ignoresSafeArea()

      ScrollView(showsIndicators: false) {
        VStack(spacing: 22) {
          Spacer(minLength: 44)

          VStack(alignment: .leading, spacing: 16) {
            Text("Play vs Stockfish")
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .tracking(2.0)
              .foregroundStyle(Color(red: 0.84, green: 0.78, blue: 0.66))

            Text("Stockfish Setup")
              .font(.system(size: 34, weight: .heavy, design: .rounded))
              .foregroundStyle(.white)

            Text("Start a full match with a coin-tossed color, or use devCheck to jump into a custom FEN.")
              .font(.system(size: 16, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.82))
              .lineSpacing(3)

            VStack(alignment: .leading, spacing: 10) {
              Text("Full match")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

              Text("Coin toss assigns White or Black. Full matches keep normal post-game review.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineSpacing(2)

              NativeActionButton(title: "Start Match", style: .solid) {
                openExperience(.coinToss())
              }
            }

            Rectangle()
              .fill(Color.white.opacity(0.10))
              .frame(height: 1)
              .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
              Text("devCheck")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

              Text("Paste a FEN. The side to move in that FEN becomes the human side for this session.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineSpacing(2)

              ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                  .fill(Color.white.opacity(0.06))
                  .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                      .stroke(Color.white.opacity(0.16), lineWidth: 1)
                  )

                if devCheckFEN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text(exampleFEN)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.34))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                if #available(iOS 16.0, *) {
                  TextEditor(text: $devCheckFEN)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                  TextEditor(text: $devCheckFEN)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .background(Color.clear)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
              }
              .frame(minHeight: 120)

              Text("Shorthand is fine here. Missing FEN fields default to: side `w`, castling `-`, en passant `-`, halfmove `0`, fullmove `1`.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73).opacity(0.88))
                .lineSpacing(2)

              if let devCheckError {
                Text(devCheckError)
                  .font(.system(size: 13, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color(red: 0.95, green: 0.66, blue: 0.62))
                  .lineSpacing(2)
              }

              NativeActionButton(title: "devCheck", style: .outline) {
                launchDevCheck()
              }
            }

            NativeActionButton(title: "Back", style: .outline) {
              goBack()
            }
          }
          .padding(24)
          .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
              .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.88))
              .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                  .stroke(Color.white.opacity(0.12), lineWidth: 1)
              )
          )

          Spacer(minLength: 44)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
      }
    }
  }

  private func launchDevCheck() {
    do {
      let validatedFEN = try StockfishDevCheckFENResolver.resolve(devCheckFEN)
      devCheckError = nil
      openExperience(.devCheck(fen: validatedFEN.fen, humanColor: validatedFEN.sideToMove))
    } catch {
      devCheckError = error.localizedDescription
    }
  }
}

private struct LandingView: View {
  let onSelect: (PlayerMode) -> Void

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      LinearGradient(
        colors: [
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.20),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.74),
          Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.95),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      Circle()
        .fill(Color(red: 0.86, green: 0.70, blue: 0.43).opacity(0.22))
        .frame(width: 280, height: 280)
        .blur(radius: 16)
        .offset(y: -210)

      VStack(spacing: 26) {
        Spacer()

        VStack(spacing: 12) {
          Text("Native iOS")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(Color(red: 0.85, green: 0.78, blue: 0.64))

          WarChessTitle()

          Text("Place boards in rooms • Play together")
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 290)
        }

        VStack(spacing: 14) {
          NativeActionButton(title: "Join", style: .solid) {
            onSelect(.join)
          }

          NativeActionButton(title: "Create", style: .outline) {
            onSelect(.create)
          }
        }
        .frame(maxWidth: 320)

        Text("SwiftUI shell • AR runs in the native app only")
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.72))
          .padding(.top, 4)

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
    }
  }
}

private struct WarChessTitle: View {
  var body: some View {
    (
      Text("W")
        .foregroundColor(.white)
      + Text("AR")
        .foregroundColor(Color(red: 0.89, green: 0.54, blue: 0.32))
      + Text(" CHESS")
        .foregroundColor(.white)
    )
    .font(.system(size: 50, weight: .heavy, design: .rounded))
  }
}

private struct LobbyView: View {
  let mode: PlayerMode
  let openExperience: () -> Void
  let goBack: () -> Void

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      Color.black.opacity(0.60).ignoresSafeArea()

      VStack(spacing: 22) {
        Spacer()

        VStack(alignment: .leading, spacing: 14) {
          Text(mode.heading)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(Color(red: 0.84, green: 0.78, blue: 0.66))

          Text("Lobby / Loading")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text("AR experience opens next (TODO)")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)

          Text(mode.lobbySummary)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.80))
            .lineSpacing(3)

          VStack(spacing: 12) {
            NativeActionButton(title: "Open Native AR", style: .solid) {
              openExperience()
            }

            NativeActionButton(title: "Back", style: .outline) {
              goBack()
            }
          }
          .padding(.top, 4)
        }
        .padding(24)
        .background(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.88))
            .overlay(
              RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
    }
  }
}

private struct QueueMatchView: View {
  @ObservedObject var queueMatch: QueueMatchStore
  let openExperience: () -> Void
  let goBack: () -> Void

  var body: some View {
    ZStack {
      ChessboardBackdrop()
      Color.black.opacity(0.60).ignoresSafeArea()

      VStack(spacing: 22) {
        Spacer()

        VStack(alignment: .leading, spacing: 14) {
          Text("Queue Match")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(Color(red: 0.84, green: 0.78, blue: 0.66))

          Text("Matchmaking")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text(queueHeadline)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)

          Text(queueMatch.statusText)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.80))
            .lineSpacing(3)

          Text("Device player ID: \(queueMatch.playerIDLabel)")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.62))
            .textSelection(.enabled)

          if let matchID = queueMatch.matchID {
            Text("Match ID: \(matchID)")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.62))
              .textSelection(.enabled)
          }

          if let assignedColor = queueMatch.assignedColor {
            Text("Assigned color: \(assignedColor.displayName)")
              .font(.system(size: 15, weight: .bold, design: .rounded))
              .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))
          }

          VStack(spacing: 12) {
            if queueMatch.state == .idle || queueMatch.state == .cancelled || queueMatch.state == .syncError {
              NativeActionButton(title: "Join Queue", style: .solid) {
                Task {
                  await queueMatch.joinQueue()
                }
              }
            }

            if queueMatch.state == .waiting || queueMatch.state == .reconnecting {
              NativeActionButton(title: "Cancel Queue", style: .outline) {
                Task {
                  await queueMatch.cancelQueue()
                }
              }
            }

            if queueMatch.canOpenExperience {
              NativeActionButton(title: "Open Native AR", style: .solid) {
                openExperience()
              }
            }

            NativeActionButton(title: "Back", style: .outline) {
              goBack()
            }
          }
          .padding(.top, 4)
        }
        .padding(24)
        .background(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.88))
            .overlay(
              RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
    }
  }

  private var queueHeadline: String {
    switch queueMatch.state {
    case .idle:
      return "Ready to join"
    case .waiting:
      return "Waiting for opponent"
    case .matched:
      return "Matched"
    case .reconnecting:
      return "Reconnecting"
    case .syncError:
      return "Sync error"
    case .cancelled:
      return "Cancelled"
    }
  }
}

@MainActor
private final class FishingInteractionStore: ObservableObject {
  enum State: String {
    case idle
    case eligible
    case casting
    case waiting
    case bite
    case catchWindow
    case caught
    case revealNote
    case reset
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var isPondInFocus = false
  @Published private(set) var statusText = "Look toward the pond beside the board."
  @Published private(set) var rewardMoves: [String] = []

  private var castHandler: (() -> Void)?
  private var dismissNoteHandler: (() -> Void)?
  private var armedRewardMoves: [String] = []

  var showsFishingButton: Bool {
    isPondInFocus && state == .eligible
  }

  var showsFirstPersonRig: Bool {
    switch state {
    case .idle, .revealNote, .reset:
      return false
    case .eligible, .casting, .waiting, .bite, .catchWindow, .caught:
      return isPondInFocus || state != .eligible
    }
  }

  var showsFishingStatus: Bool {
    switch state {
    case .idle, .eligible:
      return false
    case .casting, .waiting, .bite, .catchWindow, .caught, .revealNote, .reset:
      return true
    }
  }

  var showsRewardNote: Bool {
    state == .revealNote
  }

  var canRevealRewardFromFish: Bool {
    state == .caught && !armedRewardMoves.isEmpty
  }

  var canAcceptCatchFlick: Bool {
    switch state {
    case .bite, .catchWindow:
      return true
    case .idle, .eligible, .casting, .waiting, .caught, .revealNote, .reset:
      return false
    }
  }

  func bindCastHandler(_ handler: @escaping () -> Void) {
    castHandler = handler
  }

  func bindDismissNoteHandler(_ handler: @escaping () -> Void) {
    dismissNoteHandler = handler
  }

  func updatePondFocus(_ isFocused: Bool) {
    guard isPondInFocus != isFocused else {
      return
    }

    isPondInFocus = isFocused
    switch state {
    case .idle:
      if isFocused {
        transition(to: .eligible, status: "Cast toward the pond.")
      }
    case .eligible:
      if !isFocused {
        transition(to: .idle, status: "Look toward the pond beside the board.")
      }
    case .casting, .waiting, .bite, .catchWindow, .caught, .revealNote, .reset:
      break
    }
  }

  func requestCast() {
    guard state == .eligible else {
      return
    }

    transition(to: .casting, status: "Casting into the pond...")
    castHandler?()
  }

  func setWaiting() {
    transition(to: .waiting, status: "Waiting for a bite...")
  }

  func setBite() {
    transition(to: .bite, status: "Fish on. Flick upward now.")
  }

  func setCatchWindow() {
    transition(to: .catchWindow, status: "Hook it. Flick upward.")
  }

  func setCaught() {
    transition(to: .caught, status: "Reeling in the catch...")
  }

  func armRewardFromCaughtFish(lines: [String]) {
    armedRewardMoves = lines
    transition(to: .caught, status: "Tap the fish to read the note.")
  }

  func revealRewardNote(lines: [String]) {
    rewardMoves = lines
    transition(to: .revealNote, status: "Stockfish sent a note back with the fish.")
  }

  func revealArmedRewardNote() {
    guard !armedRewardMoves.isEmpty else {
      return
    }

    rewardMoves = armedRewardMoves
    transition(to: .revealNote, status: "Stockfish sent a note back with the fish.")
  }

  func setResetStatus(_ message: String) {
    transition(to: .reset, status: message)
  }

  func finishReset() {
    rewardMoves = []
    armedRewardMoves = []
    transition(
      to: isPondInFocus ? .eligible : .idle,
      status: isPondInFocus ? "Cast toward the pond." : "Look toward the pond beside the board."
    )
  }

  func dismissRewardNote() {
    dismissNoteHandler?()
  }

  private func transition(to nextState: State, status: String) {
    guard state != nextState || statusText != status else {
      return
    }

    state = nextState
    statusText = status
  }
}

@MainActor
private final class PieceRoleStore: ObservableObject {
  @Published private(set) var snapshot = PieceRoleSnapshot.empty(currentPlayer: .white)

  private var highlightEmployeeHandler: (() -> Void)?

  var employeeOfTheMonth: PieceRoleAssignment? {
    snapshot.employeeOfTheMonth
  }

  var employeePosterTitle: String? {
    guard let employee = employeeOfTheMonth else {
      return nil
    }

    return "Wanted: \(employee.piece.kind.displayName) \(employee.square.algebraic.uppercased())"
  }

  var employeePosterSubtitle: String? {
    guard let employee = employeeOfTheMonth else {
      return nil
    }

    let score = Double(employee.employeeThreatScoreHalfPoints) / 2.0
    let kingZoneText = employee.attacksKingZone ? " • king ring" : ""
    return String(
      format: "Score %.1f • %d piece targets • %d home-half%@",
      score,
      employee.attackedFriendlyPieceCount,
      employee.influenceCount,
      kingZoneText
    )
  }

  func update(snapshot: PieceRoleSnapshot) {
    self.snapshot = snapshot
  }

  func reset() {
    snapshot = PieceRoleSnapshot.empty(currentPlayer: .white)
    highlightEmployeeHandler = nil
  }

  func bindEmployeeHighlightHandler(_ handler: @escaping () -> Void) {
    highlightEmployeeHandler = handler
  }

  func unbindEmployeeHighlightHandler() {
    highlightEmployeeHandler = nil
  }

  func requestEmployeeHighlight() {
    highlightEmployeeHandler?()
  }
}

private final class UpwardFlickDetector {
  var onUpwardFlick: (() -> Void)?

  private let motionManager = CMMotionManager()
  private let motionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "archess.fishing.motion"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private var lastFlickTime: CFTimeInterval = 0

  func start() {
    guard motionManager.isDeviceMotionAvailable else {
      return
    }

    guard !motionManager.isDeviceMotionActive else {
      return
    }

    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
      self?.handleMotionUpdate(motion)
    }
  }

  func stop() {
    motionManager.stopDeviceMotionUpdates()
  }

  private func handleMotionUpdate(_ motion: CMDeviceMotion?) {
    guard let motion else {
      return
    }

    let gravity = SIMD3<Double>(motion.gravity.x, motion.gravity.y, motion.gravity.z)
    let gravityLength = simd_length(gravity)
    guard gravityLength > 0.001 else {
      return
    }

    // Project user acceleration against world-up so the flick works even while the phone is tilted.
    let worldUp = -gravity / gravityLength
    let userAcceleration = SIMD3<Double>(
      motion.userAcceleration.x,
      motion.userAcceleration.y,
      motion.userAcceleration.z
    )
    let upwardAcceleration = simd_dot(userAcceleration, worldUp)
    let pitchRate = abs(motion.rotationRate.x)
    let now = CACurrentMediaTime()

    guard upwardAcceleration > 0.82,
          pitchRate > 1.85,
          (now - lastFlickTime) > 0.85 else {
      return
    }

    lastFlickTime = now
    DispatchQueue.main.async { [weak self] in
      self?.onUpwardFlick?()
    }
  }
}

private struct NativeARExperienceView: View {
  let mode: ExperienceMode
  let narrator: NarratorType
  @ObservedObject var queueMatch: QueueMatchStore
  let closeExperience: () -> Void
  let returnHome: () -> Void
  let markLessonComplete: (String) -> Void
  @StateObject private var matchLog = MatchLogStore()
  @StateObject private var commentary: PiecePersonalityDirector
  @StateObject private var gameReview = GameReviewStore()
  @StateObject private var lessonStore = OpeningLessonStore()
  @StateObject private var socraticCoach: SocraticCoachStore
  @StateObject private var fishing = FishingInteractionStore()
  @StateObject private var pieceRoles = PieceRoleStore()
  @State private var isModePanelVisible = false
  @State private var isMatchLogVisible = false
  @State private var isGeminiDebugVisible = false
  @State private var isVoiceStackVisible = false
  @State private var isStockfishDebugVisible = false
  @State private var isMusicMuted = AmbientMusicController.shared.isMuted
  @State private var notifiedCompletedLessonID: String?

  init(
    mode: ExperienceMode,
    narrator: NarratorType,
    queueMatch: QueueMatchStore,
    closeExperience: @escaping () -> Void,
    returnHome: @escaping () -> Void,
    markLessonComplete: @escaping (String) -> Void
  ) {
    self.mode = mode
    self.narrator = narrator
    _queueMatch = ObservedObject(wrappedValue: queueMatch)
    self.closeExperience = closeExperience
    self.returnHome = returnHome
    self.markLessonComplete = markLessonComplete
    _commentary = StateObject(wrappedValue: PiecePersonalityDirector(narrator: narrator))
    _socraticCoach = StateObject(wrappedValue: SocraticCoachStore(narrator: narrator))
  }

  var body: some View {
    ZStack {
      NativeARView(
        matchLog: matchLog,
        queueMatch: queueMatch,
        mode: mode,
        commentary: commentary,
        gameReview: gameReview,
        lessonStore: lessonStore,
        socraticCoach: socraticCoach,
        fishing: fishing,
        pieceRoles: pieceRoles,
        onReviewFinished: returnHome
      )
        .ignoresSafeArea()

      LinearGradient(
        colors: [
          Color.black.opacity(0.54),
          Color.clear,
          Color.black.opacity(0.72),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      if gameReview.phase == .idle && !isLessonMode {
        VStack(spacing: 16) {
          if isModePanelVisible {
            ScrollView(showsIndicators: true) {
              VStack(alignment: .leading, spacing: 10) {
                Text(modeTitle)
                  .font(.system(size: 12, weight: .bold, design: .rounded))
                  .tracking(2.0)
                  .foregroundStyle(Color(red: 0.87, green: 0.79, blue: 0.64))

                Text("Native AR Sandbox")
                  .font(.system(size: 30, weight: .heavy, design: .rounded))
                  .foregroundStyle(.white)

                Text("RealityKit and ARKit are running inside the iOS app. Tap a piece, then tap a highlighted square to move it. Legal moves log in UCI and sync to Railway when ARChessAPIBaseURL is configured.")
                  .font(.system(size: 15, weight: .medium, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.86))
                  .lineSpacing(3)

                Text(commentary.analysisStatus)
                  .font(.system(size: 12, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

                Text(commentary.hintStatusText)
                  .font(.system(size: 13, weight: .bold, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.92))

                Text(socraticCoach.statusText)
                  .font(.system(size: 12, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color(red: 0.78, green: 0.88, blue: 0.98))

                if let coachError = socraticCoach.lastError {
                  Text(coachError)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.96, green: 0.72, blue: 0.68))
                    .lineSpacing(2)
                }

                if commentary.isHintLoading {
                  HStack(spacing: 10) {
                    ProgressView()
                      .tint(Color.white.opacity(0.92))

                    Text("Loading hint...")
                      .font(.system(size: 12, weight: .semibold, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.78))
                  }
                }

                if let visibleHintText = commentary.visibleHintText {
                  Text(visibleHintText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.96, green: 0.92, blue: 0.82))
                    .lineSpacing(3)
                }

                HStack(spacing: 10) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(commentary.whiteEvalText)
                      .font(.system(size: 12, weight: .bold, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.94))

                    Text(commentary.blackEvalText)
                      .font(.system(size: 12, weight: .bold, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.88))

                    Text(commentary.analysisTimingText)
                      .font(.system(size: 11, weight: .semibold, design: .rounded))
                      .foregroundStyle(Color.white.opacity(0.66))
                  }

                  Spacer(minLength: 12)

                  VStack(spacing: 8) {
                    NativeActionButton(title: "Hint", style: .outline) {
                      commentary.revealHint()
                    }

                    NativeActionButton(
                      title: "Help",
                      style: .outline,
                      isDisabled: !socraticCoach.canRequestHelp,
                      showsSpinner: socraticCoach.isStreamingResponse
                    ) {
                      socraticCoach.requestStrategicBriefing()
                    }

                    NativeActionButton(title: "Analyze current position", style: .outline) {
                      Task {
                        await commentary.analyzeCurrentPosition()
                      }
                    }
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: overlayPanelMaxHeight(ratio: 0.36), alignment: .top)
            .background(
              RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
          }

          Spacer()

          if let caption = socraticCoach.caption ?? commentary.caption {
            PieceSpeechBubble(caption: caption)
            .allowsHitTesting(false)
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }

          if isGeminiDebugVisible {
            geminiDebugPanel
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }

          if isVoiceStackVisible {
            voiceStackPanel
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }

          if isStockfishDebugVisible {
            stockfishDebugPanel
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }

          if isMatchLogVisible {
            ScrollView(showsIndicators: true) {
              VStack(alignment: .leading, spacing: 10) {
                Text("Match log")
                  .font(.system(size: 12, weight: .bold, design: .rounded))
                  .tracking(1.8)
                  .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

                Text(activeSyncStatus)
                  .font(.system(size: 15, weight: .medium, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.86))

                Text(commentary.latestAssessment)
                  .font(.system(size: 13, weight: .semibold, design: .rounded))
                  .foregroundStyle(Color.white.opacity(0.70))

                if let remoteGameID = activeRemoteGameID {
                  Text("Game ID: \(remoteGameID)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .textSelection(.enabled)
                }

                if activeEntries.isEmpty {
                  Text("Make a legal move to start the UCI move log.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                } else {
                  ForEach(Array(activeEntries.suffix(6))) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                      Text(entry.label)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                      Spacer(minLength: 0)

                      Text(entry.statusLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(
                          entry.isSynced
                            ? Color(red: 0.57, green: 0.90, blue: 0.68)
                            : Color(red: 0.93, green: 0.78, blue: 0.54)
                        )
                    }
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: overlayPanelMaxHeight(ratio: 0.42), alignment: .top)
            .background(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.82))
                .overlay(
                  RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
      }

      if gameReview.phase == .idle {
        VStack {
          HStack(alignment: .top) {
            if !isLessonMode {
              HStack(spacing: 10) {
                overlayToggleButton(
                  title: isModePanelVisible ? "Hide Mode" : "Show Mode",
                  systemImage: "rectangle.topthird.inset.filled"
                ) {
                  withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isModePanelVisible.toggle()
                  }
                }

                overlayToggleButton(
                  title: isMatchLogVisible ? "Hide Log" : "Show Log",
                  systemImage: "text.append"
                ) {
                  withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isMatchLogVisible.toggle()
                  }
                }

                overlayToggleButton(
                  title: isGeminiDebugVisible ? "Hide Gemini Debug" : "Show Gemini Debug",
                  systemImage: "sparkles.rectangle.stack"
                ) {
                  let nextVisible = !isGeminiDebugVisible
                  withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isGeminiDebugVisible = nextVisible
                    if nextVisible {
                      isStockfishDebugVisible = false
                    }
                  }
                  syncStockfishDebugVisibility()
                }

                overlayToggleButton(
                  title: isVoiceStackVisible ? "Hide Voices" : "Show Voices",
                  systemImage: "text.quote"
                ) {
                  withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isVoiceStackVisible.toggle()
                  }
                }

                overlayToggleButton(
                  title: isStockfishDebugVisible ? "Hide Stockfish Debug" : "Show Stockfish Debug",
                  systemImage: "list.number"
                ) {
                  let nextVisible = !isStockfishDebugVisible
                  withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isStockfishDebugVisible = nextVisible
                    if nextVisible {
                      isGeminiDebugVisible = false
                    }
                  }
                  syncStockfishDebugVisibility()
                }

                musicToggleButton

                if socraticCoach.isVisibleInCurrentMode {
                  overlayToggleButton(
                    title: socraticCoach.micState.label,
                    systemImage: socraticCoach.micState.systemImageName,
                    foregroundColor: .white,
                    backgroundColor: socraticCoach.micState.accentColor
                  ) {
                    Task {
                      await socraticCoach.toggleMicrophone()
                    }
                  }
                }
              }

              Spacer(minLength: 16)

              overlayToggleButton(
                title: "Exit AR",
                systemImage: "xmark"
              ) {
                closeExperience()
              }
            } else if let lesson = lessonStore.activeLesson {
              Text(lesson.title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

              Spacer(minLength: 12)

              HStack(spacing: 8) {
                if socraticCoach.isVisibleInCurrentMode {
                  overlayToggleButton(
                    title: "Lesson Help",
                    systemImage: "questionmark.bubble.fill",
                    foregroundColor: socraticCoach.canRequestHelp ? .white : Color.white.opacity(0.56),
                    backgroundColor: socraticCoach.canRequestHelp
                      ? Color.black.opacity(0.54)
                      : Color.black.opacity(0.28)
                  ) {
                    socraticCoach.requestStrategicBriefing()
                  }

                  overlayToggleButton(
                    title: socraticCoach.micState.label,
                    systemImage: socraticCoach.micState.systemImageName,
                    foregroundColor: .white,
                    backgroundColor: socraticCoach.micState.accentColor
                  ) {
                    Task {
                      await socraticCoach.toggleMicrophone()
                    }
                  }
                }

                musicToggleButton

                ForEach(0..<3, id: \.self) { index in
                  lessonStrikeBadge(isUsed: index < lessonUsedStrikeCount)
                }
              }

              overlayToggleButton(
                title: "Exit AR",
                systemImage: "xmark"
              ) {
                closeExperience()
              }
            } else {
              Spacer(minLength: 0)

              overlayToggleButton(
                title: "Exit AR",
                systemImage: "xmark"
              ) {
                closeExperience()
              }
            }
          }
          .padding(.horizontal, 18)
          .padding(.top, 24)

          if let employeePosterTitle = pieceRoles.employeePosterTitle,
             let employeePosterSubtitle = pieceRoles.employeePosterSubtitle {
            HStack {
              wantedPosterButton(
                title: employeePosterTitle,
                subtitle: employeePosterSubtitle
              )

              Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
          }

          Spacer()
        }
      }

      if gameReview.phase == .idle {
        fishingPromptOverlay
      }

      if gameReview.isAwaitingEntryDecision {
        reviewDecisionOverlay
      } else if gameReview.isLoading {
        reviewLoadingOverlay
      } else if gameReview.isReviewMode {
        reviewCheckpointOverlay
      }

      if isLessonMode {
        lessonOverlay
      }

      if fishing.showsRewardNote {
        FishingRewardOverlay(
          rewardMoves: fishing.rewardMoves,
          onDismiss: { fishing.dismissRewardNote() }
        )
      }
    }
    .task {
      lessonStore.configure(for: mode)
      if mode.usesLocalMatchLog {
        // Remote move logs assume a standard game start, so custom-FEN devCheck
        // sessions keep their history on-device only.
        matchLog.configureRemoteSync(
          enabled: mode.allowsRemoteMatchLogSync,
          disabledReason: mode.matchLogStatusSummary
        )
      }

      socraticCoach.setEnabled(mode.supportsSocraticCoach && gameReview.phase == .idle)

      let shouldDelayRemoteStartup: Bool
      if case .queueMatch = mode {
        shouldDelayRemoteStartup = true
      } else {
        shouldDelayRemoteStartup = mode.allowsRemoteMatchLogSync
      }

      if shouldDelayRemoteStartup {
        try? await Task.sleep(nanoseconds: experienceStartupRemoteWorkDelayNanoseconds)
        guard !Task.isCancelled else {
          return
        }
      }

      if mode.usesLocalMatchLog, mode.allowsRemoteMatchLogSync {
        await matchLog.prepareRemoteGameIfNeeded()
      } else if case .queueMatch = mode {
        await queueMatch.activateMatchSync()
      }
    }
    .onChange(of: gameReview.phase) { phase in
      socraticCoach.setEnabled(mode.supportsSocraticCoach && phase == .idle)
      guard phase != .idle else {
        return
      }

      isModePanelVisible = false
      isMatchLogVisible = false
      isGeminiDebugVisible = false
      isVoiceStackVisible = false
      isStockfishDebugVisible = false
      syncStockfishDebugVisibility()
    }
    .onChange(of: lessonStore.phase) { phase in
      guard phase == .complete,
            let lessonID = lessonStore.activeLesson?.id,
            notifiedCompletedLessonID != lessonID else {
        return
      }

      notifiedCompletedLessonID = lessonID
      markLessonComplete(lessonID)
    }
    .onAppear {
      isMusicMuted = AmbientMusicController.shared.isMuted
    }
    .onDisappear {
      gameReview.resetSession()
      lessonStore.resetSession()
      notifiedCompletedLessonID = nil
      commentary.resetSession()
      commentary.unbindStateProvider()
      commentary.unbindHintAvailabilityProvider()
      commentary.unbindRecentHistoryProvider()
      commentary.unbindReactionHandler()
      commentary.unbindNarrationHighlightHandler()
      commentary.unbindPieceAudioBusyDurationProvider()
      commentary.unbindPassiveCommentarySuppressionProvider()
      socraticCoach.unbindThreatZoneHandler()
      socraticCoach.unbindMoveHandler()
      socraticCoach.unbindDirectVoiceCommandHandler()
      pieceRoles.reset()
      socraticCoach.disconnect()
      switch mode {
      case .lesson:
        break
      case .passAndPlay(_), .playVsStockfish:
        matchLog.resetSession()
      case .queueMatch:
        Task {
          await queueMatch.exitQueueFlow()
        }
      }
    }
  }

  private func overlayToggleButton(
    title: String,
    systemImage: String,
    foregroundColor: Color = .white,
    backgroundColor: Color = Color.black.opacity(0.54),
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(foregroundColor)
        .frame(width: 42, height: 42)
        .background(
          Circle()
            .fill(backgroundColor)
            .overlay(
              Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
        )
    }
    .accessibilityLabel(title)
  }

  private func wantedPosterButton(title: String, subtitle: String) -> some View {
    Button {
      pieceRoles.requestEmployeeHighlight()
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "star.circle.fill")
            .font(.system(size: 16, weight: .black))
            .foregroundStyle(Color(red: 0.33, green: 0.12, blue: 0.07))

          Text("WANTED")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .tracking(2.1)
            .foregroundStyle(Color(red: 0.33, green: 0.12, blue: 0.07))
        }

        Text(title)
          .font(.system(size: 15, weight: .heavy, design: .rounded))
          .foregroundStyle(Color(red: 0.20, green: 0.08, blue: 0.04))
          .multilineTextAlignment(.leading)
          .lineLimit(2)

        Text(subtitle)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(Color(red: 0.29, green: 0.16, blue: 0.10).opacity(0.86))
          .lineLimit(2)
      }
      .frame(maxWidth: 220, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Color(red: 0.92, green: 0.79, blue: 0.58).opacity(0.96))
          .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .stroke(Color(red: 0.44, green: 0.23, blue: 0.12).opacity(0.38), lineWidth: 1)
          )
      )
    }
    .accessibilityLabel("Wanted poster for \(title)")
  }

  private var musicToggleButton: some View {
    overlayToggleButton(
      title: isMusicMuted ? "Unmute Music" : "Mute Music",
      systemImage: isMusicMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
      foregroundColor: .white,
      backgroundColor: isMusicMuted
        ? Color(red: 0.38, green: 0.18, blue: 0.18).opacity(0.88)
        : Color.black.opacity(0.54)
    ) {
      let nextMuted = !isMusicMuted
      AmbientMusicController.shared.setMuted(nextMuted)
      isMusicMuted = nextMuted
    }
  }

  private var reviewLoadingOverlay: some View {
    ZStack {
      Color.black.opacity(0.72)
        .ignoresSafeArea()

      VStack {
        HStack {
          Spacer()
          musicToggleButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)

        Spacer()

        VStack(spacing: 18) {
          Text("Game Review")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          ProgressView()
            .scaleEffect(1.15)
            .tint(Color(red: 0.95, green: 0.88, blue: 0.73))

          Text("Preparing your biggest evaluation drops...")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .background(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.92))
            .overlay(
              RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )
        .padding(.horizontal, 24)

        Spacer()
      }
    }
  }

  private var reviewDecisionOverlay: some View {
    ZStack {
      Color.black.opacity(0.72)
        .ignoresSafeArea()

      VStack {
        HStack {
          Spacer()
          musicToggleButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)

        Spacer()

        VStack(alignment: .leading, spacing: 16) {
          Text("Game Review")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text("Review your \(gameReview.stagedCheckpointCount) biggest evaluation drops, or leave the match now.")
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.84))
            .lineSpacing(3)

          HStack(spacing: 12) {
            NativeActionButton(title: "Leave", style: .outline) {
              gameReview.resetSession()
              returnHome()
            }

            NativeActionButton(title: "Game Review", style: .solid) {
              Task {
                if !(await gameReview.startStagedReviewSequence()) {
                  returnHome()
                }
              }
            }
          }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .background(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.92))
            .overlay(
              RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )
        .padding(.horizontal, 24)

        Spacer()
      }
    }
  }

  private var reviewCheckpointOverlay: some View {
    VStack {
      if let checkpoint = gameReview.currentCheckpoint {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Game Review")
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .tracking(2.0)
              .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

            Text("Checkpoint \(gameReview.currentReviewIndex + 1) of \(gameReview.reviewCheckpoints.count)")
              .font(.system(size: 24, weight: .heavy, design: .rounded))
              .foregroundStyle(.white)

            Text("Replay \(commentaryHumanMove(checkpoint.blunderMove)) from ply \(checkpoint.moveIndex).")
              .font(.system(size: 14, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.88))
              .lineSpacing(2)

            Text("Eval drop: \(formattedReviewDelta(checkpoint.deltaW))")
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.73))
          }
          .padding(18)
          .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.88))
              .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                  .stroke(Color.white.opacity(0.12), lineWidth: 1)
              )
          )

          Spacer(minLength: 0)

          VStack(spacing: 10) {
            musicToggleButton
              .frame(width: 170)

            NativeActionButton(title: "Try again", style: .outline) {
              gameReview.restartCurrentCheckpoint()
            }
            .frame(width: 170)

            NativeActionButton(title: "I give up", style: .solid) {
              if gameReview.advanceToNextCheckpoint() {
                returnHome()
              }
            }
            .frame(width: 170)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
      }

      Spacer()
    }
  }

  private var lessonOverlay: some View {
    VStack {
      if lessonStore.isComplete, let lesson = lessonStore.activeLesson {
        ZStack {
          Color.black.opacity(0.72)
            .ignoresSafeArea()

          VStack(alignment: .leading, spacing: 16) {
            Text("Lesson Complete")
              .font(.system(size: 34, weight: .heavy, design: .rounded))
              .foregroundStyle(.white)

            Text("\(lesson.title) is complete. You can restart it now or head back to the lessons catalog.")
              .font(.system(size: 16, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.84))
              .lineSpacing(3)

            HStack(spacing: 12) {
              NativeActionButton(title: "Restart Lesson", style: .outline) {
                lessonStore.restartLesson()
              }

              NativeActionButton(title: "Back to Lessons", style: .solid) {
                closeExperience()
              }
            }
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 30)
          .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
              .fill(Color(red: 0.07, green: 0.10, blue: 0.14).opacity(0.92))
              .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                  .stroke(Color.white.opacity(0.12), lineWidth: 1)
              )
          )
          .padding(.horizontal, 24)
        }
      } else {
        Spacer()

        if lessonStore.isAwaitingPlayerMove {
          HStack {
            Spacer()

            NativeActionButton(title: "See Move", style: .solid) {
              lessonStore.revealCurrentMove()
            }
            .frame(width: 170)
          }
          .padding(.horizontal, 18)
          .padding(.bottom, lessonActionBottomInset)
        }
      }
    }
  }

  private var fishingPromptOverlay: some View {
    VStack {
      Spacer()

      HStack(alignment: .bottom, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          if fishing.showsFishingStatus {
            FishingStatusChip(text: fishing.statusText)
              .transition(.move(edge: .leading).combined(with: .opacity))
          }

          if fishing.showsFishingButton {
            FishingActionButton {
              fishing.requestCast()
            }
            .transition(.scale(scale: 0.88).combined(with: .opacity))
          }
        }

        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.bottom, 30)
    }
  }

  private var lessonUsedStrikeCount: Int {
    let used = 3 - lessonStore.remainingTries
    return max(0, min(3, used))
  }

  private var lessonActionBottomInset: CGFloat {
    30
  }

  private func lessonStrikeBadge(isUsed: Bool) -> some View {
    ZStack {
      Circle()
        .fill(
          isUsed
            ? Color(red: 0.91, green: 0.31, blue: 0.33).opacity(0.94)
            : Color.white.opacity(0.10)
        )
        .overlay(
          Circle()
            .stroke(
              isUsed
                ? Color(red: 1.0, green: 0.74, blue: 0.72).opacity(0.80)
                : Color.white.opacity(0.16),
              lineWidth: 1
            )
        )

      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .black))
        .foregroundStyle(isUsed ? Color.white : Color.white.opacity(0.46))
    }
    .frame(width: 28, height: 28)
  }

  private func formattedReviewDelta(_ delta: Int) -> String {
    if abs(delta) >= 90_000 {
      return delta < 0 ? "mate collapse" : "mate gain"
    }

    return String(format: "%+.2f pawns", Double(delta) / 100.0)
  }

  private var geminiDebugPanel: some View {
    debugOverlayCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Gemini debug")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

        Text(commentary.hintStatusText)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.86))

        HStack(spacing: 8) {
          Text("Live:")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.76))

          Text(commentary.geminiConnectionState.rawValue)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(connectionStateColor)
        }

        if let connectionError = commentary.geminiConnectionLastError {
          Text(connectionError)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.95, green: 0.70, blue: 0.62))
            .lineLimit(2)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Gemini Coach Lines")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.88))

          if commentary.coachLines.isEmpty {
            Text("No coach lines yet.")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.68))
          } else {
            ForEach(Array(commentary.coachLines.enumerated()), id: \.offset) { _, line in
              Text("Coach: \(line)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.95, green: 0.90, blue: 0.80))
                .lineSpacing(2)
            }
          }

          if !commentary.topWorkers.isEmpty {
            Text("Workers: \(geminiRoleSummary(commentary.topWorkers))")
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.70))
              .lineSpacing(2)
          }

          if !commentary.topTraitors.isEmpty {
            Text("Traitors: \(geminiRoleSummary(commentary.topTraitors))")
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.70))
              .lineSpacing(2)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Auto Commentary Lines")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.88))

          Text(commentary.pieceVoiceStatusText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(red: 0.80, green: 0.88, blue: 0.95))
            .lineSpacing(2)

          if commentary.pieceVoiceLines.isEmpty {
            Text("No automatic commentary yet.")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.68))
          } else {
            ForEach(Array(commentary.pieceVoiceLines.enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.86, green: 0.94, blue: 0.88))
                .lineSpacing(2)
            }
          }
        }

        if commentary.geminiDebugLines.isEmpty {
          Text("No Gemini activity yet.")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
        } else {
          ForEach(Array(commentary.geminiDebugLines.reversed()), id: \.self) { line in
            Text(line)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.white.opacity(0.80))
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var voiceStackPanel: some View {
    debugOverlayCard {
      VStack(alignment: .leading, spacing: 14) {
        Text("Voice line stack")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

        Text(commentary.pieceVoiceStatusText)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Color(red: 0.80, green: 0.88, blue: 0.95))
          .lineSpacing(2)

        VStack(alignment: .leading, spacing: 10) {
          Text("Dialogue settings")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.88))

          Text("These odds only control whether a chosen speaker reacts to recent piece dialogue or stays fresh. They do not change when narrator vs piece gets selected to talk.")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
            .lineSpacing(2)

          dialogueOddsControl(
            title: "Piece uses piece context",
            contextualPercent: commentary.pieceHistoryReactiveChancePercent,
            independentLabel: "Fresh piece line",
            independentPercent: max(0, 100 - commentary.pieceHistoryReactiveChancePercent),
            accent: Color(red: 0.80, green: 0.92, blue: 0.84),
            value: pieceHistoryReactiveChanceBinding
          )

          Text(commentary.pieceDialogueModeStatusText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineSpacing(2)

          dialogueOddsControl(
            title: "Narrator reacts to latest piece line",
            contextualPercent: commentary.narratorPieceReactiveChancePercent,
            independentLabel: "Independent narrator line",
            independentPercent: max(0, 100 - commentary.narratorPieceReactiveChancePercent),
            accent: Color(red: 0.95, green: 0.84, blue: 0.66),
            value: narratorPieceReactiveChanceBinding
          )

          Text(commentary.narratorDialogueModeStatusText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineSpacing(2)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              dialoguePresetButton(title: "Defaults") {
                commentary.resetPassiveDialogueModeOddsToDefaults()
              }

              dialoguePresetButton(title: "Context Heavy") {
                commentary.setPieceHistoryReactiveChancePercent(100)
                commentary.setNarratorPieceReactiveChancePercent(100)
              }

              dialoguePresetButton(title: "Fresh Only") {
                commentary.setPieceHistoryReactiveChancePercent(0)
                commentary.setNarratorPieceReactiveChancePercent(0)
              }
            }
          }
        }

        Divider()
          .overlay(Color.white.opacity(0.10))

        VStack(alignment: .leading, spacing: 8) {
          Text("Recent lines")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.88))

          if commentary.pieceVoiceLines.isEmpty {
            Text("No automatic commentary yet. Make a move to trigger one.")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.72))
          } else {
            ForEach(Array(commentary.pieceVoiceLines.reversed().enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.86, green: 0.94, blue: 0.88))
                .lineSpacing(2)
            }
          }
        }
      }
    }
  }

  private var pieceHistoryReactiveChanceBinding: Binding<Double> {
    Binding(
      get: { Double(commentary.pieceHistoryReactiveChancePercent) },
      set: { commentary.setPieceHistoryReactiveChancePercent(Int($0.rounded())) }
    )
  }

  private var narratorPieceReactiveChanceBinding: Binding<Double> {
    Binding(
      get: { Double(commentary.narratorPieceReactiveChancePercent) },
      set: { commentary.setNarratorPieceReactiveChancePercent(Int($0.rounded())) }
    )
  }

  private func dialogueOddsControl(
    title: String,
    contextualPercent: Int,
    independentLabel: String,
    independentPercent: Int,
    accent: Color,
    value: Binding<Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.90))

        Spacer(minLength: 8)

        Text("Context \(contextualPercent)%")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(accent)
      }

      Slider(value: value, in: 0...100, step: 5)
        .tint(accent)

      Text("\(independentLabel): \(independentPercent)%")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.66))
    }
  }

  private func dialoguePresetButton(
    title: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(Color.white.opacity(0.92))
        .background(
          Capsule(style: .continuous)
            .fill(Color.white.opacity(0.10))
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }

  private var stockfishDebugPanel: some View {
    debugOverlayCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Stockfish debug")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

        Text(commentary.stockfishDebugStatusText)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.82))

        Button {
          Task {
            await commentary.analyzeCurrentPosition()
          }
        } label: {
          Text("Analyze position")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.black.opacity(0.88))
            .background(
              Capsule(style: .continuous)
                .fill(Color(red: 0.95, green: 0.88, blue: 0.73))
            )
        }
        .buttonStyle(.plain)

        if commentary.stockfishDebugWhiteMoves.isEmpty && commentary.stockfishDebugBlackMoves.isEmpty {
          Text("No Stockfish move lines yet.")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
        } else {
          if !commentary.stockfishDebugWhiteMoves.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Stockfish top 5: White")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.86))

              stockfishMoveList(commentary.stockfishDebugWhiteMoves)
            }
          }

          if !commentary.stockfishDebugBlackMoves.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Stockfish top 5: Black")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.86))

              stockfishMoveList(commentary.stockfishDebugBlackMoves)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func stockfishMoveList(_ moves: [StockfishCandidate]) -> some View {
    ForEach(Array(moves.prefix(StockfishAnalysisDefaults.multiPV).enumerated()), id: \.offset) { _, candidate in
      VStack(alignment: .leading, spacing: 2) {
        Text(stockfishCandidateHeadline(candidate))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.84))
          .textSelection(.enabled)

        Text(stockfishCandidatePV(candidate))
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.68))
          .textSelection(.enabled)
      }
    }
  }

  private func stockfishCandidateHeadline(_ candidate: StockfishCandidate) -> String {
    let move = commentaryHumanMove(candidate.move ?? "(none)")
    let rootRange = [candidate.rootFrom, candidate.rootTo].compactMap { $0 }.joined(separator: "→")
    let rootSuffix = rootRange.isEmpty ? "" : " | \(rootRange)"
    let confidence = Int((candidate.confidence * 100.0).rounded())
    return "\(candidate.rank). \(move) (\(candidate.formattedScore)) | d\(candidate.depth) | conf \(confidence)%\(rootSuffix)"
  }

  private func stockfishCandidatePV(_ candidate: StockfishCandidate) -> String {
    let preview = candidate.pvPreview.map(commentaryHumanMove).joined(separator: " -> ")
    return preview.isEmpty ? "pv: —" : "pv: \(preview)"
  }

  private func commentaryHumanMove(_ uci: String) -> String {
    guard uci.count >= 4 else {
      return uci
    }

    let from = String(uci.prefix(2))
    let to = String(uci.dropFirst(2).prefix(2))
    guard uci.count > 4 else {
      return "\(from) to \(to)"
    }

    let promotion = String(uci.suffix(1)).lowercased()
    let promotionName: String
    switch promotion {
    case "q":
      promotionName = "queen"
    case "r":
      promotionName = "rook"
    case "b":
      promotionName = "bishop"
    case "n":
      promotionName = "knight"
    default:
      promotionName = promotion
    }

    return "\(from) to \(to) = \(promotionName)"
  }

  private func geminiRoleSummary(_ roles: [GeminiPieceRole]) -> String {
    roles.map { "\($0.piece) \($0.square)" }.joined(separator: " | ")
  }

  private var debugPanelBackground: some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
      .fill(Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.86))
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(Color.white.opacity(0.14), lineWidth: 1)
      )
  }

  private func overlayPanelMaxHeight(ratio: CGFloat) -> CGFloat {
    UIScreen.main.bounds.height * ratio
  }

  private func debugOverlayCard<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    ZStack {
      debugPanelBackground

      ScrollView(showsIndicators: true) {
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(18)
      }
      .frame(maxWidth: .infinity, maxHeight: overlayPanelMaxHeight(ratio: 0.42), alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: overlayPanelMaxHeight(ratio: 0.42), alignment: .top)
    .contentShape(Rectangle())
  }

  private func syncStockfishDebugVisibility() {
    commentary.setStockfishDebugVisible(isStockfishDebugVisible)
  }

  private var modeTitle: String {
    switch mode {
    case .lesson(let lesson):
      return lesson.title
    case .passAndPlay(let playerMode):
      return playerMode.title + " Mode"
    case .queueMatch:
      return "Queue Match"
    case .playVsStockfish(let configuration):
      return configuration.modeTitle
    }
  }

  private var activeEntries: [MatchLogStore.Entry] {
    switch mode {
    case .lesson:
      return []
    case .passAndPlay(_), .playVsStockfish:
      return matchLog.entries
    case .queueMatch:
      return queueMatch.logEntries
    }
  }

  private var activeRemoteGameID: String? {
    switch mode {
    case .lesson:
      return nil
    case .passAndPlay(_), .playVsStockfish:
      return matchLog.remoteGameID
    case .queueMatch:
      return queueMatch.remoteGameID
    }
  }

  private var activeSyncStatus: String {
    switch mode {
    case .lesson:
      return "Lesson mode keeps the board local to this guided opening flow."
    case .passAndPlay(_), .playVsStockfish:
      return matchLog.syncStatus
    case .queueMatch:
      return queueMatch.statusText
    }
  }

  private var connectionStateColor: Color {
    switch commentary.geminiConnectionState {
    case .connected:
      return Color(red: 0.56, green: 0.91, blue: 0.69)
    case .connecting:
      return Color(red: 0.96, green: 0.82, blue: 0.54)
    case .error:
      return Color(red: 0.95, green: 0.66, blue: 0.62)
    case .disconnected:
      return Color.white.opacity(0.70)
    }
  }

  private var isLessonMode: Bool {
    mode.isLessonMode
  }
}

private struct ChessboardBackdrop: View {
  private let rows = 14
  private let columns = 10
  private let overdraw = 2

  var body: some View {
    GeometryReader { geometry in
      let squareSize = max(geometry.size.width / CGFloat(columns), geometry.size.height / CGFloat(rows))
      let renderedRows = rows + overdraw
      let renderedColumns = columns + overdraw

      ZStack {
        Color(red: 0.07, green: 0.10, blue: 0.13)
          .ignoresSafeArea()

        ForEach(0..<renderedRows, id: \.self) { row in
          ForEach(0..<renderedColumns, id: \.self) { column in
            let gridRow = row - (overdraw / 2)
            let gridColumn = column - (overdraw / 2)
            Rectangle()
              .fill(squareColor(row: gridRow, column: gridColumn))
              .frame(width: squareSize, height: squareSize)
              .position(
                x: (CGFloat(gridColumn) + 0.5) * squareSize,
                y: (CGFloat(gridRow) + 0.5) * squareSize
              )
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      .overlay(
        LinearGradient(
          colors: [
            Color(red: 0.93, green: 0.77, blue: 0.53).opacity(0.08),
            Color.clear,
            Color.black.opacity(0.34),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .ignoresSafeArea()
    }
  }

  private func squareColor(row: Int, column: Int) -> Color {
    if (row + column).isMultiple(of: 2) {
      return Color(red: 0.76, green: 0.69, blue: 0.56).opacity(0.90)
    }

    return Color(red: 0.17, green: 0.22, blue: 0.28).opacity(0.94)
  }
}

private struct FishingRodGlyph: View {
  var body: some View {
    GeometryReader { geometry in
      let size = min(geometry.size.width, geometry.size.height)

      ZStack {
        Path { path in
          path.move(to: CGPoint(x: size * 0.24, y: size * 0.82))
          path.addLine(to: CGPoint(x: size * 0.66, y: size * 0.30))
          path.addQuadCurve(
            to: CGPoint(x: size * 0.82, y: size * 0.14),
            control: CGPoint(x: size * 0.77, y: size * 0.22)
          )
        }
        .stroke(
          Color(red: 0.12, green: 0.16, blue: 0.20),
          style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round)
        )

        Circle()
          .stroke(Color(red: 0.12, green: 0.16, blue: 0.20), lineWidth: size * 0.08)
          .frame(width: size * 0.22, height: size * 0.22)
          .position(x: size * 0.37, y: size * 0.68)

        Path { path in
          path.move(to: CGPoint(x: size * 0.82, y: size * 0.14))
          path.addLine(to: CGPoint(x: size * 0.80, y: size * 0.62))
          path.addQuadCurve(
            to: CGPoint(x: size * 0.58, y: size * 0.78),
            control: CGPoint(x: size * 0.78, y: size * 0.76)
          )
        }
        .stroke(
          Color.white.opacity(0.82),
          style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round, lineJoin: .round)
        )

        Circle()
          .fill(Color(red: 0.94, green: 0.34, blue: 0.28))
          .frame(width: size * 0.17, height: size * 0.17)
          .position(x: size * 0.55, y: size * 0.78)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }
}

private struct FishingActionButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [
                Color(red: 0.95, green: 0.88, blue: 0.73),
                Color(red: 0.78, green: 0.88, blue: 0.95),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .shadow(color: Color.black.opacity(0.28), radius: 20, y: 12)

        Circle()
          .stroke(Color.white.opacity(0.58), lineWidth: 1.5)

        VStack(spacing: 6) {
          FishingRodGlyph()
            .frame(width: 34, height: 34)

          Text("Fish")
            .font(.system(size: 13, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.16))
        }
      }
      .frame(width: 92, height: 92)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Cast fishing line")
  }
}

private struct FishingStatusChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .lineSpacing(2)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        Capsule(style: .continuous)
          .fill(Color(red: 0.06, green: 0.09, blue: 0.12).opacity(0.84))
          .overlay(
            Capsule(style: .continuous)
              .stroke(Color.white.opacity(0.14), lineWidth: 1)
          )
      )
  }
}

private struct FishingFirstPersonOverlay: View {
  let state: FishingInteractionStore.State

  var body: some View {
    if showsRig {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
        GeometryReader { geometry in
          let metrics = overlayMetrics(
            size: geometry.size,
            timestamp: context.date.timeIntervalSinceReferenceDate
          )

          ZStack {
            fishingLine(metrics: metrics)
            fishingRod(metrics: metrics)
            frontHand(metrics: metrics)
            rearHand(metrics: metrics)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
      }
      .ignoresSafeArea()
      .transition(.opacity)
    }
  }

  private var showsRig: Bool {
    switch state {
    case .eligible, .casting, .waiting, .bite, .catchWindow, .caught:
      return true
    case .idle, .revealNote, .reset:
      return false
    }
  }

  private func overlayMetrics(size: CGSize, timestamp: TimeInterval) -> FishingRigMetrics {
    let idleBob = CGFloat(sin(timestamp * 2.1) * 6.0)
    let biteJerk = CGFloat(sin(timestamp * 34.0) * 10.0)

    let baseX = size.width * 0.72
    let baseY = size.height * 0.93
    let rigWidth = min(size.width * 0.54, 360)
    let rigHeight = min(size.height * 0.30, 250)

    switch state {
    case .eligible:
      return FishingRigMetrics(
        center: CGPoint(x: baseX, y: baseY + idleBob),
        rigSize: CGSize(width: rigWidth, height: rigHeight),
        rodAngle: -23,
        handAngle: -2,
        lineLength: size.height * 0.12,
        rodScale: 0.96
      )
    case .casting:
      return FishingRigMetrics(
        center: CGPoint(x: baseX + 10, y: baseY - 22),
        rigSize: CGSize(width: rigWidth * 1.02, height: rigHeight * 1.02),
        rodAngle: -30,
        handAngle: -8,
        lineLength: size.height * 0.16,
        rodScale: 1.02
      )
    case .waiting:
      return FishingRigMetrics(
        center: CGPoint(x: baseX + 6, y: baseY - 10 + idleBob),
        rigSize: CGSize(width: rigWidth, height: rigHeight),
        rodAngle: -26,
        handAngle: -4,
        lineLength: size.height * 0.18,
        rodScale: 1.0
      )
    case .bite, .catchWindow:
      return FishingRigMetrics(
        center: CGPoint(x: baseX + 2 + biteJerk, y: baseY - 22 - abs(biteJerk)),
        rigSize: CGSize(width: rigWidth * 1.03, height: rigHeight * 1.03),
        rodAngle: -18,
        handAngle: -2,
        lineLength: size.height * 0.20,
        rodScale: 1.03
      )
    case .caught:
      return FishingRigMetrics(
        center: CGPoint(x: baseX - 6, y: baseY - 56),
        rigSize: CGSize(width: rigWidth * 1.02, height: rigHeight * 1.02),
        rodAngle: -8,
        handAngle: 6,
        lineLength: size.height * 0.10,
        rodScale: 1.04
      )
    case .idle, .revealNote, .reset:
      return FishingRigMetrics(
        center: CGPoint(x: baseX, y: baseY),
        rigSize: CGSize(width: rigWidth, height: rigHeight),
        rodAngle: -30,
        handAngle: 0,
        lineLength: size.height * 0.12,
        rodScale: 1.0
      )
    }
  }

  private func fishingLine(metrics: FishingRigMetrics) -> some View {
    Capsule(style: .continuous)
      .fill(Color.white.opacity(0.76))
      .frame(width: 2.5, height: metrics.lineLength)
      .position(
        x: metrics.center.x + (metrics.rigSize.width * 0.08),
        y: metrics.center.y - (metrics.rigSize.height * 0.47)
      )
      .rotationEffect(.degrees(metrics.rodAngle * 0.20))
      .blur(radius: 0.15)
  }

  private func fishingRod(metrics: FishingRigMetrics) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.63, green: 0.47, blue: 0.23),
              Color(red: 0.36, green: 0.24, blue: 0.12),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: 18, height: metrics.rigSize.height * 0.78)
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.26), radius: 18, y: 10)

      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color(red: 0.98, green: 0.84, blue: 0.37),
              Color(red: 0.55, green: 0.40, blue: 0.05),
            ],
            center: .center,
            startRadius: 2,
            endRadius: 24
          )
        )
        .frame(width: 48, height: 48)
        .offset(x: 26, y: 56)

      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(red: 0.89, green: 0.79, blue: 0.57))
        .frame(width: 11, height: metrics.rigSize.height * 0.16)
        .offset(x: 0, y: -(metrics.rigSize.height * 0.35))
    }
    .scaleEffect(metrics.rodScale)
    .rotationEffect(.degrees(metrics.rodAngle))
    .position(x: metrics.center.x, y: metrics.center.y)
  }

  private func frontHand(metrics: FishingRigMetrics) -> some View {
    FishingOverlayHand(
      sleeveColor: Color(red: 0.10, green: 0.13, blue: 0.18),
      skinColor: Color(red: 0.88, green: 0.73, blue: 0.61)
    )
    .frame(width: metrics.rigSize.width * 0.42, height: metrics.rigSize.height * 0.34)
    .rotationEffect(.degrees(metrics.handAngle))
    .position(
      x: metrics.center.x - (metrics.rigSize.width * 0.16),
      y: metrics.center.y + (metrics.rigSize.height * 0.18)
    )
  }

  private func rearHand(metrics: FishingRigMetrics) -> some View {
    FishingOverlayHand(
      sleeveColor: Color(red: 0.15, green: 0.19, blue: 0.24),
      skinColor: Color(red: 0.90, green: 0.76, blue: 0.64)
    )
    .frame(width: metrics.rigSize.width * 0.50, height: metrics.rigSize.height * 0.40)
    .rotationEffect(.degrees(metrics.handAngle + 8))
    .position(
      x: metrics.center.x + (metrics.rigSize.width * 0.08),
      y: metrics.center.y + (metrics.rigSize.height * 0.24)
    )
  }
}

private struct FishingRigMetrics {
  let center: CGPoint
  let rigSize: CGSize
  let rodAngle: Double
  let handAngle: Double
  let lineLength: CGFloat
  let rodScale: CGFloat
}

private struct FishingOverlayHand: View {
  let sleeveColor: Color
  let skinColor: Color

  var body: some View {
    ZStack(alignment: .trailing) {
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .fill(sleeveColor)
        .frame(width: 150, height: 82)
        .overlay(
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )

      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(skinColor)
        .frame(width: 84, height: 68)
        .offset(x: 22, y: -2)

      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(skinColor)
        .frame(width: 24, height: 44)
        .offset(x: 48, y: -10)

      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(skinColor)
        .frame(width: 24, height: 40)
        .offset(x: 54, y: 10)
    }
    .shadow(color: Color.black.opacity(0.22), radius: 12, y: 8)
  }
}

private struct FishingRewardOverlay: View {
  let rewardMoves: [String]
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.56)
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)

      VStack(alignment: .leading, spacing: 16) {
        header
        moveList

        HStack(spacing: 12) {
          NativeActionButton(title: "Cast again", style: .solid, action: onDismiss)
        }
      }
      .padding(24)
      .background(cardBackground)
      .padding(.horizontal, 24)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Pond Reward")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(2.0)
          .foregroundStyle(Color(red: 0.84, green: 0.91, blue: 0.96))

        Text("Stockfish's note")
          .font(.system(size: 28, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)

        Text("The fish dragged back a short move list from the engine.")
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.78))
          .lineSpacing(3)
      }

      Spacer(minLength: 12)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.88))
          .frame(width: 38, height: 38)
          .background(
            Circle()
              .fill(Color.white.opacity(0.08))
          )
      }
      .buttonStyle(.plain)
    }
  }

  private var moveList: some View {
    ScrollView(showsIndicators: true) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(rewardMoves.enumerated()), id: \.offset) { _, line in
          FishingRewardLine(text: line)
        }
      }
      .padding(18)
    }
    .frame(maxHeight: UIScreen.main.bounds.height * 0.38)
    .background(noteBackground)
  }

  private var noteBackground: some View {
    RoundedRectangle(cornerRadius: 26, style: .continuous)
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.96, green: 0.94, blue: 0.88),
            Color(red: 0.87, green: 0.84, blue: 0.76),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 30, style: .continuous)
      .fill(Color(red: 0.06, green: 0.11, blue: 0.15).opacity(0.94))
      .overlay(
        RoundedRectangle(cornerRadius: 30, style: .continuous)
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      )
  }
}

private struct FishingRewardLine: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.18))
      .lineSpacing(3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.white.opacity(0.82))
      )
  }
}

private struct NativeActionButton: View {
  enum ButtonStyleKind {
    case solid
    case outline
  }

  let title: String
  let style: ButtonStyleKind
  var isDisabled = false
  var showsSpinner = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if showsSpinner {
          ProgressView()
            .tint(foregroundColor)
        }

        Text(title)
          .font(.system(size: 18, weight: .bold, design: .rounded))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
      .foregroundStyle(foregroundColor.opacity(isDisabled ? 0.66 : 1.0))
      .background(background.opacity(isDisabled ? 0.72 : 1.0))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .shadow(color: Color.black.opacity(style == .solid ? 0.22 : 0.0), radius: 14, y: 10)
  }

  private var foregroundColor: Color {
    switch style {
    case .solid:
      return Color(red: 0.06, green: 0.08, blue: 0.11)
    case .outline:
      return .white
    }
  }

  @ViewBuilder
  private var background: some View {
    switch style {
    case .solid:
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(red: 0.95, green: 0.88, blue: 0.73))
    case .outline:
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color.white.opacity(0.06))
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
  }
}

private enum ChessColor {
  case white
  case black

  init?(serverValue: String?) {
    switch serverValue?.lowercased() {
    case "white":
      self = .white
    case "black":
      self = .black
    default:
      return nil
    }
  }

  var opponent: ChessColor {
    switch self {
    case .white:
      return .black
    case .black:
      return .white
    }
  }

  var fenSymbol: String {
    switch self {
    case .white:
      return "w"
    case .black:
      return "b"
    }
  }

  var displayName: String {
    switch self {
    case .white:
      return "White"
    case .black:
      return "Black"
    }
  }

  static func turnColor(forPly ply: Int) -> ChessColor {
    ply.isMultiple(of: 2) ? .black : .white
  }

  static func turnColor(afterLatestPly latestPly: Int) -> ChessColor {
    latestPly.isMultiple(of: 2) ? .white : .black
  }
}

private enum ChessPieceKind {
  case pawn
  case rook
  case knight
  case bishop
  case queen
  case king

  var strategicRoleTradeValue: Int {
    switch self {
    case .pawn:
      return 1
    case .knight, .bishop:
      return 3
    case .rook:
      return 5
    case .queen:
      return 9
    case .king:
      return .max
    }
  }

  var displayName: String {
    switch self {
    case .pawn:
      return "Pawn"
    case .rook:
      return "Rook"
    case .knight:
      return "Knight"
    case .bishop:
      return "Bishop"
    case .queen:
      return "Queen"
    case .king:
      return "King"
    }
  }

  var fenSymbol: Character {
    switch self {
    case .pawn:
      return "p"
    case .rook:
      return "r"
    case .knight:
      return "n"
    case .bishop:
      return "b"
    case .queen:
      return "q"
    case .king:
      return "k"
    }
  }

  var sanSymbol: String {
    switch self {
    case .pawn:
      return ""
    case .rook:
      return "R"
    case .knight:
      return "N"
    case .bishop:
      return "B"
    case .queen:
      return "Q"
    case .king:
      return "K"
    }
  }

  var forkThreatPriority: Int {
    switch self {
    case .king:
      return 6
    case .queen:
      return 5
    case .rook:
      return 4
    case .bishop:
      return 3
    case .knight:
      return 2
    case .pawn:
      return 1
    }
  }

  init?(fenSymbol: Character) {
    switch String(fenSymbol).lowercased() {
    case "p":
      self = .pawn
    case "r":
      self = .rook
    case "n":
      self = .knight
    case "b":
      self = .bishop
    case "q":
      self = .queen
    case "k":
      self = .king
    default:
      return nil
    }
  }
}

private struct BoardSquare: Hashable {
  let file: Int
  let rank: Int

  init(file: Int, rank: Int) {
    self.file = file
    self.rank = rank
  }

  init?(algebraic: String) {
    let trimmed = algebraic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.count == 2 else {
      return nil
    }

    let characters = Array(trimmed)
    guard let fileScalar = characters.first?.unicodeScalars.first,
          let rankScalar = characters.last?.unicodeScalars.first else {
      return nil
    }

    let fileValue = Int(fileScalar.value) - 97
    let rankValue = Int(rankScalar.value) - 49
    guard (0..<8).contains(fileValue), (0..<8).contains(rankValue) else {
      return nil
    }

    self.file = fileValue
    self.rank = rankValue
  }

  var isValid: Bool {
    (0..<8).contains(file) && (0..<8).contains(rank)
  }

  var algebraic: String {
    let fileScalar = UnicodeScalar(97 + file) ?? UnicodeScalar(97)!
    return "\(Character(fileScalar))\(rank + 1)"
  }

  func offset(file deltaFile: Int, rank deltaRank: Int) -> BoardSquare? {
    let target = BoardSquare(file: file + deltaFile, rank: rank + deltaRank)
    return target.isValid ? target : nil
  }
}

private struct ChessPieceState {
  var color: ChessColor
  var kind: ChessPieceKind
}

private struct CastlingRights {
  var whiteKingside = true
  var whiteQueenside = true
  var blackKingside = true
  var blackQueenside = true
}

private struct ChessMove {
  let from: BoardSquare
  let to: BoardSquare
  let piece: ChessPieceState
  var captured: ChessPieceState?
  var isEnPassant = false
  var rookMove: (from: BoardSquare, to: BoardSquare)?
  var promotion: ChessPieceKind?

  var uciString: String {
    let promotionSuffix: String
    if let promotion {
      switch promotion {
      case .queen:
        promotionSuffix = "q"
      case .rook:
        promotionSuffix = "r"
      case .bishop:
        promotionSuffix = "b"
      case .knight:
        promotionSuffix = "n"
      default:
        promotionSuffix = ""
      }
    } else {
      promotionSuffix = ""
    }

    return from.algebraic + to.algebraic + promotionSuffix
  }
}

private struct ChessGameState {
  enum GameOutcome: Equatable {
    case checkmate(winner: ChessColor)
    case stalemate
  }

  var board: [BoardSquare: ChessPieceState]
  var turn: ChessColor
  var castlingRights: CastlingRights
  var enPassantTarget: BoardSquare?
  var halfmoveClock: Int
  var fullmoveNumber: Int

  init(
    board: [BoardSquare: ChessPieceState],
    turn: ChessColor,
    castlingRights: CastlingRights,
    enPassantTarget: BoardSquare?,
    halfmoveClock: Int,
    fullmoveNumber: Int
  ) {
    self.board = board
    self.turn = turn
    self.castlingRights = castlingRights
    self.enPassantTarget = enPassantTarget
    self.halfmoveClock = halfmoveClock
    self.fullmoveNumber = fullmoveNumber
  }

  static func initial() -> ChessGameState {
    let backRank: [ChessPieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
    var board: [BoardSquare: ChessPieceState] = [:]

    for file in 0..<8 {
      board[BoardSquare(file: file, rank: 0)] = ChessPieceState(color: .white, kind: backRank[file])
      board[BoardSquare(file: file, rank: 1)] = ChessPieceState(color: .white, kind: .pawn)
      board[BoardSquare(file: file, rank: 6)] = ChessPieceState(color: .black, kind: .pawn)
      board[BoardSquare(file: file, rank: 7)] = ChessPieceState(color: .black, kind: backRank[file])
    }

    return ChessGameState(
      board: board,
      turn: .white,
      castlingRights: CastlingRights(),
      enPassantTarget: nil,
      halfmoveClock: 0,
      fullmoveNumber: 1
    )
  }

  init(fen: String) throws {
    let validatedFEN = try StockfishFENValidator.validate(fen)
    let fields = validatedFEN.fen.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    let placement = fields[0]
    let castling = fields[2]
    let enPassant = fields[3]

    var parsedBoard: [BoardSquare: ChessPieceState] = [:]
    let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)

    for (rankOffset, rankText) in ranks.enumerated() {
      let rank = 7 - rankOffset
      var file = 0

      for character in rankText {
        if let emptySquares = character.wholeNumberValue {
          file += emptySquares
          continue
        }

        guard let kind = ChessPieceKind(fenSymbol: character) else {
          throw StockfishFENValidationError.invalidPieceCharacter(character)
        }

        let color: ChessColor = character.isUppercase ? .white : .black
        let square = BoardSquare(file: file, rank: rank)
        parsedBoard[square] = ChessPieceState(color: color, kind: kind)
        file += 1
      }
    }

    var rights = CastlingRights(
      whiteKingside: false,
      whiteQueenside: false,
      blackKingside: false,
      blackQueenside: false
    )
    if castling != "-" {
      rights.whiteKingside = castling.contains("K")
      rights.whiteQueenside = castling.contains("Q")
      rights.blackKingside = castling.contains("k")
      rights.blackQueenside = castling.contains("q")
    }

    board = parsedBoard
    turn = validatedFEN.sideToMove
    castlingRights = rights
    enPassantTarget = enPassant == "-" ? nil : BoardSquare(algebraic: enPassant)
    halfmoveClock = Int(fields[4]) ?? 0
    fullmoveNumber = Int(fields[5]) ?? 1
  }

  var fenString: String {
    let boardField = (0..<8).reversed().map { rank -> String in
      var row = ""
      var emptyCount = 0

      for file in 0..<8 {
        let square = BoardSquare(file: file, rank: rank)
        if let piece = board[square] {
          if emptyCount > 0 {
            row.append(String(emptyCount))
            emptyCount = 0
          }

          let symbol = piece.kind.fenSymbol
          row.append(piece.color == .white ? Character(String(symbol).uppercased()) : symbol)
        } else {
          emptyCount += 1
        }
      }

      if emptyCount > 0 {
        row.append(String(emptyCount))
      }

      return row
    }.joined(separator: "/")

    let castlingField = castlingFieldString
    let enPassantField = enPassantTarget?.algebraic ?? "-"
    return "\(boardField) \(turn.fenSymbol) \(castlingField) \(enPassantField) \(halfmoveClock) \(fullmoveNumber)"
  }

  private var castlingFieldString: String {
    var field = ""

    if castlingRights.whiteKingside {
      field.append("K")
    }
    if castlingRights.whiteQueenside {
      field.append("Q")
    }
    if castlingRights.blackKingside {
      field.append("k")
    }
    if castlingRights.blackQueenside {
      field.append("q")
    }

    return field.isEmpty ? "-" : field
  }

  func piece(at square: BoardSquare) -> ChessPieceState? {
    board[square]
  }

  func legalMoves(from square: BoardSquare) -> [ChessMove] {
    guard let piece = board[square], piece.color == turn else {
      return []
    }

    return pseudoLegalMoves(from: square, piece: piece).filter { move in
      !applying(move).isInCheck(for: piece.color)
    }
  }

  func legalMove(from: BoardSquare, to: BoardSquare) -> ChessMove? {
    legalMoves(from: from).first { $0.to == to }
  }

  func move(forUCI uci: String) -> ChessMove? {
    let trimmed = uci.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.count == 4 || trimmed.count == 5 else {
      return nil
    }

    let fromIndex = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let toIndex = trimmed.index(fromIndex, offsetBy: 2)
    let fromString = String(trimmed[..<fromIndex])
    let toString = String(trimmed[fromIndex..<toIndex])
    let promotionCode = trimmed.count == 5 ? trimmed.last : nil

    guard let from = BoardSquare(algebraic: fromString),
          let to = BoardSquare(algebraic: toString) else {
      return nil
    }

    return legalMoves(from: from).first { candidate in
      guard candidate.to == to else {
        return false
      }

      switch (candidate.promotion, promotionCode) {
      case (nil, nil):
        return true
      case (.some(let promotion), .some(let code)):
        return promotion.fenSymbol == code
      default:
        return false
      }
    }
  }

  func hasLegalMoves(for color: ChessColor) -> Bool {
    for (square, piece) in board where piece.color == color {
      if !legalMoves(from: square, for: color).isEmpty {
        return true
      }
    }

    return false
  }

  func isCheckmate(for color: ChessColor) -> Bool {
    isInCheck(for: color) && !hasLegalMoves(for: color)
  }

  func isStalemate(for color: ChessColor) -> Bool {
    !isInCheck(for: color) && !hasLegalMoves(for: color)
  }

  var outcome: GameOutcome? {
    if isCheckmate(for: turn) {
      return .checkmate(winner: turn.opponent)
    }
    if isStalemate(for: turn) {
      return .stalemate
    }
    return nil
  }

  func applying(_ move: ChessMove) -> ChessGameState {
    var next = self
    var movingPiece = move.piece

    next.board[move.from] = nil

    if move.isEnPassant {
      let capturedRank = move.piece.color == .white ? move.to.rank - 1 : move.to.rank + 1
      next.board[BoardSquare(file: move.to.file, rank: capturedRank)] = nil
    } else if move.captured != nil {
      next.board[move.to] = nil
    }

    if let rookMove = move.rookMove, let rookPiece = next.board[rookMove.from] {
      next.board[rookMove.from] = nil
      next.board[rookMove.to] = rookPiece
    }

    if let promotion = move.promotion {
      movingPiece.kind = promotion
    }

    next.board[move.to] = movingPiece
    next.enPassantTarget = nil
    next.halfmoveClock = (move.piece.kind == .pawn || move.captured != nil) ? 0 : (halfmoveClock + 1)

    if move.piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
      next.enPassantTarget = BoardSquare(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
    }

    next.updateCastlingRights(for: move)
    next.turn = turn.opponent
    next.fullmoveNumber = fullmoveNumber + (turn == .black ? 1 : 0)
    return next
  }

  func sanNotation(for move: ChessMove) -> String {
    let baseNotation: String
    if move.rookMove != nil {
      baseNotation = move.to.file == 6 ? "O-O" : "O-O-O"
    } else {
      let isCapture = move.captured != nil || move.isEnPassant
      let destination = move.to.algebraic
      let promotionSuffix = move.promotion.map { "=\($0.sanSymbol)" } ?? ""

      if move.piece.kind == .pawn {
        let capturePrefix = isCapture ? String(move.from.algebraic.prefix(1)) + "x" : ""
        baseNotation = capturePrefix + destination + promotionSuffix
      } else {
        let disambiguation = sanDisambiguation(for: move)
        let captureMarker = isCapture ? "x" : ""
        baseNotation = move.piece.kind.sanSymbol + disambiguation + captureMarker + destination + promotionSuffix
      }
    }

    let afterState = applying(move)
    if afterState.isCheckmate(for: afterState.turn) {
      return baseNotation + "#"
    }
    if afterState.isInCheck(for: afterState.turn) {
      return baseNotation + "+"
    }
    return baseNotation
  }

  func isInCheck(for color: ChessColor) -> Bool {
    guard let kingSquare = kingSquare(for: color) else {
      return false
    }

    return isSquareAttacked(kingSquare, by: color.opponent)
  }

  func kingSquare(for color: ChessColor) -> BoardSquare? {
    board.first(where: { $0.value.color == color && $0.value.kind == .king })?.key
  }

  func attackOrigins(on target: BoardSquare, by attacker: ChessColor) -> [BoardSquare] {
    var origins: [BoardSquare] = []

    for (origin, piece) in board where piece.color == attacker {
      let attacksTarget: Bool
      switch piece.kind {
      case .pawn:
        let direction = piece.color == .white ? 1 : -1
        attacksTarget = origin.offset(file: -1, rank: direction) == target
          || origin.offset(file: 1, rank: direction) == target
      case .knight:
        let offsets = [
          (1, 2), (2, 1), (2, -1), (1, -2),
          (-1, -2), (-2, -1), (-2, 1), (-1, 2),
        ]
        attacksTarget = offsets.contains { origin.offset(file: $0.0, rank: $0.1) == target }
      case .bishop:
        attacksTarget = attacksAlongDirections(
          from: origin,
          target: target,
          directions: [(1, 1), (1, -1), (-1, -1), (-1, 1)]
        )
      case .rook:
        attacksTarget = attacksAlongDirections(
          from: origin,
          target: target,
          directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]
        )
      case .queen:
        attacksTarget = attacksAlongDirections(
          from: origin,
          target: target,
          directions: [
            (1, 1), (1, -1), (-1, -1), (-1, 1),
            (1, 0), (-1, 0), (0, 1), (0, -1),
          ]
        )
      case .king:
        attacksTarget = abs(origin.file - target.file) <= 1 && abs(origin.rank - target.rank) <= 1
      }

      if attacksTarget {
        origins.append(origin)
      }
    }

    return origins
  }

  func attackedSquares(from origin: BoardSquare) -> [BoardSquare] {
    guard let piece = board[origin] else {
      return []
    }

    switch piece.kind {
    case .pawn:
      let direction = piece.color == .white ? 1 : -1
      return [-1, 1].compactMap { origin.offset(file: $0, rank: direction) }
    case .knight:
      let offsets = [
        (1, 2), (2, 1), (2, -1), (1, -2),
        (-1, -2), (-2, -1), (-2, 1), (-1, 2),
      ]
      return offsets.compactMap { origin.offset(file: $0.0, rank: $0.1) }
    case .bishop:
      return attackedSquaresAlongDirections(
        from: origin,
        attackerColor: piece.color,
        directions: [(1, 1), (1, -1), (-1, -1), (-1, 1)]
      )
    case .rook:
      return attackedSquaresAlongDirections(
        from: origin,
        attackerColor: piece.color,
        directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]
      )
    case .queen:
      return attackedSquaresAlongDirections(
        from: origin,
        attackerColor: piece.color,
        directions: [
          (1, 1), (1, -1), (-1, -1), (-1, 1),
          (1, 0), (-1, 0), (0, 1), (0, -1),
        ]
      )
    case .king:
      var squares: [BoardSquare] = []
      for deltaFile in -1...1 {
        for deltaRank in -1...1 {
          guard deltaFile != 0 || deltaRank != 0,
                let target = origin.offset(file: deltaFile, rank: deltaRank) else {
            continue
          }
          squares.append(target)
        }
      }
      return squares
    }
  }

  func longestSlidingAttackRayLength(from origin: BoardSquare) -> Int {
    guard let piece = board[origin] else {
      return 0
    }

    let directions: [(Int, Int)]
    switch piece.kind {
    case .bishop:
      directions = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    case .rook:
      directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    case .queen:
      directions = [
        (1, 1), (1, -1), (-1, -1), (-1, 1),
        (1, 0), (-1, 0), (0, 1), (0, -1),
      ]
    default:
      return 0
    }

    return directions.map {
      attackSquaresAlongRay(from: origin, attackerColor: piece.color, direction: $0).count
    }.max() ?? 0
  }

  private func attackedSquaresAlongDirections(
    from origin: BoardSquare,
    attackerColor: ChessColor,
    directions: [(Int, Int)]
  ) -> [BoardSquare] {
    directions.flatMap { attackSquaresAlongRay(from: origin, attackerColor: attackerColor, direction: $0) }
  }

  private func attackSquaresAlongRay(
    from origin: BoardSquare,
    attackerColor: ChessColor,
    direction: (Int, Int)
  ) -> [BoardSquare] {
    var squares: [BoardSquare] = []
    var current = origin

    while let next = current.offset(file: direction.0, rank: direction.1) {
      if let occupant = board[next] {
        if occupant.color != attackerColor {
          squares.append(next)
        }
        break
      }
      squares.append(next)
      current = next
    }

    return squares
  }

  func isPiecePinned(at square: BoardSquare) -> Bool {
    guard let piece = board[square],
          piece.kind != .king,
          let ownKing = kingSquare(for: piece.color) else {
      return false
    }

    let deltaFile = square.file - ownKing.file
    let deltaRank = square.rank - ownKing.rank
    guard deltaFile == 0 || deltaRank == 0 || abs(deltaFile) == abs(deltaRank) else {
      return false
    }

    let stepFile = deltaFile == 0 ? 0 : deltaFile / abs(deltaFile)
    let stepRank = deltaRank == 0 ? 0 : deltaRank / abs(deltaRank)

    var current = ownKing
    while let next = current.offset(file: stepFile, rank: stepRank) {
      current = next
      if next == square {
        break
      }
      if board[next] != nil {
        return false
      }
    }

    guard current == square else {
      return false
    }

    while let next = current.offset(file: stepFile, rank: stepRank) {
      current = next
      guard let occupant = board[next] else {
        continue
      }
      guard occupant.color == piece.color.opponent else {
        return false
      }

      switch occupant.kind {
      case .queen:
        return true
      case .rook:
        return stepFile == 0 || stepRank == 0
      case .bishop:
        return abs(stepFile) == 1 && abs(stepRank) == 1
      default:
        return false
      }
    }

    return false
  }

  private func legalMoves(from square: BoardSquare, for color: ChessColor) -> [ChessMove] {
    guard let piece = board[square], piece.color == color else {
      return []
    }

    return pseudoLegalMoves(from: square, piece: piece).filter { move in
      !applying(move).isInCheck(for: color)
    }
  }

  private func pseudoLegalMoves(from square: BoardSquare, piece: ChessPieceState) -> [ChessMove] {
    switch piece.kind {
    case .pawn:
      return pawnMoves(from: square, piece: piece)
    case .knight:
      return stepMoves(
        from: square,
        piece: piece,
        deltas: [
          (1, 2), (2, 1), (2, -1), (1, -2),
          (-1, -2), (-2, -1), (-2, 1), (-1, 2),
        ]
      )
    case .bishop:
      return slidingMoves(
        from: square,
        piece: piece,
        directions: [(1, 1), (1, -1), (-1, -1), (-1, 1)]
      )
    case .rook:
      return slidingMoves(
        from: square,
        piece: piece,
        directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]
      )
    case .queen:
      return slidingMoves(
        from: square,
        piece: piece,
        directions: [
          (1, 1), (1, -1), (-1, -1), (-1, 1),
          (1, 0), (-1, 0), (0, 1), (0, -1),
        ]
      )
    case .king:
      return kingMoves(from: square, piece: piece)
    }
  }

  private func pawnMoves(from square: BoardSquare, piece: ChessPieceState) -> [ChessMove] {
    let direction = piece.color == .white ? 1 : -1
    let startRank = piece.color == .white ? 1 : 6
    let promotionRank = piece.color == .white ? 7 : 0
    var moves: [ChessMove] = []

    if let oneForward = square.offset(file: 0, rank: direction), board[oneForward] == nil {
      moves.append(
        ChessMove(
          from: square,
          to: oneForward,
          piece: piece,
          captured: nil,
          isEnPassant: false,
          rookMove: nil,
          promotion: oneForward.rank == promotionRank ? .queen : nil
        )
      )

      if square.rank == startRank,
         let twoForward = square.offset(file: 0, rank: direction * 2),
         board[twoForward] == nil {
        moves.append(ChessMove(from: square, to: twoForward, piece: piece))
      }
    }

    for deltaFile in [-1, 1] {
      guard let target = square.offset(file: deltaFile, rank: direction) else {
        continue
      }

      if let captured = board[target], captured.color != piece.color {
        moves.append(
          ChessMove(
            from: square,
            to: target,
            piece: piece,
            captured: captured,
            isEnPassant: false,
            rookMove: nil,
            promotion: target.rank == promotionRank ? .queen : nil
          )
        )
      } else if target == enPassantTarget {
        let capturedSquare = BoardSquare(file: target.file, rank: square.rank)
        if let captured = board[capturedSquare], captured.color != piece.color, captured.kind == .pawn {
          moves.append(
            ChessMove(
              from: square,
              to: target,
              piece: piece,
              captured: captured,
              isEnPassant: true,
              rookMove: nil,
              promotion: nil
            )
          )
        }
      }
    }

    return moves
  }

  private func stepMoves(
    from square: BoardSquare,
    piece: ChessPieceState,
    deltas: [(Int, Int)]
  ) -> [ChessMove] {
    deltas.compactMap { deltaFile, deltaRank in
      guard let target = square.offset(file: deltaFile, rank: deltaRank) else {
        return nil
      }

      if let occupant = board[target] {
        guard occupant.color != piece.color else {
          return nil
        }

        return ChessMove(from: square, to: target, piece: piece, captured: occupant)
      }

      return ChessMove(from: square, to: target, piece: piece)
    }
  }

  private func slidingMoves(
    from square: BoardSquare,
    piece: ChessPieceState,
    directions: [(Int, Int)]
  ) -> [ChessMove] {
    var moves: [ChessMove] = []

    for (deltaFile, deltaRank) in directions {
      var current = square

      while let next = current.offset(file: deltaFile, rank: deltaRank) {
        if let occupant = board[next] {
          if occupant.color != piece.color {
            moves.append(ChessMove(from: square, to: next, piece: piece, captured: occupant))
          }
          break
        }

        moves.append(ChessMove(from: square, to: next, piece: piece))
        current = next
      }
    }

    return moves
  }

  private func kingMoves(from square: BoardSquare, piece: ChessPieceState) -> [ChessMove] {
    var moves = stepMoves(
      from: square,
      piece: piece,
      deltas: [
        (-1, -1), (-1, 0), (-1, 1),
        (0, -1),           (0, 1),
        (1, -1),  (1, 0),  (1, 1),
      ]
    )

    guard !isInCheck(for: piece.color) else {
      return moves
    }

    let homeRank = piece.color == .white ? 0 : 7
    let kingsideRookSquare = BoardSquare(file: 7, rank: homeRank)
    let queensideRookSquare = BoardSquare(file: 0, rank: homeRank)
    let kingStartSquare = BoardSquare(file: 4, rank: homeRank)

    guard square == kingStartSquare else {
      return moves
    }

    let opponent = piece.color.opponent

    if canCastleKingside(for: piece.color),
       board[BoardSquare(file: 5, rank: homeRank)] == nil,
       board[BoardSquare(file: 6, rank: homeRank)] == nil,
       board[kingsideRookSquare]?.kind == .rook,
       board[kingsideRookSquare]?.color == piece.color,
       !isSquareAttacked(BoardSquare(file: 5, rank: homeRank), by: opponent),
       !isSquareAttacked(BoardSquare(file: 6, rank: homeRank), by: opponent) {
      moves.append(
        ChessMove(
          from: square,
          to: BoardSquare(file: 6, rank: homeRank),
          piece: piece,
          captured: nil,
          isEnPassant: false,
          rookMove: (
            from: kingsideRookSquare,
            to: BoardSquare(file: 5, rank: homeRank)
          ),
          promotion: nil
        )
      )
    }

    if canCastleQueenside(for: piece.color),
       board[BoardSquare(file: 1, rank: homeRank)] == nil,
       board[BoardSquare(file: 2, rank: homeRank)] == nil,
       board[BoardSquare(file: 3, rank: homeRank)] == nil,
       board[queensideRookSquare]?.kind == .rook,
       board[queensideRookSquare]?.color == piece.color,
       !isSquareAttacked(BoardSquare(file: 3, rank: homeRank), by: opponent),
       !isSquareAttacked(BoardSquare(file: 2, rank: homeRank), by: opponent) {
      moves.append(
        ChessMove(
          from: square,
          to: BoardSquare(file: 2, rank: homeRank),
          piece: piece,
          captured: nil,
          isEnPassant: false,
          rookMove: (
            from: queensideRookSquare,
            to: BoardSquare(file: 3, rank: homeRank)
          ),
          promotion: nil
        )
      )
    }

    return moves
  }

  private func canCastleKingside(for color: ChessColor) -> Bool {
    switch color {
    case .white:
      return castlingRights.whiteKingside
    case .black:
      return castlingRights.blackKingside
    }
  }

  private func canCastleQueenside(for color: ChessColor) -> Bool {
    switch color {
    case .white:
      return castlingRights.whiteQueenside
    case .black:
      return castlingRights.blackQueenside
    }
  }

  private func isSquareAttacked(_ target: BoardSquare, by attacker: ChessColor) -> Bool {
    !attackOrigins(on: target, by: attacker).isEmpty
  }

  private func attacksAlongDirections(
    from origin: BoardSquare,
    target: BoardSquare,
    directions: [(Int, Int)]
  ) -> Bool {
    for (deltaFile, deltaRank) in directions {
      var current = origin

      while let next = current.offset(file: deltaFile, rank: deltaRank) {
        if next == target {
          return true
        }

        if board[next] != nil {
          break
        }

        current = next
      }
    }

    return false
  }

  private func sanDisambiguation(for move: ChessMove) -> String {
    let competingOrigins = board.compactMap { square, piece -> BoardSquare? in
      guard square != move.from,
            piece.color == move.piece.color,
            piece.kind == move.piece.kind else {
        return nil
      }

      let matchingMove = legalMoves(from: square).contains { candidate in
        candidate.to == move.to && candidate.promotion == move.promotion
      }
      return matchingMove ? square : nil
    }

    guard !competingOrigins.isEmpty else {
      return ""
    }

    let sameFileExists = competingOrigins.contains { $0.file == move.from.file }
    let sameRankExists = competingOrigins.contains { $0.rank == move.from.rank }
    let fileToken = String(move.from.algebraic.prefix(1))
    let rankToken = String(move.from.rank + 1)

    if !sameFileExists {
      return fileToken
    }
    if !sameRankExists {
      return rankToken
    }
    return fileToken + rankToken
  }

  private mutating func updateCastlingRights(for move: ChessMove) {
    if move.piece.kind == .king {
      switch move.piece.color {
      case .white:
        castlingRights.whiteKingside = false
        castlingRights.whiteQueenside = false
      case .black:
        castlingRights.blackKingside = false
        castlingRights.blackQueenside = false
      }
    }

    if move.piece.kind == .rook {
      revokeRookCastlingRight(at: move.from)
    }

    if move.captured?.kind == .rook, !move.isEnPassant {
      revokeRookCastlingRight(at: move.to)
    }
  }

  private mutating func revokeRookCastlingRight(at square: BoardSquare) {
    switch (square.file, square.rank) {
    case (0, 0):
      castlingRights.whiteQueenside = false
    case (7, 0):
      castlingRights.whiteKingside = false
    case (0, 7):
      castlingRights.blackQueenside = false
    case (7, 7):
      castlingRights.blackKingside = false
    default:
      break
    }
  }
}

private enum PieceRoleType: String {
  case employee
  case lazy
  case traitor
  case worker

  var displayName: String {
    switch self {
    case .employee:
      return "Employee of the Month"
    case .lazy:
      return "Lazy"
    case .traitor:
      return "Traitor"
    case .worker:
      return "Worker"
    }
  }
}

private struct PieceRoleAssignment {
  let pieceId: String
  let square: BoardSquare
  let piece: ChessPieceState
  let roleType: PieceRoleType
  let influenceCount: Int
  let attackedFriendlyPieceCount: Int
  let attacksKingZone: Bool
  let employeeThreatScoreHalfPoints: Int
}

private struct PieceRoleSnapshot {
  let currentPlayer: ChessColor
  let assignmentsBySquare: [BoardSquare: PieceRoleAssignment]
  let employeeOfTheMonthSquare: BoardSquare?

  static func empty(currentPlayer: ChessColor) -> PieceRoleSnapshot {
    PieceRoleSnapshot(
      currentPlayer: currentPlayer,
      assignmentsBySquare: [:],
      employeeOfTheMonthSquare: nil
    )
  }

  var employeeOfTheMonth: PieceRoleAssignment? {
    guard let employeeOfTheMonthSquare else {
      return nil
    }

    return assignmentsBySquare[employeeOfTheMonthSquare]
  }
}

private struct EmployeeThreatRating {
  let attackedFriendlyPieceCount: Int
  let attacksKingZone: Bool
  let homeHalfInfluenceCount: Int

  var scoreHalfPoints: Int {
    (attackedFriendlyPieceCount * 3) + (attacksKingZone ? 2 : 0) + homeHalfInfluenceCount
  }
}

private struct PieceRoleEvaluationCache {
  var influenceSquaresBySquare: [BoardSquare: [BoardSquare]] = [:]
  var legalMovesBySquare: [BoardSquare: [ChessMove]] = [:]
  var removedFriendlyPressureBySquare: [BoardSquare: Set<BoardSquare>] = [:]
}

extension ChessGameState {
  func evaluatePieceRolesRelativeToCurrentPlayer() -> PieceRoleSnapshot {
    let currentPlayer = turn
    let enemyColor = currentPlayer.opponent
    var assignmentsBySquare: [BoardSquare: PieceRoleAssignment] = [:]
    var cache = PieceRoleEvaluationCache()

    let baselineFriendlyPressure = pressuredSquaresOnEnemyHalf(
      for: currentPlayer,
      excluding: nil,
      cache: &cache
    )

    let enemyPieces = orderedPieces(for: enemyColor)
    let enemyThreatRatingsBySquare = Dictionary(
      uniqueKeysWithValues: enemyPieces.map { square, _ in
        (
          square,
          employeeThreatRating(
            for: square,
            defendingColor: currentPlayer,
            cache: &cache
          )
        )
      }
    )
    let employeeCandidate = enemyPieces
      .map { square, piece -> (square: BoardSquare, piece: ChessPieceState, rating: EmployeeThreatRating) in
        let rating = enemyThreatRatingsBySquare[square] ?? EmployeeThreatRating(
          attackedFriendlyPieceCount: 0,
          attacksKingZone: false,
          homeHalfInfluenceCount: 0
        )
        return (square, piece, rating)
      }
      .max { lhs, rhs in
        if lhs.rating.scoreHalfPoints != rhs.rating.scoreHalfPoints {
          return lhs.rating.scoreHalfPoints < rhs.rating.scoreHalfPoints
        }

        if lhs.rating.attackedFriendlyPieceCount != rhs.rating.attackedFriendlyPieceCount {
          return lhs.rating.attackedFriendlyPieceCount < rhs.rating.attackedFriendlyPieceCount
        }

        if lhs.rating.attacksKingZone != rhs.rating.attacksKingZone {
          return lhs.rating.attacksKingZone == false && rhs.rating.attacksKingZone == true
        }

        if lhs.rating.homeHalfInfluenceCount != rhs.rating.homeHalfInfluenceCount {
          return lhs.rating.homeHalfInfluenceCount < rhs.rating.homeHalfInfluenceCount
        }

        let lhsValue = lhs.piece.kind.strategicRoleTradeValue
        let rhsValue = rhs.piece.kind.strategicRoleTradeValue
        if lhsValue != rhsValue {
          return lhsValue < rhsValue
        }

        if lhs.square.rank != rhs.square.rank {
          return lhs.square.rank < rhs.square.rank
        }

        return lhs.square.file < rhs.square.file
      }

    let employeeSquare = employeeCandidate?.square
    for (square, piece) in enemyPieces {
      let rating = enemyThreatRatingsBySquare[square] ?? EmployeeThreatRating(
        attackedFriendlyPieceCount: 0,
        attacksKingZone: false,
        homeHalfInfluenceCount: 0
      )
      let influenceCount = rating.homeHalfInfluenceCount
      let roleType: PieceRoleType = square == employeeSquare ? .employee : .worker
      assignmentsBySquare[square] = PieceRoleAssignment(
        pieceId: rolePieceIdentifier(for: piece, at: square),
        square: square,
        piece: piece,
        roleType: roleType,
        influenceCount: influenceCount,
        attackedFriendlyPieceCount: rating.attackedFriendlyPieceCount,
        attacksKingZone: rating.attacksKingZone,
        employeeThreatScoreHalfPoints: rating.scoreHalfPoints
      )
    }

    for (square, piece) in orderedPieces(for: currentPlayer) {
      let enemyHalfInfluenceSquares = roleInfluenceSquares(from: square, cache: &cache)
        .filter { isOnEnemyHalf($0, for: currentPlayer) }
      let influenceCount = enemyHalfInfluenceSquares.count
      let roleType: PieceRoleType
      if isTraitorPiece(
        at: square,
        friendlyColor: currentPlayer,
        baselineFriendlyPressure: baselineFriendlyPressure,
        cache: &cache
      ) {
        roleType = .traitor
      } else if !enemyHalfInfluenceSquares.isEmpty {
        roleType = .worker
      } else if isLazyPiece(at: square, piece: piece, cache: &cache) {
        roleType = .lazy
      } else {
        roleType = .worker
      }

      assignmentsBySquare[square] = PieceRoleAssignment(
        pieceId: rolePieceIdentifier(for: piece, at: square),
        square: square,
        piece: piece,
        roleType: roleType,
        influenceCount: influenceCount,
        attackedFriendlyPieceCount: 0,
        attacksKingZone: false,
        employeeThreatScoreHalfPoints: 0
      )
    }

    return PieceRoleSnapshot(
      currentPlayer: currentPlayer,
      assignmentsBySquare: assignmentsBySquare,
      employeeOfTheMonthSquare: employeeSquare
    )
  }

  func influenceSquares(from origin: BoardSquare) -> [BoardSquare] {
    guard let piece = board[origin] else {
      return []
    }

    switch piece.kind {
    case .pawn:
      let direction = piece.color == .white ? 1 : -1
      return [-1, 1].compactMap { origin.offset(file: $0, rank: direction) }
    case .knight:
      let offsets = [
        (1, 2), (2, 1), (2, -1), (1, -2),
        (-1, -2), (-2, -1), (-2, 1), (-1, 2),
      ]
      return offsets.compactMap { origin.offset(file: $0.0, rank: $0.1) }
    case .bishop:
      return influenceSquaresAlongDirections(
        from: origin,
        directions: [(1, 1), (1, -1), (-1, -1), (-1, 1)]
      )
    case .rook:
      return influenceSquaresAlongDirections(
        from: origin,
        directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]
      )
    case .queen:
      return influenceSquaresAlongDirections(
        from: origin,
        directions: [
          (1, 1), (1, -1), (-1, -1), (-1, 1),
          (1, 0), (-1, 0), (0, 1), (0, -1),
        ]
      )
    case .king:
      var squares: [BoardSquare] = []
      for deltaFile in -1...1 {
        for deltaRank in -1...1 {
          guard deltaFile != 0 || deltaRank != 0,
                let target = origin.offset(file: deltaFile, rank: deltaRank) else {
            continue
          }
          squares.append(target)
        }
      }
      return squares
    }
  }

  private func orderedPieces(for color: ChessColor) -> [(BoardSquare, ChessPieceState)] {
    board
      .filter { $0.value.color == color }
      .sorted { lhs, rhs in
        if lhs.key.rank != rhs.key.rank {
          return lhs.key.rank < rhs.key.rank
        }
        return lhs.key.file < rhs.key.file
      }
      .map { ($0.key, $0.value) }
  }

  private func rolePieceIdentifier(for piece: ChessPieceState, at square: BoardSquare) -> String {
    "\(piece.color.fenSymbol)_\(piece.kind.fenSymbol)_\(square.algebraic)"
  }

  private func roleInfluenceSquares(
    from origin: BoardSquare,
    cache: inout PieceRoleEvaluationCache
  ) -> [BoardSquare] {
    if let cached = cache.influenceSquaresBySquare[origin] {
      return cached
    }

    let resolved = influenceSquares(from: origin)
    cache.influenceSquaresBySquare[origin] = resolved
    return resolved
  }

  private func roleLegalMoves(
    from origin: BoardSquare,
    cache: inout PieceRoleEvaluationCache
  ) -> [ChessMove] {
    if let cached = cache.legalMovesBySquare[origin] {
      return cached
    }

    let resolved = legalMoves(from: origin)
    cache.legalMovesBySquare[origin] = resolved
    return resolved
  }

  private func pressuredSquaresOnEnemyHalf(
    for color: ChessColor,
    excluding excludedSquare: BoardSquare?,
    cache: inout PieceRoleEvaluationCache
  ) -> Set<BoardSquare> {
    if let excludedSquare,
       let cached = cache.removedFriendlyPressureBySquare[excludedSquare] {
      return cached
    }

    let state = excludedSquare.map { removingPiece(at: $0) } ?? self
    var pressuredSquares = Set<BoardSquare>()

    for (square, piece) in state.orderedPieces(for: color) {
      let influenceSquares: [BoardSquare]
      if excludedSquare == nil {
        influenceSquares = roleInfluenceSquares(from: square, cache: &cache)
      } else {
        influenceSquares = state.influenceSquares(from: square)
      }

      for target in influenceSquares where state.isOnEnemyHalf(target, for: piece.color) {
        pressuredSquares.insert(target)
      }
    }

    if let excludedSquare {
      cache.removedFriendlyPressureBySquare[excludedSquare] = pressuredSquares
    }

    return pressuredSquares
  }

  private func employeeThreatRating(
    for attackerSquare: BoardSquare,
    defendingColor: ChessColor,
    cache: inout PieceRoleEvaluationCache
  ) -> EmployeeThreatRating {
    let attackedSquares = roleInfluenceSquares(from: attackerSquare, cache: &cache)
    let defendingKingZone = kingZone(for: defendingColor)
    let attackedFriendlyPieceCount = attackedSquares.reduce(into: 0) { count, square in
      guard let occupant = board[square], occupant.color == defendingColor else {
        return
      }
      count += 1
    }
    let homeHalfInfluenceCount = attackedSquares.filter { isOnHomeHalf($0, for: defendingColor) }.count
    let attacksKingZone = !defendingKingZone.isEmpty && attackedSquares.contains { defendingKingZone.contains($0) }

    return EmployeeThreatRating(
      attackedFriendlyPieceCount: attackedFriendlyPieceCount,
      attacksKingZone: attacksKingZone,
      homeHalfInfluenceCount: homeHalfInfluenceCount
    )
  }

  private func isLazyPiece(
    at square: BoardSquare,
    piece: ChessPieceState,
    cache: inout PieceRoleEvaluationCache
  ) -> Bool {
    let enemySideMoves = roleLegalMoves(from: square, cache: &cache)
      .filter { isOnEnemyHalf($0.to, for: piece.color) }
    guard !enemySideMoves.isEmpty else {
      return true
    }

    let movingValue = piece.kind.strategicRoleTradeValue
    for move in enemySideMoves {
      let defendedByEqualOrLowerValueEnemy = attackOrigins(on: move.to, by: piece.color.opponent)
        .contains { defenderSquare in
          guard let defender = board[defenderSquare] else {
            return false
          }

          return defender.kind.strategicRoleTradeValue <= movingValue
        }

      if !defendedByEqualOrLowerValueEnemy {
        return false
      }
    }

    return true
  }

  private func isTraitorPiece(
    at square: BoardSquare,
    friendlyColor: ChessColor,
    baselineFriendlyPressure: Set<BoardSquare>,
    cache: inout PieceRoleEvaluationCache
  ) -> Bool {
    let pressureWithoutPiece = pressuredSquaresOnEnemyHalf(
      for: friendlyColor,
      excluding: square,
      cache: &cache
    )
    return pressureWithoutPiece.count > baselineFriendlyPressure.count
  }

  private func isOnEnemyHalf(_ square: BoardSquare, for color: ChessColor) -> Bool {
    switch color {
    case .white:
      return square.rank >= 4
    case .black:
      return square.rank <= 3
    }
  }

  private func isOnHomeHalf(_ square: BoardSquare, for color: ChessColor) -> Bool {
    !isOnEnemyHalf(square, for: color)
  }

  private func kingZone(for color: ChessColor) -> Set<BoardSquare> {
    guard let kingSquare = kingSquare(for: color) else {
      return []
    }

    var zone: Set<BoardSquare> = [kingSquare]
    for deltaFile in -1...1 {
      for deltaRank in -1...1 {
        guard deltaFile != 0 || deltaRank != 0,
              let target = kingSquare.offset(file: deltaFile, rank: deltaRank) else {
          continue
        }
        zone.insert(target)
      }
    }

    return zone
  }

  private func removingPiece(at square: BoardSquare) -> ChessGameState {
    var next = self
    next.board[square] = nil
    return next
  }

  private func influenceSquaresAlongDirections(
    from origin: BoardSquare,
    directions: [(Int, Int)]
  ) -> [BoardSquare] {
    directions.flatMap { influenceSquaresAlongRay(from: origin, direction: $0) }
  }

  private func influenceSquaresAlongRay(
    from origin: BoardSquare,
    direction: (Int, Int)
  ) -> [BoardSquare] {
    var squares: [BoardSquare] = []
    var current = origin

    while let next = current.offset(file: direction.0, rank: direction.1) {
      squares.append(next)
      if board[next] != nil {
        break
      }
      current = next
    }

    return squares
  }
}

private struct NativeARView: UIViewRepresentable {
  @ObservedObject var matchLog: MatchLogStore
  @ObservedObject var queueMatch: QueueMatchStore
  let mode: ExperienceMode
  @ObservedObject var commentary: PiecePersonalityDirector
  @ObservedObject var gameReview: GameReviewStore
  @ObservedObject var lessonStore: OpeningLessonStore
  @ObservedObject var socraticCoach: SocraticCoachStore
  @ObservedObject var fishing: FishingInteractionStore
  @ObservedObject var pieceRoles: PieceRoleStore
  let onReviewFinished: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      matchLog: matchLog,
      queueMatch: queueMatch,
      mode: mode,
      commentary: commentary,
      gameReview: gameReview,
      lessonStore: lessonStore,
      socraticCoach: socraticCoach,
      fishing: fishing,
      pieceRoles: pieceRoles,
      onReviewFinished: onReviewFinished
    )
  }

  func makeUIView(context: Context) -> ARView {
    let arView = ARView(frame: .zero)
    context.coordinator.configure(arView)
    return arView
  }

  func updateUIView(_ uiView: ARView, context: Context) {
    context.coordinator.syncRuntimeState(queueAssignedColor: queueMatch.assignedColor)
  }

  @MainActor
  final class Coordinator: NSObject, ARSessionDelegate {
    private struct NarrativeMove {
      let ply: Int
      let san: String
    }

    private struct PiecePrototypeKey: Hashable {
      let kind: ChessPieceKind
      let color: ChessColor
      let isGhost: Bool
    }

    private struct AnimatedMoveContext {
      let move: ChessMove
      let beforeState: ChessGameState
      let afterState: ChessGameState
      let postApply: (@MainActor () async -> Void)?
    }

    private struct ActiveKnightForkBinding {
      let targetSquares: [BoardSquare]
      let clearsOnMoveBy: ChessColor
    }

    private struct ActivePieceDrag {
      let originSquare: BoardSquare
      let legalMoves: [ChessMove]
      var previewSquare: BoardSquare?
    }

    private enum FishingHandSide {
      case left
      case right
    }

    private enum PieceAccessoryHandSide {
      case left
      case right
    }

    private static let boardTemplateSize: Float = 0.40
    private static let boardSquareSize: Float = boardTemplateSize / 8.0
    private static let fishingPondVerticalOffset: Float = -0.068
    private static let fishingLookAlignmentThreshold: Float = 0.945
    private static let fishingPondFocusDistance: Float = 4.0
    private static let fishingBiteDelayRangeSeconds: ClosedRange<Double> = 5.0...10.0
    private static let fishingCatchWindowSeconds: TimeInterval = 1.85
    private static let fishingRigBasePosition = SIMD3<Float>(0.0, -0.25, -0.60)
    private static let fishingRigBasePitch: Float = 0
    private static let fishingRigBaseYaw: Float = 0
    private static let fishingRigBaseRoll: Float = 0
    private static let fishingRigRelativePitchDeltaMin: Float = 0
    private static let fishingRigRelativePitchDeltaMax: Float = 0.18
    private static let fishingTerrainPlaneLocalY: Float = -0.041
    private static let fishingRigGroundClearance: Float = 0.012
    private static let fishingRigMinimumCameraUpComponent: Float = 0.22
    private static let boardBaseMesh = MeshResource.generateBox(
      size: SIMD3<Float>(boardTemplateSize + 0.03, 0.012, boardTemplateSize + 0.03)
    )
    private static let boardBaseMaterial = SimpleMaterial(
      color: UIColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 1),
      roughness: 0.65,
      isMetallic: false
    )
    private static let boardSquareMesh = MeshResource.generateBox(
      size: SIMD3<Float>(boardSquareSize, 0.004, boardSquareSize)
    )
    private static let scenicSkyColor = UIColor(red: 0.55, green: 0.78, blue: 0.98, alpha: 1)
    private static let darkSquareMaterial = SimpleMaterial(
      color: UIColor(red: 0.22, green: 0.18, blue: 0.15, alpha: 1),
      roughness: 0.35,
      isMetallic: false
    )
    private static let lightSquareMaterial = SimpleMaterial(
      color: UIColor(red: 0.93, green: 0.88, blue: 0.79, alpha: 1),
      roughness: 0.35,
      isMetallic: false
    )
    private static let boardBasePrototype: ModelEntity = {
      ModelEntity(mesh: boardBaseMesh, materials: [boardBaseMaterial])
    }()
    private static let darkSquarePrototype: ModelEntity = {
      let entity = ModelEntity(mesh: boardSquareMesh, materials: [darkSquareMaterial])
      entity.generateCollisionShapes(recursive: false)
      return entity
    }()
    private static let lightSquarePrototype: ModelEntity = {
      let entity = ModelEntity(mesh: boardSquareMesh, materials: [lightSquareMaterial])
      entity.generateCollisionShapes(recursive: false)
      return entity
    }()
    private static var piecePrototypeCache: [PiecePrototypeKey: Entity] = [:]

    private let boardSize: Float = 0.40
    private let boardInset: Float = 0.035
    private let minimumBoardScale: Float = 0.72
    private let maximumBoardScale: Float = 2.4
    private let strongMoveAttackHighlightMaxRank = 3
    private let strongMoveAttackHighlightMinSlidingLength = 4
    private static let brilliantAnimation = GIFAnimationSequence.loadFromBundle(named: "brilliant", withExtension: "gif")
    private let matchLog: MatchLogStore
    private let queueMatch: QueueMatchStore
    private let mode: ExperienceMode
    private let commentary: PiecePersonalityDirector
    private let gameReview: GameReviewStore
    private let lessonStore: OpeningLessonStore
    private let socraticCoach: SocraticCoachStore
    private let fishing: FishingInteractionStore
    private let pieceRoles: PieceRoleStore
    private let onReviewFinished: () -> Void
    private weak var arView: ARView?
    private var boardAnchor: AnchorEntity?
    private var boardWorldTransform: simd_float4x4?
    private var boardRoot = Entity()
    private var hasPreparedBoardScene = false
    private var boardScale: Float = 1.0
    private var boardViewerColor: ChessColor = .black
    private var pinchStartScale: Float = 1.0
    private var piecesContainer = Entity()
    private var captureGhostContainer = Entity()
    private var highlightsContainer = Entity()
    private var threatOverlayContainer = Entity()
    private var activeThreatSquares: [BoardSquare] = []
    private var persistentThreatSquares: [BoardSquare] = []
    private var speakingPieceHighlightSquare: BoardSquare?
    private var wantedPosterHighlightSquare: BoardSquare?
    private var activeThreatEntities: [ModelEntity] = []
    private var threatOverlayDisplayLink: CADisplayLink?
    private var threatOverlayHideWorkItem: DispatchWorkItem?
    private var trackedPlaneID: UUID?
    private var gameState = ChessGameState.initial() {
      didSet {
        recalculatePieceRoles()
      }
    }
    private var pieceRoleSnapshot = PieceRoleSnapshot.empty(currentPlayer: .white)
    private var selectedSquare: BoardSquare?
    private var selectedMoves: [ChessMove] = []
    private var activePieceDrag: ActivePieceDrag?
    private var syncedQueueMoves: [QueueMatchMovePayload] = []
    private var queueAssignedColor: ChessColor?
    private var hasBoundReactionHandler = false
    private var stableTrackingFrames = 0
    private var hasScheduledInitialAnalysis = false
    private var initialAnalysisTask: Task<Void, Never>?
    private var lastWarmupStatusMessage: String?
    private var pendingAnimatedMoves: [AnimatedMoveContext] = []
    private var moveAnimationTask: Task<Void, Never>?
    private var narrativeHistory: [NarrativeMove] = []
    private let captureSoundEffects = CaptureSoundEffectEngine()
    private var activeKnightForkBinding: ActiveKnightForkBinding?
    private weak var brilliantMarkerView: UIImageView?
    private var brilliantMarkerPieceName: String?
    private var brilliantMarkerDisplayLink: CADisplayLink?
    private var brilliantMarkerHideWorkItem: DispatchWorkItem?
    private var knightCameraSplatAnchor: AnchorEntity?
    private weak var knightCameraSplatEntity: Entity?
    private var knightCameraSplatHideWorkItem: DispatchWorkItem?
    private var knightCameraSplatStartTime: CFTimeInterval?
    private weak var fishingPondEntity: Entity?
    private weak var fishingPondWaterEntity: Entity?
    private weak var fishingPondFinEntity: Entity?
    private var fishingRodAnchor: AnchorEntity?
    private weak var fishingRigEntity: Entity?
    private weak var fishingRodEntity: Entity?
    private weak var fishingLeftHandEntity: Entity?
    private weak var fishingRightHandEntity: Entity?
    private weak var fishingRodTipEntity: Entity?
    private var baselineFishingOrientation: simd_float4x4?
    private var baselineFishingDownwardPitch: Float?
    private var fishingCastLineAnchor: AnchorEntity?
    private weak var fishingCastLineEntity: ModelEntity?
    private var fishingBobberAnchor: AnchorEntity?
    private weak var fishingBobberEntity: ModelEntity?
    private var fishingFishAnchor: AnchorEntity?
    private weak var fishingFishEntity: Entity?
    private var fishingFishFloatStartedAt: CFTimeInterval?
    private var fishingBiteTask: Task<Void, Never>?
    private var fishingCatchWindowTask: Task<Void, Never>?
    private var fishingRevealTask: Task<Void, Never>?
    private var fishingResetTask: Task<Void, Never>?
    private var fishingBobberCastCompletedAt: CFTimeInterval?
    private var fishingSequenceID = 0
    private var fishingPondFinTravelStartedAt: CFTimeInterval = 0
    private var fishingPondFinTravelDuration: Float = 0
    private var fishingPondFinStartLocalPosition = SIMD3<Float>(0, 0.031, 0)
    private var fishingPondFinTargetLocalPosition = SIMD3<Float>(0, 0.031, 0)
    private let upwardFlickDetector = UpwardFlickDetector()
    private var liveEngineTask: Task<Void, Never>?
    private var reviewEngineTask: Task<Void, Never>?
    private var hasTriggeredPostGameFlow = false
    private var loadedReviewCheckpointID: UUID?
    private var loadedReviewReloadVersion = 0
    private var loadedLessonReloadVersion = 0
    private var lastLessonMoveRevealState = false
    private var lastLessonIntroNarrationKey: String?

    init(
      matchLog: MatchLogStore,
      queueMatch: QueueMatchStore,
      mode: ExperienceMode,
      commentary: PiecePersonalityDirector,
      gameReview: GameReviewStore,
      lessonStore: OpeningLessonStore,
      socraticCoach: SocraticCoachStore,
      fishing: FishingInteractionStore,
      pieceRoles: PieceRoleStore,
      onReviewFinished: @escaping () -> Void
    ) {
      self.matchLog = matchLog
      self.queueMatch = queueMatch
      self.mode = mode
      self.commentary = commentary
      self.gameReview = gameReview
      self.lessonStore = lessonStore
      self.socraticCoach = socraticCoach
      self.fishing = fishing
      self.pieceRoles = pieceRoles
      self.onReviewFinished = onReviewFinished

      switch mode {
      case .lesson(let lesson):
        if let startingFEN = lesson.steps.first?.startingFEN,
           let restoredState = try? ChessGameState(fen: startingFEN) {
          self.gameState = restoredState
        }
      case .playVsStockfish(let configuration):
        if let startingFEN = configuration.startingFEN,
           let restoredState = try? ChessGameState(fen: startingFEN) {
          self.gameState = restoredState
        }
      case .passAndPlay, .queueMatch:
        break
      }
    }

    deinit {
      initialAnalysisTask?.cancel()
      moveAnimationTask?.cancel()
      liveEngineTask?.cancel()
      reviewEngineTask?.cancel()
      brilliantMarkerDisplayLink?.invalidate()
      brilliantMarkerHideWorkItem?.cancel()
      knightCameraSplatHideWorkItem?.cancel()
      knightCameraSplatAnchor?.removeFromParent()
      fishingBiteTask?.cancel()
      fishingCatchWindowTask?.cancel()
      fishingRevealTask?.cancel()
      fishingResetTask?.cancel()
      fishingRodAnchor?.removeFromParent()
      fishingCastLineAnchor?.removeFromParent()
      fishingBobberAnchor?.removeFromParent()
      fishingFishAnchor?.removeFromParent()
      upwardFlickDetector.stop()
      threatOverlayDisplayLink?.invalidate()
      threatOverlayHideWorkItem?.cancel()
      AmbientMusicController.shared.stop()
    }

    func configure(_ arView: ARView) {
      self.arView = arView
      fishing.bindCastHandler { [weak self] in
        Task { @MainActor [weak self] in
          self?.beginFishingInteraction()
        }
      }
      pieceRoles.bindEmployeeHighlightHandler { [weak self] in
        Task { @MainActor [weak self] in
          self?.highlightEmployeeOfTheMonth()
        }
      }
      fishing.bindDismissNoteHandler { [weak self] in
        Task { @MainActor [weak self] in
          self?.dismissFishingRewardNote()
        }
      }
      upwardFlickDetector.onUpwardFlick = { [weak self] in
        Task { @MainActor [weak self] in
          self?.handleFishingCatchFlick()
        }
      }
      upwardFlickDetector.start()
      socraticCoach.bindThreatZoneHandler { [weak self] squares, _ in
        self?.showThreatOverlay(algebraicSquares: squares)
      }
      socraticCoach.bindMoveHandler { [weak self] uci, _ in
        self?.applyVoiceCommandMove(uci)
      }
      socraticCoach.bindDirectVoiceCommandHandler { [weak self] transcript in
        self?.applyDirectVoiceCommand(transcript)
      }
      arView.automaticallyConfigureSession = false
      applySceneBackground(for: arView)
      arView.renderOptions.insert(.disableMotionBlur)
      arView.renderOptions.insert(.disableAREnvironmentLighting)
      arView.renderOptions.insert(.disableGroundingShadows)
      Task { @MainActor [weak self] in
        self?.commentary.attachEngineHost(to: arView)
        if self?.mode.warmsStockfishAnalysis == true {
          self?.commentary.prepareEngineIfNeeded()
        }
      }
      captureSoundEffects.prewarmIfNeeded()
      noteWarmupStatus(
        mode.warmsStockfishAnalysis
          ? "Scanning for board placement. Local Stockfish is warming in the background..."
          : "Waiting for board placement to start the lesson..."
      )
      if case .playVsStockfish(let configuration) = mode {
        commentary.noteExternalStatus(configuration.statusSummary)
      } else if case .lesson(let lesson) = mode {
        commentary.noteExternalStatus(lesson.summary)
      }

      let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      arView.addGestureRecognizer(tapRecognizer)

      let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      panRecognizer.maximumNumberOfTouches = 1
      tapRecognizer.require(toFail: panRecognizer)
      arView.addGestureRecognizer(panRecognizer)

      let pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      arView.addGestureRecognizer(pinchRecognizer)

      guard ARWorldTrackingConfiguration.isSupported else {
        return
      }

      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.environmentTexturing = .none
      configuration.sceneReconstruction = []
      arView.environment.sceneUnderstanding.options = []

      if let lowerPowerFormat = Self.preferredVideoFormat() {
        configuration.videoFormat = lowerPowerFormat
      }

      arView.session.delegate = self
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

      DispatchQueue.main.async { [weak self] in
        self?.prepareBoardSceneIfNeeded()
      }

      if !hasBoundReactionHandler {
        hasBoundReactionHandler = true
        Task { @MainActor [weak self] in
          guard let self else {
            return
          }

          self.commentary.bindReactionHandler { [weak self] cue in
            self?.handleReactionCue(cue)
          }
          self.commentary.bindNarrationHighlightHandler { [weak self] squares, reason in
            guard let self else {
              return
            }
            if reason == "Speaking piece" {
              self.setSpeakingPieceHighlight(algebraicSquares: squares)
            } else {
              self.showThreatOverlay(algebraicSquares: squares)
            }
          }
          self.commentary.bindPieceAudioBusyDurationProvider { [weak self] in
            self?.captureSoundEffects.remainingPlaybackTime() ?? 0
          }
          self.commentary.bindStateProvider { [weak self] in
            self?.gameState
          }
          self.commentary.bindRecentHistoryProvider { [weak self] in
            self?.recentNarrativeSequence()
          }
          self.commentary.bindHintAvailabilityProvider { [weak self] in
            guard let self else {
              return false
            }

            switch self.mode {
            case .lesson:
              return false
            case .passAndPlay(_):
              return true
            case .queueMatch:
              return self.queueAssignedColor == self.gameState.turn
            case .playVsStockfish(let configuration):
              return self.gameState.turn == configuration.humanColor
            }
          }
          self.commentary.bindPassiveCommentarySuppressionProvider { [weak self] in
            self?.socraticCoach.blocksPassiveCommentary ?? false
          }
          if self.mode.supportsPassiveAutomaticCommentary {
            self.commentary.maybeStartOpeningNarration(for: self.gameState)
          }
        }
      }

      if case .queueMatch = mode {
        Task { @MainActor [weak self] in
          guard let self else {
            return
          }

          self.queueAssignedColor = self.queueMatch.assignedColor
          self.queueMatch.bindBoardSync { [weak self] moves in
            guard let self else {
              return
            }

            Task { @MainActor [weak self] in
              self?.queueAssignedColor = self?.queueMatch.assignedColor
            }
            self.applyServerMoveSet(moves)
          }
        }
      }

      let coachingOverlay = ARCoachingOverlayView()
      coachingOverlay.session = arView.session
      coachingOverlay.goal = .horizontalPlane
      coachingOverlay.activatesAutomatically = true
      coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
      arView.addSubview(coachingOverlay)

      NSLayoutConstraint.activate([
        coachingOverlay.topAnchor.constraint(equalTo: arView.topAnchor),
        coachingOverlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
        coachingOverlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
        coachingOverlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
      ])

      syncSocraticCoachContext(force: true)
      recalculatePieceRoles()
    }

    private static func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
      let formats = ARWorldTrackingConfiguration.supportedVideoFormats
      let lowerPower30fps = formats
        .filter { $0.framesPerSecond == 30 }
        .sorted { lhs, rhs in
          let lhsPixels = lhs.imageResolution.width * lhs.imageResolution.height
          let rhsPixels = rhs.imageResolution.width * rhs.imageResolution.height
          return lhsPixels < rhsPixels
        }
        .first

      return lowerPower30fps ?? formats.min { lhs, rhs in
        let lhsScore = CGFloat(lhs.framesPerSecond) * lhs.imageResolution.width * lhs.imageResolution.height
        let rhsScore = CGFloat(rhs.framesPerSecond) * rhs.imageResolution.width * rhs.imageResolution.height
        return lhsScore < rhsScore
      }
    }

    func syncRuntimeState(queueAssignedColor: ChessColor?) {
      self.queueAssignedColor = queueAssignedColor
      syncLessonStateIfNeeded()
      syncLessonRevealPresentationIfNeeded()
      syncBoardPerspectiveIfNeeded()
      syncLessonAutoplayIfNeeded()
      syncReviewStateIfNeeded()
      syncAutomatedOpponentTurnIfNeeded()
      syncSocraticCoachContext()
      if boardAnchor == nil {
        prepareBoardSceneIfNeeded()
      }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      Task { @MainActor [weak self] in
        self?.updateBoardPlacement(session: session, anchors: anchors)
      }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      Task { @MainActor [weak self] in
        self?.updateBoardPlacement(session: session, anchors: anchors)
      }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
      Task { @MainActor [weak self] in
        self?.updateTrackingReadiness(frame)
        self?.updateKnightCameraSplatIfNeeded(frame)
        self?.updateFishingInteraction(frame)
      }
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard !gameReview.isLoading else {
        return
      }

      guard moveAnimationTask == nil, pendingAnimatedMoves.isEmpty else {
        return
      }

      guard let arView else {
        return
      }

      let location = recognizer.location(in: arView)

      if let entity = arView.entity(at: location) {
        if handleFishingEntityTap(entity) {
          return
        }

        if let square = square(for: entity, prefix: "piece") {
          handleTapOnPiece(at: square)
          return
        }

        if let square = square(for: entity, prefix: "square") {
          handleTapOnSquare(square)
          return
        }
      }

      guard let square = boardSquare(at: location, in: arView) else {
        clearSelection()
        return
      }

      if gameState.piece(at: square) != nil {
        handleTapOnPiece(at: square)
      } else {
        handleTapOnSquare(square)
      }
    }

    private func handleFishingEntityTap(_ entity: Entity) -> Bool {
      guard fishing.canRevealRewardFromFish,
            fishingFishRoot(for: entity) != nil else {
        return false
      }

      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      fishing.revealArmedRewardNote()
      return true
    }

    @objc
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard !gameReview.isLoading else {
        return
      }

      guard moveAnimationTask == nil, pendingAnimatedMoves.isEmpty else {
        cancelPieceDrag()
        return
      }

      guard let arView else {
        cancelPieceDrag()
        return
      }

      let location = recognizer.location(in: arView)

      switch recognizer.state {
      case .began:
        beginPieceDrag(at: location, in: arView)
      case .changed:
        updatePieceDrag(at: location, in: arView)
      case .ended:
        endPieceDrag()
      case .cancelled, .failed:
        cancelPieceDrag()
      default:
        break
      }
    }

    @objc
    private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard boardAnchor != nil else {
        return
      }

      switch recognizer.state {
      case .began:
        pinchStartScale = boardScale
      case .changed, .ended:
        let nextScale = clamp(pinchStartScale * Float(recognizer.scale), min: minimumBoardScale, max: maximumBoardScale)
        guard abs(nextScale - boardScale) > 0.0001 else {
          return
        }

        boardScale = nextScale
        applyBoardScale()
      default:
        break
      }
    }

    private func beginPieceDrag(at location: CGPoint, in arView: ARView) {
      guard let entity = arView.entity(at: location),
            let square = square(for: entity, prefix: "piece"),
            let piece = gameState.piece(at: square),
            canControlPiece(piece, at: square) else {
        activePieceDrag = nil
        return
      }

      select(square)
      guard !selectedMoves.isEmpty else {
        activePieceDrag = nil
        return
      }

      activePieceDrag = ActivePieceDrag(originSquare: square, legalMoves: selectedMoves, previewSquare: nil)
      updatePieceDrag(at: location, in: arView)
    }

    private func updatePieceDrag(at location: CGPoint, in arView: ARView) {
      guard var activePieceDrag else {
        return
      }

      activePieceDrag.previewSquare = previewDestinationSquare(
        for: location,
        in: arView,
        originSquare: activePieceDrag.originSquare,
        legalMoves: activePieceDrag.legalMoves
      )
      self.activePieceDrag = activePieceDrag
      refreshBoardPresentation()
    }

    private func endPieceDrag() {
      guard let activePieceDrag else {
        return
      }

      let move = activePieceDrag.previewSquare.flatMap { destination in
        activePieceDrag.legalMoves.first(where: { $0.to == destination })
      }
      self.activePieceDrag = nil

      if let move {
        apply(move)
      } else {
        clearSelection()
      }
    }

    private func cancelPieceDrag() {
      guard activePieceDrag != nil else {
        return
      }

      activePieceDrag = nil
      clearSelection()
    }

    private func boardLocalPoint(at location: CGPoint, in arView: ARView) -> SIMD2<Float>? {
      guard let boardWorldTransform else {
        return nil
      }

      let hitResults = arView.raycast(from: location, allowing: .existingPlaneInfinite, alignment: .horizontal)
      guard let hit = hitResults.first else {
        return nil
      }

      let worldPoint = SIMD3<Float>(
        hit.worldTransform.columns.3.x,
        hit.worldTransform.columns.3.y,
        hit.worldTransform.columns.3.z
      )
      let localPoint4 = boardWorldTransform.inverse * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
      return SIMD2<Float>(localPoint4.x / boardScale, localPoint4.z / boardScale)
    }

    private func boardSquare(forBoardLocalPoint localPoint: SIMD2<Float>) -> BoardSquare? {
      let localX = localPoint.x
      let localZ = localPoint.y
      let halfBoard = boardSize * 0.5

      guard localX >= -halfBoard, localX <= halfBoard, localZ >= -halfBoard, localZ <= halfBoard else {
        return nil
      }

      let squareSize = boardSize / 8.0
      let presentedFile = Int(floor((localX + halfBoard) / squareSize))
      let presentedRank = Int(floor((halfBoard - localZ) / squareSize))
      let file = boardViewerColor == .white ? 7 - presentedFile : presentedFile
      let rank = boardViewerColor == .white ? 7 - presentedRank : presentedRank
      let square = BoardSquare(
        file: max(0, min(7, file)),
        rank: max(0, min(7, rank))
      )

      guard square.isValid else {
        return nil
      }

      return square
    }

    private func boardSquare(at location: CGPoint, in arView: ARView) -> BoardSquare? {
      guard let localPoint = boardLocalPoint(at: location, in: arView) else {
        return nil
      }

      return boardSquare(forBoardLocalPoint: localPoint)
    }

    private func previewDestinationSquare(
      for location: CGPoint,
      in arView: ARView,
      originSquare: BoardSquare,
      legalMoves: [ChessMove]
    ) -> BoardSquare? {
      guard let localPoint = boardLocalPoint(at: location, in: arView) else {
        return nil
      }

      let legalDestinations = Array(Set(legalMoves.map(\.to)))
      guard !legalDestinations.isEmpty else {
        return nil
      }

      if let exactSquare = boardSquare(forBoardLocalPoint: localPoint),
         legalDestinations.contains(exactSquare) {
        return exactSquare
      }

      let squareSize = boardSize / 8.0
      let originPosition = boardPosition(originSquare, squareSize: squareSize)
      let dragVector = SIMD2<Float>(localPoint.x - originPosition.x, localPoint.y - originPosition.z)
      guard simd_length(dragVector) >= (squareSize * 0.33) else {
        return nil
      }

      return legalDestinations.min { left, right in
        let leftPosition = boardPosition(left, squareSize: squareSize)
        let rightPosition = boardPosition(right, squareSize: squareSize)
        let leftDistance = simd_length(SIMD2<Float>(localPoint.x - leftPosition.x, localPoint.y - leftPosition.z))
        let rightDistance = simd_length(SIMD2<Float>(localPoint.x - rightPosition.x, localPoint.y - rightPosition.z))
        return leftDistance < rightDistance
      }
    }

    private func applyBoardScale() {
      boardRoot.scale = SIMD3<Float>(repeating: boardScale)
      updateFishingPondPlacement()
    }

    private func desiredBoardViewerColor() -> ChessColor {
      if let checkpoint = gameReview.currentCheckpoint, gameReview.isReviewMode {
        return checkpoint.playerColor
      }

      switch mode {
      case .lesson(let lesson):
        return lessonStore.activeLesson?.studentColor ?? lesson.studentColor
      case .passAndPlay(_):
        return gameState.turn
      case .queueMatch:
        return queueAssignedColor ?? gameState.turn
      case .playVsStockfish(let configuration):
        return configuration.humanColor
      }
    }

    private func syncBoardPerspectiveIfNeeded() {
      let viewerColor = desiredBoardViewerColor()
      guard boardViewerColor != viewerColor else {
        return
      }

      guard boardAnchor != nil else {
        prepareBoardSceneIfNeeded(force: true)
        return
      }

      boardViewerColor = viewerColor
      rebuildBoardEntityForPerspective()
    }

    private func rebuildBoardEntityForPerspective() {
      guard let boardAnchor else {
        return
      }

      boardRoot.removeFromParent()
      let refreshedBoardRoot = makeBoardEntity()
      boardAnchor.addChild(refreshedBoardRoot)
      refreshBoardPresentation()
      hasPreparedBoardScene = true
    }

    private func prepareBoardSceneIfNeeded(force: Bool = false) {
      let viewerColor = desiredBoardViewerColor()
      guard force || !hasPreparedBoardScene || boardViewerColor != viewerColor else {
        return
      }

      boardViewerColor = viewerColor
      _ = makeBoardEntity()
      refreshBoardPresentation()
      hasPreparedBoardScene = true
    }

    private func syncSocraticCoachContext(force: Bool = false) {
      let shouldEnableCoach = mode.supportsSocraticCoach && gameReview.phase == .idle
      socraticCoach.setEnabled(shouldEnableCoach)
      guard shouldEnableCoach else {
        socraticCoach.updateContext(nil)
        return
      }

      socraticCoach.updateContext(
        SocraticCoachContext(
          fen: gameState.fenString,
          moveHistory: fullNarrativeMoveHistory(),
          activeColor: gameState.turn
        )
      )
      if force {
        clearAllThreatOverlays()
      }
    }

    private func recalculatePieceRoles() {
      pieceRoleSnapshot = gameState.evaluatePieceRolesRelativeToCurrentPlayer()
      wantedPosterHighlightSquare = nil
      pieceRoles.update(snapshot: pieceRoleSnapshot)
    }

    private func highlightEmployeeOfTheMonth() {
      guard let employeeSquare = pieceRoleSnapshot.employeeOfTheMonthSquare else {
        return
      }

      wantedPosterHighlightSquare = employeeSquare
      syncHighlights()
    }

    private func fullNarrativeMoveHistory() -> [String] {
      narrativeHistory.map(\.san)
    }

    private func showThreatOverlay(algebraicSquares: [String]) {
      let resolvedSquares = deduplicatedSquares(algebraicSquares.compactMap(BoardSquare.init(algebraic:)))
      guard !resolvedSquares.isEmpty else {
        return
      }

      activeThreatSquares = resolvedSquares
      syncThreatOverlay()
      startThreatOverlayAnimationIfNeeded()

      threatOverlayHideWorkItem?.cancel()
      let hideWorkItem = DispatchWorkItem { [weak self] in
        self?.clearThreatOverlay()
      }
      threatOverlayHideWorkItem = hideWorkItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: hideWorkItem)
    }

    private func setSpeakingPieceHighlight(algebraicSquares: [String]) {
      let resolvedSquare = algebraicSquares.compactMap(BoardSquare.init(algebraic:)).first
      guard speakingPieceHighlightSquare != resolvedSquare else {
        return
      }
      speakingPieceHighlightSquare = resolvedSquare
      syncHighlights()
    }

    private func clearThreatOverlay() {
      threatOverlayHideWorkItem?.cancel()
      threatOverlayHideWorkItem = nil
      activeThreatSquares.removeAll(keepingCapacity: false)
      syncThreatOverlay()
      stopThreatOverlayAnimationIfNeeded()
    }

    private func setPersistentThreatOverlay(squares: [BoardSquare]) {
      persistentThreatSquares = deduplicatedSquares(squares)
      syncThreatOverlay()
      if persistentThreatSquares.isEmpty {
        stopThreatOverlayAnimationIfNeeded()
      } else {
        startThreatOverlayAnimationIfNeeded()
      }
    }

    private func clearPersistentThreatOverlay() {
      guard !persistentThreatSquares.isEmpty else {
        return
      }
      persistentThreatSquares.removeAll(keepingCapacity: false)
      syncThreatOverlay()
      stopThreatOverlayAnimationIfNeeded()
    }

    private func clearAllThreatOverlays() {
      threatOverlayHideWorkItem?.cancel()
      threatOverlayHideWorkItem = nil
      activeThreatSquares.removeAll(keepingCapacity: false)
      persistentThreatSquares.removeAll(keepingCapacity: false)
      syncThreatOverlay()
      stopThreatOverlayAnimationIfNeeded()
    }

    private func startThreatOverlayAnimationIfNeeded() {
      guard threatOverlayDisplayLink == nil else {
        return
      }

      let displayLink = CADisplayLink(target: self, selector: #selector(handleThreatOverlayDisplayLink))
      displayLink.add(to: .main, forMode: .common)
      threatOverlayDisplayLink = displayLink
    }

    private func stopThreatOverlayAnimationIfNeeded() {
      guard activeThreatSquares.isEmpty, persistentThreatSquares.isEmpty else {
        return
      }
      threatOverlayDisplayLink?.invalidate()
      threatOverlayDisplayLink = nil
    }

    private func deduplicatedSquares(_ squares: [BoardSquare]) -> [BoardSquare] {
      var resolvedSquares: [BoardSquare] = []
      var seenSquares = Set<BoardSquare>()
      for square in squares where seenSquares.insert(square).inserted {
        resolvedSquares.append(square)
      }
      return resolvedSquares
    }

    @objc
    private func handleThreatOverlayDisplayLink() {
      let alpha = currentThreatPulseAlpha()
      let scale = currentThreatPulseScale()
      for entity in activeThreatEntities {
        entity.model?.materials = [
          SimpleMaterial(
            color: UIColor(red: 0.92, green: 0.18, blue: 0.24, alpha: alpha),
            roughness: 0.10,
            isMetallic: false
          )
        ]
        entity.scale = SIMD3<Float>(repeating: scale)
      }
    }

    private func currentThreatPulseAlpha() -> CGFloat {
      let pulse = (sin(CACurrentMediaTime() * (.pi * 3.0)) + 1.0) * 0.5
      return CGFloat(0.30 + (pulse * 0.50))
    }

    private func currentThreatPulseScale() -> Float {
      let pulse = (sin(CACurrentMediaTime() * (.pi * 3.0)) + 1.0) * 0.5
      return Float(0.97 + (pulse * 0.06))
    }

    @MainActor
    private func applyEngineMoveHighlightsIfNeeded(
      for move: ChessMove,
      before beforeState: ChessGameState,
      after afterState: ChessGameState
    ) async {
      guard let stockfishRank = await commentary.stockfishRank(for: move, before: beforeState) else {
        return
      }

      showBrilliantMoveMarker(at: move.to)

      guard stockfishRank <= strongMoveAttackHighlightMaxRank else {
        return
      }

      let qualifyingSquares = qualifyingStrongMoveAttackSquares(for: move, in: afterState)
      guard !qualifyingSquares.isEmpty else {
        return
      }

      setPersistentThreatOverlay(squares: qualifyingSquares)
    }

    private func qualifyingStrongMoveAttackSquares(
      for move: ChessMove,
      in state: ChessGameState
    ) -> [BoardSquare] {
      guard let movedPiece = state.piece(at: move.to) else {
        return []
      }

      let attackedSquares = deduplicatedSquares(state.attackedSquares(from: move.to))
      guard !attackedSquares.isEmpty else {
        return []
      }

      let targetsEnemy = attackedSquares.contains { square in
        guard let occupant = state.piece(at: square) else {
          return false
        }
        return occupant.color == movedPiece.color.opponent
      }

      let holdsLongSlidingLine: Bool
      switch movedPiece.kind {
      case .bishop, .rook, .queen:
        holdsLongSlidingLine = state.longestSlidingAttackRayLength(from: move.to) >= strongMoveAttackHighlightMinSlidingLength
      default:
        holdsLongSlidingLine = false
      }

      return (holdsLongSlidingLine || targetsEnemy) ? attackedSquares : []
    }

    private func handleTapOnPiece(at square: BoardSquare) {
      guard let piece = gameState.piece(at: square) else {
        clearSelection()
        return
      }

      if canControlPiece(piece, at: square) {
        if selectedSquare == square {
          clearSelection()
        } else {
          select(square)
        }
        return
      }

      if let move = selectedMoves.first(where: { $0.to == square }) {
        apply(move)
      } else {
        clearSelection()
      }
    }

    private func handleTapOnSquare(_ square: BoardSquare) {
      if let move = selectedMoves.first(where: { $0.to == square }) {
        apply(move)
        return
      }

      if let piece = gameState.piece(at: square), canControlPiece(piece, at: square) {
        select(square)
      } else {
        clearSelection()
      }
    }

    private func select(_ square: BoardSquare) {
      activePieceDrag = nil
      selectedSquare = square
      selectedMoves = gameState.legalMoves(from: square)

      if selectedMoves.isEmpty {
        selectedSquare = nil
      }

      refreshBoardPresentation()
    }

    private func clearSelection() {
      activePieceDrag = nil
      selectedSquare = nil
      selectedMoves = []
      refreshBoardPresentation()
    }

    private func applyVoiceCommandMove(_ uci: String) {
      guard boardAnchor != nil,
            pendingAnimatedMoves.isEmpty,
            let move = gameState.move(forUCI: uci),
            let piece = gameState.piece(at: move.from),
            canControlPiece(piece, at: move.from) else {
        return
      }

      clearSelection()
      apply(move)
    }

    private func applyDirectVoiceCommand(_ transcript: String) -> String? {
      guard boardAnchor != nil,
            pendingAnimatedMoves.isEmpty,
            let move = directVoiceCommandMove(from: transcript),
            let piece = gameState.piece(at: move.from),
            canControlPiece(piece, at: move.from) else {
        return nil
      }

      showThreatOverlay(algebraicSquares: [move.to.algebraic])
      clearSelection()
      apply(move)
      return move.uciString
    }

    private func directVoiceCommandMove(from transcript: String) -> ChessMove? {
      let normalized = normalizeDirectVoiceCommand(transcript)
      guard !normalized.isEmpty else {
        return nil
      }

      if let castlingMove = directVoiceCastlingMove(for: normalized) {
        return castlingMove
      }

      let components = normalized.split(separator: " ")
      let destinationToken: Substring
      let desiredKind: ChessPieceKind

      switch components.count {
      case 1:
        guard let token = components.first, isDirectVoiceSquare(token) else {
          return nil
        }
        destinationToken = token
        desiredKind = .pawn
      case 2:
        guard let first = components.first, let second = components.last else {
          return nil
        }
        guard let kind = directVoicePieceKind(token: first), isDirectVoiceSquare(second) else {
          return nil
        }
        destinationToken = second
        desiredKind = kind
      case 3:
        guard let first = components.first,
              components[1] == "to",
              let third = components.last,
              let kind = directVoicePieceKind(token: first),
              isDirectVoiceSquare(third) else {
          return nil
        }
        destinationToken = third
        desiredKind = kind
      default:
        return nil
      }

      guard let destination = BoardSquare(algebraic: String(destinationToken)) else {
        return nil
      }

      let candidates = directVoiceLegalMoves().filter {
        $0.to == destination && $0.piece.kind == desiredKind
      }
      return candidates.count == 1 ? candidates[0] : nil
    }

    private func directVoiceLegalMoves() -> [ChessMove] {
      gameState.board.compactMap { square, piece -> [ChessMove]? in
        guard piece.color == gameState.turn else {
          return nil
        }
        return gameState.legalMoves(from: square)
      }
      .flatMap { $0 }
    }

    private func directVoiceCastlingMove(for normalized: String) -> ChessMove? {
      let kingsidePhrases = ["castle kingside", "castle king side", "short castle", "castle short"]
      let queensidePhrases = ["castle queenside", "castle queen side", "long castle", "castle long"]

      if kingsidePhrases.contains(normalized) {
        let targetFile = 6
        return directVoiceLegalMoves().first {
          $0.piece.kind == .king && $0.rookMove != nil && $0.to.file == targetFile
        }
      }

      if queensidePhrases.contains(normalized) {
        let targetFile = 2
        return directVoiceLegalMoves().first {
          $0.piece.kind == .king && $0.rookMove != nil && $0.to.file == targetFile
        }
      }

      return nil
    }

    private func normalizeDirectVoiceCommand(_ transcript: String) -> String {
      let lowered = transcript.lowercased()
      let alphanumerics = lowered.replacingOccurrences(
        of: "[^a-z0-9\\s-]",
        with: " ",
        options: .regularExpression
      )
      let collapsedSquares = alphanumerics.replacingOccurrences(
        of: "\\b([a-h])[\\s-]+([1-8])\\b",
        with: "$1$2",
        options: .regularExpression
      )
      return collapsedSquares.replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isDirectVoiceSquare(_ token: Substring) -> Bool {
      String(token).range(of: "^[a-h][1-8]$", options: .regularExpression) != nil
    }

    private func directVoicePieceKind(token: Substring) -> ChessPieceKind? {
      switch token {
      case "pawn":
        return .pawn
      case "knight", "horse":
        return .knight
      case "bishop":
        return .bishop
      case "rook":
        return .rook
      case "queen":
        return .queen
      case "king":
        return .king
      default:
        return nil
      }
    }

    private func apply(_ move: ChessMove) {
      activePieceDrag = nil

      if gameReview.isReviewMode {
        applyReviewPlayerMove(move)
        return
      }

      if mode.isLessonMode {
        applyLessonMove(move)
        return
      }

      if case .queueMatch = mode {
        let targetPly = syncedQueueMoves.count + 1
        Task { @MainActor in
          do {
            try await queueMatch.submitMove(moveUCI: move.uciString, ply: targetPly)
          } catch {
            await MainActor.run {
              commentary.noteExternalStatus("Queue move sync failed: \(error.localizedDescription)")
            }
          }
        }
        return
      }

      liveEngineTask?.cancel()
      liveEngineTask = nil
      let movingColor = gameState.turn
      let beforeState = gameState
      let afterState = gameState.applying(move)
      enqueueMoveAnimation(
        AnimatedMoveContext(
          move: move,
          beforeState: beforeState,
          afterState: afterState,
          postApply: { [weak self] in
            guard let self else {
              return
            }

            self.matchLog.recordMove(move.uciString, color: movingColor)
            self.recordNarrativeMove(move, before: beforeState)
            let evaluationDelta = await self.commentary.handleMove(move: move, before: beforeState, after: afterState)
            self.recordReviewCheckpointIfNeeded(
              for: move,
              before: beforeState,
              evaluationDelta: evaluationDelta
            )
            self.syncAutomatedOpponentTurnIfNeeded()
          }
        )
      )
    }

    private func applyServerMoveSet(_ moves: [QueueMatchMovePayload]) {
      guard gameReview.phase == .idle else {
        return
      }

      let orderedMoves = moves.sorted(by: { $0.ply < $1.ply })
      guard orderedMoves != syncedQueueMoves else {
        return
      }

      let previousMoveCount = syncedQueueMoves.count
      var rebuiltState = ChessGameState.initial()
      var rebuiltNarrativeHistory: [NarrativeMove] = []
      var newMoves: [(move: ChessMove, before: ChessGameState, after: ChessGameState)] = []

      for payload in orderedMoves {
        guard let move = rebuiltState.move(forUCI: payload.move_uci) else {
          Task { @MainActor in
            commentary.noteExternalStatus("Queue sync could not apply \(payload.move_uci).")
          }
          return
        }

        let beforeState = rebuiltState
        let afterState = rebuiltState.applying(move)
        rebuiltNarrativeHistory.append(
          NarrativeMove(ply: payload.ply, san: beforeState.sanNotation(for: move))
        )
        if payload.ply > previousMoveCount {
          newMoves.append((move: move, before: beforeState, after: afterState))
        }
        rebuiltState = afterState
      }

      syncedQueueMoves = orderedMoves
      narrativeHistory = rebuiltNarrativeHistory
      guard !newMoves.isEmpty else {
        gameState = rebuiltState
        selectedSquare = nil
        selectedMoves = []
        refreshBoardPresentation()
        syncSocraticCoachContext()
        return
      }

      if newMoves.count != orderedMoves.count - previousMoveCount {
        gameState = rebuiltState
        selectedSquare = nil
        selectedMoves = []
        refreshBoardPresentation()
        syncSocraticCoachContext()
      }

      for item in newMoves {
        enqueueMoveAnimation(
          AnimatedMoveContext(
            move: item.move,
            beforeState: item.before,
            afterState: item.after,
          postApply: { [weak self] in
            guard let self else {
              return
            }

            let evaluationDelta = await self.commentary.handleMove(move: item.move, before: item.before, after: item.after)
            self.recordReviewCheckpointIfNeeded(
              for: item.move,
              before: item.before,
              evaluationDelta: evaluationDelta
            )
          }
        )
        )
      }
    }

    private func applyReviewPlayerMove(_ move: ChessMove) {
      reviewEngineTask?.cancel()
      reviewEngineTask = nil

      let beforeState = gameState
      let afterState = gameState.applying(move)
      enqueueMoveAnimation(
        AnimatedMoveContext(
          move: move,
          beforeState: beforeState,
          afterState: afterState,
          postApply: { [weak self] in
            guard let self else {
              return
            }
            let evaluationDelta = await self.commentary.handleMove(move: move, before: beforeState, after: afterState)
            self.recordReviewCheckpointIfNeeded(
              for: move,
              before: beforeState,
              evaluationDelta: evaluationDelta
            )
            await self.scheduleReviewEngineReplyIfNeeded(after: afterState)
          }
        )
      )
    }

    private func applyLessonMove(_ move: ChessMove) {
      guard case .lesson(let lesson) = mode,
            lessonStore.isActive,
            lessonStore.isAwaitingPlayerMove,
            let step = lessonStore.currentStep,
            let correctMove = expectedLessonMove(for: step, in: gameState) else {
        clearSelection()
        return
      }

      if lessonStore.isMoveRevealed {
        guard move.uciString == correctMove.uciString else {
          clearSelection()
          return
        }

        commitLessonMove(move, lesson: lesson, step: step)
        return
      }

      guard move.uciString == correctMove.uciString else {
        clearSelection()
        guard lessonStore.registerIncorrectAttempt() else {
          return
        }
        if lessonStore.isMoveRevealed {
          socraticCoach.requestLessonAttemptFeedback(
            lessonTitle: lesson.title,
            prompt: step.prompt,
            focus: step.focus,
            remainingTries: lessonStore.remainingTries,
            moveRevealed: true
          )
        }
        return
      }

      commitLessonMove(move, lesson: lesson, step: step)
    }

    private func commitLessonMove(
      _ move: ChessMove,
      lesson: OpeningLessonDefinition,
      step: OpeningLessonStep
    ) {
      let beforeState = gameState
      let afterState = gameState.applying(move)
      enqueueMoveAnimation(
        AnimatedMoveContext(
          move: move,
          beforeState: beforeState,
          afterState: afterState,
          postApply: { [weak self] in
            guard let self else {
              return
            }

            _ = await self.commentary.handleMove(move: move, before: beforeState, after: afterState)

            let lessonCompleted = self.lessonStore.advanceAfterCorrectMove() != nil
            if lessonCompleted {
              self.commentary.noteExternalStatus("\(lesson.title) complete.")
              self.socraticCoach.requestLessonCompletion(
                lessonTitle: lesson.title,
                summary: lesson.summary
              )
            } else {
              self.socraticCoach.requestLessonSuccess(
                lessonTitle: lesson.title,
                prompt: step.prompt,
                focus: step.focus
              )
              if let nextStep = self.lessonStore.currentStep {
                self.commentary.noteExternalStatus(nextStep.focus)
              }
            }

            self.syncLessonAutoplayIfNeeded()
          }
        )
      )
    }

    private func expectedLessonMove(
      for step: OpeningLessonStep,
      in state: ChessGameState
    ) -> ChessMove? {
      state.move(forUCI: step.correctMoveUCI)
    }

    private func syncAutomatedOpponentTurnIfNeeded() {
      guard case .playVsStockfish(let configuration) = mode,
            !gameReview.isLoading,
            !gameReview.isReviewMode,
            boardAnchor != nil,
            pendingAnimatedMoves.isEmpty,
            liveEngineTask == nil,
            gameState.outcome == nil,
            gameState.turn == configuration.engineColor else {
        return
      }

      requestLiveEngineMove(for: gameState, configuration: configuration)
    }

    private func syncLessonAutoplayIfNeeded() {
      guard case .lesson(let lesson) = mode,
            lessonStore.isAutoPlayingOpponentMove,
            boardAnchor != nil,
            pendingAnimatedMoves.isEmpty,
            liveEngineTask == nil,
            let step = lessonStore.currentStep,
            gameState.fenString == step.startingFEN,
            expectedLessonMove(for: step, in: gameState) != nil else {
        return
      }

      let requestedFEN = gameState.fenString
      liveEngineTask?.cancel()
      liveEngineTask = Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        defer {
          self.liveEngineTask = nil
        }

        try? await Task.sleep(nanoseconds: 350_000_000)

        guard case .lesson(let confirmedLesson) = self.mode,
              confirmedLesson == lesson,
              self.lessonStore.isAutoPlayingOpponentMove,
              self.gameState.fenString == requestedFEN,
              self.pendingAnimatedMoves.isEmpty,
              let confirmedStep = self.lessonStore.currentStep,
              confirmedStep == step,
              let confirmedMove = self.expectedLessonMove(for: confirmedStep, in: self.gameState) else {
          return
        }

        let beforeState = self.gameState
        let afterState = beforeState.applying(confirmedMove)
        self.enqueueMoveAnimation(
          AnimatedMoveContext(
            move: confirmedMove,
            beforeState: beforeState,
            afterState: afterState,
            postApply: { [weak self] in
              guard let self else {
                return
              }

              _ = await self.commentary.handleMove(move: confirmedMove, before: beforeState, after: afterState)

              if self.lessonStore.advanceAfterCorrectMove() != nil {
                self.commentary.noteExternalStatus("\(lesson.title) complete.")
                self.socraticCoach.requestLessonCompletion(
                  lessonTitle: lesson.title,
                  summary: lesson.summary
                )
              } else if let nextStep = self.lessonStore.currentStep {
                self.commentary.noteExternalStatus(nextStep.focus)
              }
              self.syncLessonAutoplayIfNeeded()
            }
          )
        )
      }
    }

    private func requestLiveEngineMove(
      for state: ChessGameState,
      configuration: StockfishMatchConfiguration
    ) {
      let requestedFEN = state.fenString
      liveEngineTask?.cancel()
      liveEngineTask = Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        defer {
          self.liveEngineTask = nil
        }

        guard case .playVsStockfish(let currentConfiguration) = self.mode,
              currentConfiguration == configuration,
              !self.gameReview.isLoading,
              !self.gameReview.isReviewMode,
              self.gameState.fenString == requestedFEN else {
          return
        }

        guard let replyMove = await self.commentary.gameplayReplyMove(for: state) else {
          self.commentary.noteExternalStatus("Stockfish could not produce a move.")
          return
        }

        guard !Task.isCancelled,
              case .playVsStockfish(let confirmedConfiguration) = self.mode,
              confirmedConfiguration == configuration,
              !self.gameReview.isLoading,
              !self.gameReview.isReviewMode,
              self.gameState.fenString == requestedFEN,
              self.pendingAnimatedMoves.isEmpty else {
          return
        }

        let afterState = state.applying(replyMove)
        self.enqueueMoveAnimation(
          AnimatedMoveContext(
            move: replyMove,
            beforeState: state,
            afterState: afterState,
            postApply: { [weak self] in
              guard let self else {
                return
              }

              self.matchLog.recordMove(replyMove.uciString, color: state.turn)
              self.recordNarrativeMove(replyMove, before: state)
              let evaluationDelta = await self.commentary.handleMove(move: replyMove, before: state, after: afterState)
              self.recordReviewCheckpointIfNeeded(
                for: replyMove,
                before: state,
                evaluationDelta: evaluationDelta
              )
              self.syncAutomatedOpponentTurnIfNeeded()
            }
          )
        )
      }
    }

    private func recordReviewCheckpointIfNeeded(
      for move: ChessMove,
      before state: ChessGameState,
      evaluationDelta: MoveEvaluationDelta?
    ) {
      guard let evaluationDelta,
            evaluationDelta.deltaW < 0,
            shouldTrackMoveForReview(moverColor: state.turn) else {
        return
      }

      gameReview.recordNegativeDrop(
        GameReviewCheckpoint(
          fenBeforeMistake: state.fenString,
          moveIndex: ply(for: state),
          blunderMove: move.uciString,
          evalBefore: evaluationDelta.evalBefore,
          evalAfter: evaluationDelta.evalAfter,
          deltaW: evaluationDelta.deltaW,
          playerColor: state.turn
        )
      )
    }

    private func shouldTrackMoveForReview(moverColor: ChessColor) -> Bool {
      guard mode.supportsPostGameReview else {
        return false
      }

      return mode.humanPlayerColor(queueAssignedColor: queueAssignedColor) == moverColor
    }

    @MainActor
    private func maybeBeginPostGameFlowIfNeeded(after state: ChessGameState) async {
      guard mode.supportsPostGameReview,
            gameReview.phase == .idle,
            !hasTriggeredPostGameFlow,
            state.outcome != nil else {
        return
      }

      hasTriggeredPostGameFlow = true
      initialAnalysisTask?.cancel()
      initialAnalysisTask = nil
      liveEngineTask?.cancel()
      liveEngineTask = nil
      reviewEngineTask?.cancel()
      reviewEngineTask = nil
      clearSelection()

      if !gameReview.stageReviewPrompt() {
        onReviewFinished()
      }
    }

    private func syncLessonStateIfNeeded(force: Bool = false) {
      guard mode.isLessonMode,
            lessonStore.isActive,
            let step = lessonStore.currentStep else {
        loadedLessonReloadVersion = 0
        lastLessonMoveRevealState = false
        lastLessonIntroNarrationKey = nil
        return
      }

      guard force || loadedLessonReloadVersion != lessonStore.reloadVersion else {
        return
      }

      loadLessonStep(step)
    }

    private func loadLessonStep(_ step: OpeningLessonStep) {
      liveEngineTask?.cancel()
      liveEngineTask = nil
      reviewEngineTask?.cancel()
      reviewEngineTask = nil
      initialAnalysisTask?.cancel()
      initialAnalysisTask = nil
      moveAnimationTask?.cancel()
      moveAnimationTask = nil
      pendingAnimatedMoves.removeAll()
      activeKnightForkBinding = nil
      narrativeHistory.removeAll()
      selectedSquare = nil
      selectedMoves = []

      do {
        gameState = try ChessGameState(fen: step.startingFEN)
        loadedLessonReloadVersion = lessonStore.reloadVersion
        lastLessonMoveRevealState = lessonStore.isMoveRevealed
        refreshBoardPresentation()
        commentary.noteExternalStatus(step.focus)
        syncSocraticCoachContext(force: true)
        maybeRequestLessonIntroIfNeeded()
      } catch {
        commentary.noteExternalStatus("Lesson step could not load.")
        lessonStore.resetSession()
      }
    }

    private func maybeRequestLessonIntroIfNeeded() {
      guard mode.isLessonMode,
            boardAnchor != nil,
            lessonStore.isActive,
            let lesson = lessonStore.activeLesson,
            let step = lessonStore.currentStep else {
        return
      }

      let introKey = "\(lesson.id):\(lessonStore.reloadVersion):\(step.id)"
      guard lastLessonIntroNarrationKey != introKey else {
        return
      }

      lastLessonIntroNarrationKey = introKey
      socraticCoach.requestLessonIntro(
        lessonTitle: lesson.title,
        prompt: step.prompt,
        focus: step.focus
      )
    }

    private func syncLessonRevealPresentationIfNeeded() {
      guard mode.isLessonMode else {
        lastLessonMoveRevealState = false
        return
      }

      let revealState = lessonStore.isMoveRevealed
      guard revealState != lastLessonMoveRevealState else {
        return
      }

      lastLessonMoveRevealState = revealState
      refreshBoardPresentation()
    }

    private func syncReviewStateIfNeeded(force: Bool = false) {
      guard gameReview.isReviewMode,
            let checkpoint = gameReview.currentCheckpoint else {
        loadedReviewCheckpointID = nil
        loadedReviewReloadVersion = 0
        return
      }

      guard force
        || loadedReviewCheckpointID != checkpoint.id
        || loadedReviewReloadVersion != gameReview.checkpointReloadVersion else {
        return
      }

      loadReviewCheckpoint(checkpoint)
    }

    private func loadReviewCheckpoint(_ checkpoint: GameReviewCheckpoint) {
      liveEngineTask?.cancel()
      liveEngineTask = nil
      reviewEngineTask?.cancel()
      reviewEngineTask = nil
      initialAnalysisTask?.cancel()
      initialAnalysisTask = nil
      moveAnimationTask?.cancel()
      moveAnimationTask = nil
      pendingAnimatedMoves.removeAll()
      activeKnightForkBinding = nil
      narrativeHistory.removeAll()
      selectedSquare = nil
      selectedMoves = []

      do {
        gameState = try ChessGameState(fen: checkpoint.fenBeforeMistake)
        loadedReviewCheckpointID = checkpoint.id
        loadedReviewReloadVersion = gameReview.checkpointReloadVersion
        refreshBoardPresentation()
        commentary.noteExternalStatus("Game Review checkpoint \(gameReview.currentReviewIndex + 1) ready.")
        syncSocraticCoachContext(force: true)
      } catch {
        commentary.noteExternalStatus("Game Review skipped an invalid checkpoint.")
        if gameReview.advanceToNextCheckpoint() {
          onReviewFinished()
        } else {
          syncReviewStateIfNeeded(force: true)
        }
      }
    }

    @MainActor
    private func scheduleReviewEngineReplyIfNeeded(after state: ChessGameState) async {
      guard gameReview.isReviewMode,
            let checkpoint = gameReview.currentCheckpoint,
            state.outcome == nil,
            state.turn != checkpoint.playerColor else {
        return
      }

      requestReviewEngineMove(for: state, checkpoint: checkpoint)
    }

    private func requestReviewEngineMove(
      for state: ChessGameState,
      checkpoint: GameReviewCheckpoint
    ) {
      let requestedFEN = state.fenString
      reviewEngineTask?.cancel()
      reviewEngineTask = Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        guard self.gameReview.isReviewMode,
              self.gameReview.currentCheckpoint?.id == checkpoint.id else {
          return
        }

        guard let replyMove = await self.commentary.reviewReplyMove(for: state) else {
          return
        }

        guard !Task.isCancelled,
              self.gameReview.isReviewMode,
              self.gameReview.currentCheckpoint?.id == checkpoint.id,
              self.gameState.fenString == requestedFEN else {
          return
        }

        let afterState = state.applying(replyMove)
        self.enqueueMoveAnimation(
          AnimatedMoveContext(
            move: replyMove,
            beforeState: state,
            afterState: afterState,
            postApply: { [weak self] in
              guard let self else {
                return
              }

              _ = await self.commentary.handleMove(move: replyMove, before: state, after: afterState)
            }
          )
        )
      }
    }

    private func recordNarrativeMove(_ move: ChessMove, before state: ChessGameState) {
      let entry = NarrativeMove(ply: ply(for: state), san: state.sanNotation(for: move))
      narrativeHistory.append(entry)
    }

    private func recentNarrativeSequence() -> String? {
      let recentMoves = Array(narrativeHistory.suffix(10))
      guard !recentMoves.isEmpty else {
        return nil
      }

      return recentMoves.map { entry in
        let moveNumber = (entry.ply + 1) / 2
        if entry.ply.isMultiple(of: 2) {
          return "\(moveNumber)... \(entry.san)"
        }
        return "\(moveNumber). \(entry.san)"
      }.joined(separator: " ")
    }

    private func ply(for state: ChessGameState) -> Int {
      let basePly = (state.fullmoveNumber - 1) * 2
      return basePly + (state.turn == .white ? 1 : 2)
    }

    private func enqueueMoveAnimation(_ context: AnimatedMoveContext) {
      pendingAnimatedMoves.append(context)

      guard moveAnimationTask == nil else {
        return
      }

      moveAnimationTask = Task { @MainActor [weak self] in
        await self?.drainMoveAnimations()
      }
    }

    @MainActor
    private func drainMoveAnimations() async {
      while !pendingAnimatedMoves.isEmpty {
        let context = pendingAnimatedMoves.removeFirst()
        await animateAndApply(context)
      }

      moveAnimationTask = nil
    }

    @MainActor
    private func animateAndApply(_ context: AnimatedMoveContext) async {
      clearKnightCameraSplatOverlay(animated: false)
      clearThreatOverlay()
      clearPersistentThreatOverlay()

      if activeKnightForkBinding?.clearsOnMoveBy == context.move.piece.color {
        activeKnightForkBinding = nil
      }

      selectedSquare = nil
      selectedMoves = []
      refreshBoardPresentation()
      let previousViewerColor = boardViewerColor
      let knightCameraSplatVictim = knightCameraSplatVictim(for: context.move, beforeState: context.beforeState)

      captureSoundEffects.playMove(for: context.move.piece.kind)
      if mode.supportsPassiveAutomaticCommentary {
        commentary.triggerAutomaticCommentaryForMove(
          move: context.move,
          before: context.beforeState,
          after: context.afterState
        )
      }

      if context.move.captured != nil || context.move.isEnPassant {
        await animateCapture(for: context.move, beforeState: context.beforeState)
      }

      gameState = context.afterState
      syncBoardPerspectiveIfNeeded()
      refreshBoardPresentation()
      let nextViewerColor = desiredBoardViewerColor()
      if let knightCameraSplatVictim,
         previousViewerColor != nextViewerColor {
        showKnightCameraSplat(for: knightCameraSplatVictim, viewerColor: nextViewerColor)
      }
      animateCapturedGhostIfNeeded(for: context.move, beforeState: context.beforeState)
      syncSocraticCoachContext()
      await applyEngineMoveHighlightsIfNeeded(
        for: context.move,
        before: context.beforeState,
        after: context.afterState
      )
      await context.postApply?()
      await maybeBeginPostGameFlowIfNeeded(after: context.afterState)
    }

    @MainActor
    private func showBrilliantMoveMarker(at square: BoardSquare) {
      guard let animation = Self.brilliantAnimation,
            let arView else {
        return
      }

      brilliantMarkerHideWorkItem?.cancel()
      brilliantMarkerDisplayLink?.invalidate()
      brilliantMarkerView?.removeFromSuperview()

      let marker = UIImageView()
      marker.backgroundColor = .clear
      marker.isUserInteractionEnabled = false
      marker.contentMode = .scaleAspectFit
      marker.alpha = 0.96
      marker.animationImages = animation.frames
      marker.animationDuration = animation.duration
      marker.animationRepeatCount = 1
      arView.addSubview(marker)
      arView.bringSubviewToFront(marker)

      brilliantMarkerView = marker
      brilliantMarkerPieceName = pieceName(square)
      updateBrilliantMoveMarkerFrame()
      marker.startAnimating()

      let displayLink = CADisplayLink(target: self, selector: #selector(handleBrilliantMarkerDisplayLink))
      displayLink.add(to: .main, forMode: .common)
      brilliantMarkerDisplayLink = displayLink

      let hideWorkItem = DispatchWorkItem { [weak self, weak marker] in
        guard let self else {
          return
        }
        self.brilliantMarkerDisplayLink?.invalidate()
        self.brilliantMarkerDisplayLink = nil
        self.brilliantMarkerPieceName = nil
        UIView.animate(withDuration: 0.14, animations: {
          marker?.alpha = 0
        }, completion: { _ in
          marker?.removeFromSuperview()
        })
      }
      brilliantMarkerHideWorkItem = hideWorkItem
      DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration + 0.05, execute: hideWorkItem)
    }

    @objc
    private func handleBrilliantMarkerDisplayLink() {
      updateBrilliantMoveMarkerFrame()
    }

    private func updateBrilliantMoveMarkerFrame() {
      guard let marker = brilliantMarkerView,
            let pieceName = brilliantMarkerPieceName,
            let frame = brilliantMarkerFrame(forPieceNamed: pieceName) else {
        brilliantMarkerView?.removeFromSuperview()
        brilliantMarkerView = nil
        brilliantMarkerDisplayLink?.invalidate()
        brilliantMarkerDisplayLink = nil
        brilliantMarkerPieceName = nil
        return
      }

      marker.frame = frame
    }

    private func brilliantMarkerFrame(forPieceNamed pieceName: String) -> CGRect? {
      guard let arView,
            let head = projectedPiecePoint(named: pieceName, verticalOffset: 0.082),
            let neck = projectedPiecePoint(named: pieceName, verticalOffset: 0.046) else {
        return nil
      }

      // Keep the brilliant badge visually similar to a chess-app "!!" exponent:
      // smaller than the piece and offset above-right of the crown while still
      // tracking the piece's world position through projection.
      let projectedHeadHeight = abs(neck.y - head.y)
      let size = max(18, min(42, projectedHeadHeight * 1.1))
      let exponentCenter = CGPoint(
        x: head.x + max(size * 0.28, projectedHeadHeight * 0.22),
        y: head.y - max(size * 0.16, projectedHeadHeight * 0.14)
      )
      let origin = CGPoint(x: exponentCenter.x - (size * 0.5), y: exponentCenter.y - (size * 0.5))
      let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
      return frame.intersects(arView.bounds) ? frame : nil
    }

    private func projectedPiecePoint(named pieceName: String, verticalOffset: Float) -> CGPoint? {
      guard let arView,
            let piece = piecesContainer.findEntity(named: pieceName) else {
        return nil
      }

      let worldPoint = piece.position(relativeTo: nil) + SIMD3<Float>(0, verticalOffset, 0)
      return arView.project(worldPoint)
    }

    private func handleReactionCue(_ cue: PiecePersonalityDirector.ReactionCue) {
      switch cue.kind {
      case .enemyKingPrays(let color):
        animateKingPrayer(for: color)
      case .currentKingCries(let color):
        animateKingCrying(for: color)
      case .knightFork(let targets):
        activateKnightForkChains(on: targets)
      }
    }

    @MainActor
    private func animateCapture(for move: ChessMove, beforeState: ChessGameState) async {
      guard let attacker = piecesContainer.findEntity(named: pieceName(move.from)) else {
        return
      }

      let capturedSquare = capturedSquare(for: move)
      let victim = capturedSquare.flatMap { piecesContainer.findEntity(named: pieceName($0)) }

      switch move.piece.kind {
      case .pawn:
        await animatePawnKnifeCapture(attacker: attacker, victim: victim, move: move)
      case .bishop:
        await animateBishopSniperCapture(attacker: attacker, victim: victim, move: move)
      case .knight:
        await animateKnightStrikeCapture(attacker: attacker, victim: victim, move: move)
      case .rook:
        await animateRookBazookaCapture(attacker: attacker, victim: victim, move: move)
      case .queen:
        await animateQueenLaserCapture(attacker: attacker, victim: victim, move: move)
      case .king:
        await animateKingCrownCapture(attacker: attacker, victim: victim, move: move)
      }
    }

    private func capturedSquare(for move: ChessMove) -> BoardSquare? {
      if move.isEnPassant {
        return BoardSquare(file: move.to.file, rank: move.from.rank)
      }

      return move.captured == nil ? nil : move.to
    }

    private func knightCameraSplatVictim(
      for move: ChessMove,
      beforeState: ChessGameState
    ) -> ChessPieceState? {
      guard case .passAndPlay = mode,
            move.piece.kind == .knight,
            let capturedSquare = capturedSquare(for: move) else {
        return nil
      }

      return beforeState.piece(at: capturedSquare)
    }

    @MainActor
    private func animateCapturedGhostIfNeeded(
      for move: ChessMove,
      beforeState: ChessGameState
    ) {
      guard let capturedSquare = capturedSquare(for: move),
            let capturedPiece = beforeState.piece(at: capturedSquare) else {
        return
      }

      let ghost = piecePrototype(
        for: capturedPiece.kind,
        color: capturedPiece.color,
        isGhost: true
      ).clone(recursive: true)
      ghost.name = "capture_ghost_\(capturedSquare.file)_\(capturedSquare.rank)"
      let squareSize = boardSize / 8.0
      ghost.position = boardPosition(capturedSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.004, 0)
      ghost.orientation = pieceFacingOrientation(for: capturedPiece.color)
      ghost.scale = SIMD3<Float>(repeating: 1.04)
      captureGhostContainer.addChild(ghost)

      let floatedAway = transformed(
        ghost.transform,
        translation: captureGhostFloatOffset(),
        scale: SIMD3<Float>(repeating: 0.86)
      )
      ghost.move(to: floatedAway, relativeTo: ghost.parent, duration: 1.95, timingFunction: .easeOut)

      DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak ghost] in
        ghost?.removeFromParent()
      }
    }

    @MainActor
    private func animatePawnKnifeCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      if move.captured?.kind == .pawn,
         let victim,
         let attackerKnife = attacker.findEntity(named: "pawn_knife"),
         let victimKnife = victim.findEntity(named: "pawn_knife") {
        let direction = attackDirection(for: move)
        let originalAttacker = attacker.transform
        let originalVictim = victim.transform
        let originalAttackerKnife = attackerKnife.transform
        let originalVictimKnife = victimKnife.transform

        // Pawn-on-pawn captures get a two-beat duel: one blade clash, then the finishing stab.
        let clashAttacker = transformed(
          originalAttacker,
          translation: direction * 0.016 + SIMD3<Float>(0, 0.002, 0)
        )
        let clashVictim = transformed(
          originalVictim,
          translation: -(direction * 0.010) + SIMD3<Float>(0, 0.001, 0)
        )
        attacker.move(to: clashAttacker, relativeTo: attacker.parent, duration: 0.11, timingFunction: .easeInOut)
        victim.move(to: clashVictim, relativeTo: victim.parent, duration: 0.11, timingFunction: .easeInOut)

        let attackerKnifeClash = transformed(
          originalAttackerKnife,
          translation: SIMD3<Float>(0.001, 0.005, 0.010),
          rotation: simd_quatf(angle: -.pi / 2.25, axis: SIMD3<Float>(1, 0, 0))
        )
        let victimKnifeClash = transformed(
          originalVictimKnife,
          translation: SIMD3<Float>(-0.001, 0.005, 0.008),
          rotation: simd_quatf(angle: .pi / 2.5, axis: SIMD3<Float>(1, 0, 0))
        )
        attackerKnife.move(to: attackerKnifeClash, relativeTo: attacker, duration: 0.10, timingFunction: .easeInOut)
        victimKnife.move(to: victimKnifeClash, relativeTo: victim, duration: 0.10, timingFunction: .easeInOut)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [captureSoundEffects] in
          captureSoundEffects.play(.pawnSword)
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        let stabAttacker = transformed(
          originalAttacker,
          translation: direction * 0.048 + SIMD3<Float>(0, 0.003, 0)
        )
        let chestStrike = transformed(
          originalAttackerKnife,
          translation: SIMD3<Float>(0.001, 0.005, 0.019),
          rotation: simd_quatf(angle: -.pi / 1.95, axis: SIMD3<Float>(1, 0, 0))
        )
        let piercedVictim = transformed(
          originalVictim,
          translation: direction * 0.018 + SIMD3<Float>(0, 0.014, 0),
          rotation: simd_normalize(
            simd_quatf(angle: .pi / 5.5, axis: SIMD3<Float>(0, 0, 1)) *
              simd_quatf(angle: -.pi / 14, axis: SIMD3<Float>(1, 0, 0))
          )
        )
        let victimKnifeCollapse = transformed(
          originalVictimKnife,
          translation: SIMD3<Float>(-0.006, -0.002, -0.004),
          rotation: simd_quatf(angle: .pi / 3.2, axis: SIMD3<Float>(0, 0, 1))
        )

        attacker.move(to: stabAttacker, relativeTo: attacker.parent, duration: 0.16, timingFunction: .easeIn)
        attackerKnife.move(to: chestStrike, relativeTo: attacker, duration: 0.14, timingFunction: .easeIn)
        victim.move(to: piercedVictim, relativeTo: victim.parent, duration: 0.20, timingFunction: .easeOut)
        victimKnife.move(to: victimKnifeCollapse, relativeTo: victim, duration: 0.16, timingFunction: .easeOut)

        try? await Task.sleep(nanoseconds: 430_000_000)
        return
      }

      let direction = attackDirection(for: move)
      let originalAttacker = attacker.transform
      let lunge = transformed(originalAttacker, translation: direction * 0.028)
      attacker.move(to: lunge, relativeTo: attacker.parent, duration: 0.12, timingFunction: .easeIn)

      if let knife = attacker.findEntity(named: "pawn_knife") {
        let slash = transformed(knife.transform, rotation: simd_quatf(angle: -.pi / 2.8, axis: SIMD3<Float>(1, 0, 0)))
        knife.move(to: slash, relativeTo: attacker, duration: 0.10, timingFunction: .easeIn)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [captureSoundEffects] in
        captureSoundEffects.play(.pawnSword)
      }

      if let victim {
        let struck = transformed(
          victim.transform,
          translation: direction * 0.024 + SIMD3<Float>(0, 0.010, 0),
          rotation: simd_quatf(angle: .pi / 7, axis: SIMD3<Float>(0, 0, 1))
        )
        victim.move(to: struck, relativeTo: victim.parent, duration: 0.14, timingFunction: .easeOut)
      }

      try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @MainActor
    private func animateBishopSniperCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      let direction = attackDirection(for: move)
      if let rifle = attacker.findEntity(named: "bishop_sniper") {
        let aim = transformed(rifle.transform, rotation: simd_quatf(angle: -.pi / 10, axis: SIMD3<Float>(1, 0, 0)))
        rifle.move(to: aim, relativeTo: attacker, duration: 0.08, timingFunction: .easeInOut)
      }

      if let victim {
        let muzzle = attacker.position + SIMD3<Float>(0, 0.038, 0) + (direction * 0.048)
        let target = victim.position + SIMD3<Float>(0, 0.018, 0)
        let flight = normalized3(target - muzzle, fallback: direction)

        let bullet = ModelEntity(
          mesh: .generateSphere(radius: 0.0045),
          materials: [SimpleMaterial(color: UIColor(red: 1.0, green: 0.93, blue: 0.70, alpha: 1), roughness: 0.08, isMetallic: true)]
        )
        bullet.position = muzzle
        boardRoot.addChild(bullet)

        let tracer = makeTracer(color: UIColor(red: 1.0, green: 0.94, blue: 0.70, alpha: 0.92), length: 0.05, thickness: 0.0028)
        tracer.position = muzzle - (flight * 0.020)
        tracer.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalized3(flight + SIMD3<Float>(0, 0.02, 0), fallback: SIMD3<Float>(0, 1, 0)))
        boardRoot.addChild(tracer)

        let bulletTransform = Transform(
          scale: bullet.scale,
          rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
          translation: target
        )
        bullet.move(to: bulletTransform, relativeTo: bullet.parent, duration: 0.11, timingFunction: .linear)

        let hit = transformed(
          victim.transform,
          translation: direction * 0.060 + SIMD3<Float>(0, 0.018, 0),
          rotation: simd_quatf(angle: .pi / 5, axis: SIMD3<Float>(1, 0, 0))
        )
        victim.move(to: hit, relativeTo: victim.parent, duration: 0.18, timingFunction: .easeOut)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [captureSoundEffects] in
          captureSoundEffects.play(.bishopGunshot)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak bullet, weak tracer] in
          bullet?.removeFromParent()
          tracer?.removeFromParent()
        }
      }

      try? await Task.sleep(nanoseconds: 320_000_000)
    }

    @MainActor
    private func animateKnightStrikeCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      let direction = attackDirection(for: move)
      let originalAttacker = attacker.transform
      let leap = transformed(
        originalAttacker,
        translation: direction * 0.042 + SIMD3<Float>(0, 0.025, 0),
        rotation: simd_quatf(angle: -.pi / 8, axis: SIMD3<Float>(1, 0, 0))
      )
      attacker.move(to: leap, relativeTo: attacker.parent, duration: 0.16, timingFunction: .easeIn)

      if let victim {
        let tossed = transformed(
          victim.transform,
          translation: direction * 0.155 + SIMD3<Float>(0, 0.078, 0),
          rotation: simd_normalize(
            simd_quatf(angle: .pi * 1.45, axis: SIMD3<Float>(0, 1, 0)) *
              simd_quatf(angle: -.pi / 7, axis: SIMD3<Float>(1, 0, 0))
          )
        )
        victim.move(to: tossed, relativeTo: victim.parent, duration: 0.26, timingFunction: .easeOut)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [captureSoundEffects] in
        captureSoundEffects.play(.knightThud)
      }

      try? await Task.sleep(nanoseconds: 340_000_000)
    }

    @MainActor
    private func animateRookBazookaCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      let direction = attackDirection(for: move)
      let originalAttacker = attacker.transform
      let recoil = transformed(originalAttacker, translation: direction * -0.018)
      attacker.move(to: recoil, relativeTo: attacker.parent, duration: 0.10, timingFunction: .easeOut)

      let shell = Entity()
      let shellBody = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.007, 0.024, 0.007)),
        materials: [SimpleMaterial(color: UIColor(red: 0.88, green: 0.58, blue: 0.24, alpha: 1), roughness: 0.10, isMetallic: true)]
      )
      shell.addChild(shellBody)

      let shellTip = ModelEntity(
        mesh: .generateSphere(radius: 0.005),
        materials: [SimpleMaterial(color: UIColor(red: 0.98, green: 0.78, blue: 0.30, alpha: 1), roughness: 0.06, isMetallic: true)]
      )
      shellTip.position = SIMD3<Float>(0, 0.015, 0)
      shell.addChild(shellTip)

      let launchPoint = attacker.position + SIMD3<Float>(0, 0.024, 0) + direction * 0.036
      shell.position = launchPoint
      boardRoot.addChild(shell)

      if let victim {
        let target = victim.position + SIMD3<Float>(0, 0.020, 0)
        let flight = normalized3(target - launchPoint, fallback: direction)
        shell.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalized3(flight + SIMD3<Float>(0, 0.02, 0), fallback: SIMD3<Float>(0, 1, 0)))

        let exhaust = makeTracer(color: UIColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 0.78), length: 0.07, thickness: 0.005)
        exhaust.position = launchPoint - (flight * 0.030)
        exhaust.orientation = shell.orientation
        boardRoot.addChild(exhaust)

        let shellTransform = Transform(scale: shell.scale, rotation: shell.orientation, translation: target)
        shell.move(to: shellTransform, relativeTo: shell.parent, duration: 0.14, timingFunction: .linear)

        let blasted = transformed(
          victim.transform,
          translation: direction * 0.110 + SIMD3<Float>(0, 0.050, 0),
          rotation: simd_quatf(angle: .pi / 2.2, axis: SIMD3<Float>(0, 0, 1))
        )
        victim.move(to: blasted, relativeTo: victim.parent, duration: 0.26, timingFunction: .easeOut)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [captureSoundEffects] in
          captureSoundEffects.play(.rookExplosion)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak exhaust] in
          exhaust?.removeFromParent()
        }
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak shell] in
        shell?.removeFromParent()
      }

      try? await Task.sleep(nanoseconds: 340_000_000)
    }

    @MainActor
    private func animateQueenLaserCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      let direction = attackDirection(for: move)

      if let glasses = attacker.findEntity(named: "queen_sunglasses") {
        let removed = transformed(
          glasses.transform,
          translation: SIMD3<Float>(0, 0.010, -0.018),
          rotation: simd_quatf(angle: -.pi / 3.2, axis: SIMD3<Float>(1, 0, 0))
        )
        glasses.move(to: removed, relativeTo: attacker, duration: 0.08, timingFunction: .easeIn)
      }

      if let victim {
        let leftOrigin = attacker.position + SIMD3<Float>(-0.007, 0.041, -0.012)
        let rightOrigin = attacker.position + SIMD3<Float>(0.007, 0.041, -0.012)
        let target = victim.position + SIMD3<Float>(0, 0.024, 0)
        let leftFlight = normalized3(target - leftOrigin, fallback: direction)
        let rightFlight = normalized3(target - rightOrigin, fallback: direction)

        let leftBolt = ModelEntity(
          mesh: .generateSphere(radius: 0.0045),
          materials: [SimpleMaterial(color: UIColor(red: 1.0, green: 0.14, blue: 0.22, alpha: 1), roughness: 0.04, isMetallic: true)]
        )
        let rightBolt = ModelEntity(
          mesh: .generateSphere(radius: 0.0045),
          materials: [SimpleMaterial(color: UIColor(red: 1.0, green: 0.14, blue: 0.22, alpha: 1), roughness: 0.04, isMetallic: true)]
        )
        leftBolt.position = leftOrigin
        rightBolt.position = rightOrigin
        boardRoot.addChild(leftBolt)
        boardRoot.addChild(rightBolt)

        let leftBeam = makeTracer(color: UIColor(red: 1.0, green: 0.12, blue: 0.18, alpha: 0.96), length: 0.06, thickness: 0.0032)
        let rightBeam = makeTracer(color: UIColor(red: 1.0, green: 0.12, blue: 0.18, alpha: 0.96), length: 0.06, thickness: 0.0032)
        leftBeam.position = leftOrigin - (leftFlight * 0.024)
        rightBeam.position = rightOrigin - (rightFlight * 0.024)
        leftBeam.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalized3(leftFlight + SIMD3<Float>(0, 0.03, 0), fallback: SIMD3<Float>(0, 1, 0)))
        rightBeam.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalized3(rightFlight + SIMD3<Float>(0, 0.03, 0), fallback: SIMD3<Float>(0, 1, 0)))
        boardRoot.addChild(leftBeam)
        boardRoot.addChild(rightBeam)

        let leftTransform = Transform(scale: leftBolt.scale, rotation: leftBolt.orientation, translation: target)
        let rightTransform = Transform(scale: rightBolt.scale, rotation: rightBolt.orientation, translation: target)
        leftBolt.move(to: leftTransform, relativeTo: leftBolt.parent, duration: 0.10, timingFunction: .linear)
        rightBolt.move(to: rightTransform, relativeTo: rightBolt.parent, duration: 0.10, timingFunction: .linear)

        let vaporized = transformed(
          victim.transform,
          translation: direction * 0.050 + SIMD3<Float>(0, 0.030, 0),
          scale: SIMD3<Float>(repeating: 0.18)
        )
        victim.move(to: vaporized, relativeTo: victim.parent, duration: 0.22, timingFunction: .easeIn)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [captureSoundEffects] in
          captureSoundEffects.play(.queenLaser)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak leftBolt, weak rightBolt, weak leftBeam, weak rightBeam] in
          leftBolt?.removeFromParent()
          rightBolt?.removeFromParent()
          leftBeam?.removeFromParent()
          rightBeam?.removeFromParent()
        }
      }

      try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @MainActor
    private func animateKingCrownCapture(attacker: Entity, victim: Entity?, move: ChessMove) async {
      let direction = attackDirection(for: move)
      if let crown = attacker.findEntity(named: "king_crown") {
        let thrown = transformed(
          crown.transform,
          translation: direction * 0.070 + SIMD3<Float>(0, 0.018, 0),
          rotation: simd_quatf(angle: .pi * 1.4, axis: SIMD3<Float>(0, 1, 0))
        )
        crown.move(to: thrown, relativeTo: attacker, duration: 0.16, timingFunction: .easeOut)
      }

      let originalAttacker = attacker.transform
      let lunge = transformed(originalAttacker, translation: direction * 0.022)
      attacker.move(to: lunge, relativeTo: attacker.parent, duration: 0.12, timingFunction: .easeIn)

      if let victim {
        let toppled = transformed(
          victim.transform,
          translation: direction * 0.070 + SIMD3<Float>(0, 0.024, 0),
          rotation: simd_quatf(angle: .pi / 3.5, axis: SIMD3<Float>(1, 0, 0))
        )
        victim.move(to: toppled, relativeTo: victim.parent, duration: 0.22, timingFunction: .easeOut)
      }

      try? await Task.sleep(nanoseconds: 320_000_000)
    }

    @MainActor
    private func showKnightCameraSplat(for piece: ChessPieceState, viewerColor: ChessColor) {
      guard let arView else {
        return
      }

      clearKnightCameraSplatOverlay(animated: false)
      let cameraMatrix = arView.session.currentFrame?.camera.transform ?? arView.cameraTransform.matrix
      let anchor = AnchorEntity(world: cameraMatrix)
      let splatPiece = piecePrototype(for: piece.kind, color: piece.color).clone(recursive: true)
      splatPiece.name = "knight_camera_splat_piece"
      anchor.addChild(splatPiece)
      arView.scene.addAnchor(anchor)
      knightCameraSplatAnchor = anchor
      knightCameraSplatEntity = splatPiece
      knightCameraSplatStartTime = CACurrentMediaTime()
      UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
      updateKnightCameraSplatTransform(viewerColor: viewerColor, elapsed: 0)

      let hideWorkItem = DispatchWorkItem { [weak self] in
        self?.clearKnightCameraSplatOverlay(animated: false)
      }
      knightCameraSplatHideWorkItem = hideWorkItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.15, execute: hideWorkItem)
    }

    @MainActor
    private func clearKnightCameraSplatOverlay(animated: Bool) {
      knightCameraSplatHideWorkItem?.cancel()
      knightCameraSplatHideWorkItem = nil
      knightCameraSplatStartTime = nil

      guard let splatAnchor = knightCameraSplatAnchor else {
        return
      }

      if animated, let splatPiece = knightCameraSplatEntity {
        var transform = splatPiece.transform
        transform.translation += SIMD3<Float>(0, 0.34, 0)
        transform.scale *= SIMD3<Float>(0.96, 0.96, 0.90)
        splatPiece.move(to: transform, relativeTo: splatPiece.parent, duration: 0.28, timingFunction: .easeIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
          splatAnchor.removeFromParent()
        }
      } else {
        splatAnchor.removeFromParent()
      }

      knightCameraSplatAnchor = nil
      knightCameraSplatEntity = nil
    }

    @MainActor
    private func updateKnightCameraSplatIfNeeded(_ frame: ARFrame) {
      guard let anchor = knightCameraSplatAnchor,
            let startedAt = knightCameraSplatStartTime else {
        return
      }

      anchor.setTransformMatrix(frame.camera.transform, relativeTo: nil)

      let elapsed = CACurrentMediaTime() - startedAt
      let viewerColor = boardViewerColor
      updateKnightCameraSplatTransform(viewerColor: viewerColor, elapsed: elapsed)
    }

    @MainActor
    private func updateKnightCameraSplatTransform(viewerColor: ChessColor, elapsed: CFTimeInterval) {
      guard let splatPiece = knightCameraSplatEntity else {
        return
      }

      let elapsed = Float(elapsed)
      let settleDuration: Float = 0.24
      let holdDuration: Float = 0.62
      let slideDuration: Float = 2.2
      let settleProgress = min(max(elapsed / settleDuration, 0), 1)
      let settleEased = 1 - pow(1 - settleProgress, 3)
      let slideStart = settleDuration + holdDuration
      let slideProgress = min(max((elapsed - slideStart) / slideDuration, 0), 1)
      let slideEased = slideProgress * slideProgress * (3 - (2 * slideProgress))
      let wobbleTime = max(0, elapsed - settleDuration)
      let wobble = sin(wobbleTime * 11) * 0.028 * exp(-wobbleTime * 5.4) * (1 - min(slideProgress, 1) * 0.8)

      let startPosition = SIMD3<Float>(0, 0.07, -0.48)
      let endPosition = SIMD3<Float>(0, 0.008, -0.145)
      let settledPosition = interpolatedVector(startPosition, endPosition, progress: settleEased) + SIMD3<Float>(0, wobble * 0.12, 0)
      let downwardTravel = SIMD3<Float>(0, 0.56, 0)
      let position = settledPosition + (downwardTravel * slideEased)

      let finalRotation = simd_normalize(
        simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: viewerColor == .black ? -0.08 : 0.08, axis: SIMD3<Float>(0, 0, 1))
      )
      let startRotation = simd_normalize(
        simd_quatf(angle: viewerColor == .black ? -0.82 : 0.82, axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: -.pi / 8, axis: SIMD3<Float>(1, 0, 0)) *
          finalRotation
      )
      let settledRotation = simd_slerp(startRotation, finalRotation, settleEased)
      let slideTilt = simd_normalize(
        simd_quatf(angle: -0.14 * slideEased, axis: SIMD3<Float>(1, 0, 0)) *
          simd_quatf(angle: (viewerColor == .black ? 0.11 : -0.11) * slideEased, axis: SIMD3<Float>(0, 0, 1))
      )
      let rotation = simd_normalize(slideTilt * settledRotation)

      let startScale = SIMD3<Float>(repeating: 0.86)
      let endScale = SIMD3<Float>(2.95, 2.95, 0.36)
      var scale = interpolatedVector(startScale, endScale, progress: settleEased)
      scale -= SIMD3<Float>(repeating: 0.18 * slideEased)
      scale.z = max(0.24, scale.z - (0.06 * slideEased) + abs(wobble) * 0.22)

      splatPiece.transform = Transform(scale: scale, rotation: rotation, translation: position)
    }

    private func interpolatedVector(
      _ from: SIMD3<Float>,
      _ to: SIMD3<Float>,
      progress: Float
    ) -> SIMD3<Float> {
      from + ((to - from) * progress)
    }

    private func attackDirection(for move: ChessMove) -> SIMD3<Float> {
      let squareSize = boardSize / 8.0
      let delta = boardPosition(move.to, squareSize: squareSize) - boardPosition(move.from, squareSize: squareSize)
      return normalized3(SIMD3<Float>(delta.x, 0, delta.z), fallback: SIMD3<Float>(0, 0, -1))
    }

    private func captureGhostFloatOffset() -> SIMD3<Float> {
      SIMD3<Float>(0, 0.26, 0)
    }

    private func normalized3(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
      let length = simd_length(value)
      guard length > 0.0001 else {
        return fallback
      }

      return value / length
    }

    private func transformed(
      _ transform: Transform,
      translation: SIMD3<Float> = .zero,
      rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
      scale: SIMD3<Float>? = nil
    ) -> Transform {
      var next = transform
      next.translation += translation
      next.rotation = simd_normalize(rotation * next.rotation)
      if let scale {
        next.scale = scale
      }
      return next
    }

    private func makeTracer(color: UIColor, length: Float, thickness: Float) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(thickness, length, thickness)),
        materials: [SimpleMaterial(color: color, roughness: 0.05, isMetallic: true)]
      )
    }

    private func canControlPiece(_ piece: ChessPieceState, at square: BoardSquare) -> Bool {
      if gameReview.isLoading {
        return false
      }

      guard piece.color == gameState.turn else {
        return false
      }

      if let checkpoint = gameReview.currentCheckpoint, gameReview.isReviewMode {
        _ = square
        return piece.color == checkpoint.playerColor && gameState.turn == checkpoint.playerColor
      }

      switch mode {
      case .lesson:
        guard let lesson = lessonStore.activeLesson,
              lessonStore.isAwaitingPlayerMove,
              lesson.studentColor == gameState.turn else {
          clearSelection()
          return false
        }
        return piece.color == lesson.studentColor
      case .passAndPlay(_):
        return true
      case .queueMatch:
        guard let assignedColor = queueAssignedColor,
              assignedColor == gameState.turn else {
          clearSelection()
          return false
        }
        return piece.color == assignedColor
      case .playVsStockfish(let configuration):
        guard configuration.humanColor == gameState.turn else {
          clearSelection()
          return false
        }
        return piece.color == configuration.humanColor
      }
    }

    private func animateKingPrayer(for color: ChessColor) {
      guard let kingEntity = kingEntity(for: color),
            let leftHand = kingEntity.findEntity(named: "king_hand_left"),
            let rightHand = kingEntity.findEntity(named: "king_hand_right") else {
        return
      }

      let originalKingTransform = kingEntity.transform
      let originalLeftTransform = leftHand.transform
      let originalRightTransform = rightHand.transform

      var bowedTransform = originalKingTransform
      bowedTransform.rotation = simd_normalize(
        simd_quatf(angle: -.pi / 12, axis: SIMD3<Float>(1, 0, 0)) * originalKingTransform.rotation
      )

      var prayingLeftTransform = originalLeftTransform
      prayingLeftTransform.translation = SIMD3<Float>(-0.006, 0.038, -0.007)
      prayingLeftTransform.rotation = simd_quatf(angle: .pi / 7, axis: SIMD3<Float>(0, 0, 1))

      var prayingRightTransform = originalRightTransform
      prayingRightTransform.translation = SIMD3<Float>(0.006, 0.038, -0.007)
      prayingRightTransform.rotation = simd_quatf(angle: -.pi / 7, axis: SIMD3<Float>(0, 0, 1))

      kingEntity.move(to: bowedTransform, relativeTo: kingEntity.parent, duration: 0.24, timingFunction: .easeInOut)
      leftHand.move(to: prayingLeftTransform, relativeTo: kingEntity, duration: 0.22, timingFunction: .easeInOut)
      rightHand.move(to: prayingRightTransform, relativeTo: kingEntity, duration: 0.22, timingFunction: .easeInOut)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak kingEntity, weak leftHand, weak rightHand] in
        guard let kingEntity, let leftHand, let rightHand else {
          return
        }

        kingEntity.move(to: originalKingTransform, relativeTo: kingEntity.parent, duration: 0.26, timingFunction: .easeInOut)
        leftHand.move(to: originalLeftTransform, relativeTo: kingEntity, duration: 0.24, timingFunction: .easeInOut)
        rightHand.move(to: originalRightTransform, relativeTo: kingEntity, duration: 0.24, timingFunction: .easeInOut)
      }
    }

    private func animateKingCrying(for color: ChessColor) {
      guard let kingEntity = kingEntity(for: color),
            let leftHand = kingEntity.findEntity(named: "king_hand_left"),
            let rightHand = kingEntity.findEntity(named: "king_hand_right"),
            let leftTear = kingEntity.findEntity(named: "king_tear_left"),
            let rightTear = kingEntity.findEntity(named: "king_tear_right") else {
        return
      }

      let originalKingTransform = kingEntity.transform
      let originalLeftTransform = leftHand.transform
      let originalRightTransform = rightHand.transform
      let originalLeftTearTransform = leftTear.transform
      let originalRightTearTransform = rightTear.transform

      var droopTransform = originalKingTransform
      droopTransform.rotation = simd_normalize(
        simd_quatf(angle: .pi / 13, axis: SIMD3<Float>(0, 0, 1)) *
          simd_quatf(angle: .pi / 16, axis: SIMD3<Float>(1, 0, 0)) *
          originalKingTransform.rotation
      )
      droopTransform.translation += SIMD3<Float>(0, -0.004, 0)

      var leftHandTransform = originalLeftTransform
      leftHandTransform.translation = SIMD3<Float>(-0.026, 0.021, -0.002)
      leftHandTransform.rotation = simd_quatf(angle: -.pi / 10, axis: SIMD3<Float>(0, 0, 1))

      var rightHandTransform = originalRightTransform
      rightHandTransform.translation = SIMD3<Float>(0.026, 0.021, -0.002)
      rightHandTransform.rotation = simd_quatf(angle: .pi / 10, axis: SIMD3<Float>(0, 0, 1))

      var leftTearTransform = originalLeftTearTransform
      leftTearTransform.scale = SIMD3<Float>(repeating: 1.0)
      leftTearTransform.translation = SIMD3<Float>(-0.009, 0.020, -0.013)

      var rightTearTransform = originalRightTearTransform
      rightTearTransform.scale = SIMD3<Float>(repeating: 1.0)
      rightTearTransform.translation = SIMD3<Float>(0.009, 0.020, -0.013)

      kingEntity.move(to: droopTransform, relativeTo: kingEntity.parent, duration: 0.20, timingFunction: .easeInOut)
      leftHand.move(to: leftHandTransform, relativeTo: kingEntity, duration: 0.18, timingFunction: .easeInOut)
      rightHand.move(to: rightHandTransform, relativeTo: kingEntity, duration: 0.18, timingFunction: .easeInOut)
      leftTear.move(to: leftTearTransform, relativeTo: kingEntity, duration: 0.12, timingFunction: .easeInOut)
      rightTear.move(to: rightTearTransform, relativeTo: kingEntity, duration: 0.12, timingFunction: .easeInOut)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak kingEntity, weak leftTear, weak rightTear] in
        guard let kingEntity, let leftTear, let rightTear else {
          return
        }

        var fallingLeft = leftTear.transform
        fallingLeft.translation += SIMD3<Float>(-0.004, -0.028, 0.002)
        fallingLeft.scale = SIMD3<Float>(repeating: 0.78)

        var fallingRight = rightTear.transform
        fallingRight.translation += SIMD3<Float>(0.004, -0.028, 0.002)
        fallingRight.scale = SIMD3<Float>(repeating: 0.78)

        leftTear.move(to: fallingLeft, relativeTo: kingEntity, duration: 0.28, timingFunction: .easeIn)
        rightTear.move(to: fallingRight, relativeTo: kingEntity, duration: 0.28, timingFunction: .easeIn)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) { [weak kingEntity, weak leftHand, weak rightHand, weak leftTear, weak rightTear] in
        guard let kingEntity, let leftHand, let rightHand, let leftTear, let rightTear else {
          return
        }

        kingEntity.move(to: originalKingTransform, relativeTo: kingEntity.parent, duration: 0.28, timingFunction: .easeInOut)
        leftHand.move(to: originalLeftTransform, relativeTo: kingEntity, duration: 0.24, timingFunction: .easeInOut)
        rightHand.move(to: originalRightTransform, relativeTo: kingEntity, duration: 0.24, timingFunction: .easeInOut)
        leftTear.move(to: originalLeftTearTransform, relativeTo: kingEntity, duration: 0.20, timingFunction: .easeInOut)
        rightTear.move(to: originalRightTearTransform, relativeTo: kingEntity, duration: 0.20, timingFunction: .easeInOut)
      }
    }

    private func activateKnightForkChains(on targetSquares: [BoardSquare]) {
      let normalizedTargets = targetSquares
      guard !normalizedTargets.isEmpty else {
        activeKnightForkBinding = nil
        return
      }

      if let attackedColor = normalizedTargets.compactMap({ gameState.board[$0]?.color }).first {
        activeKnightForkBinding = ActiveKnightForkBinding(
          targetSquares: normalizedTargets,
          clearsOnMoveBy: attackedColor
        )
      }

      for (index, square) in normalizedTargets.enumerated() {
        guard let victim = piecesContainer.findEntity(named: pieceName(square)),
              let piece = gameState.board[square] else {
          continue
        }

        attachKnightForkShackle(to: victim, piece: piece, seed: index, animated: true)
      }
    }

    private func attachKnightForkShackle(
      to victim: Entity,
      piece: ChessPieceState,
      seed: Int,
      animated: Bool
    ) {
      victim.findEntity(named: "knight_fork_shackle")?.removeFromParent()

      let shackle = makeKnightForkChainEntity(seed: seed)
      shackle.name = "knight_fork_shackle"
      let anchorHeight = knightForkChainAnchorHeight(for: piece.kind)
      let settledRotation = simd_quatf(angle: Float(seed + 1) * .pi / 12, axis: SIMD3<Float>(0, 1, 0))
      let settledTranslation = SIMD3<Float>(0, anchorHeight, 0)

      if animated {
        shackle.position = settledTranslation
        shackle.scale = SIMD3<Float>(repeating: 1.14)
        shackle.orientation = simd_quatf(angle: Float(seed) * .pi / 9, axis: SIMD3<Float>(0, 1, 0))
        victim.addChild(shackle)

        let settle = Transform(
          scale: SIMD3<Float>(repeating: 0.88),
          rotation: settledRotation,
          translation: settledTranslation
        )
        shackle.move(to: settle, relativeTo: victim, duration: 0.16, timingFunction: .easeOut)
      } else {
        shackle.position = settledTranslation
        shackle.scale = SIMD3<Float>(repeating: 0.88)
        shackle.orientation = settledRotation
        victim.addChild(shackle)
      }
    }

    private func attachPieceRoleAccessory(
      to pieceEntity: Entity,
      piece: ChessPieceState,
      roleType: PieceRoleType
    ) {
      pieceEntity.findEntity(named: "piece_role_accessory")?.removeFromParent()

      let accessory: Entity?
      switch roleType {
      case .employee:
        accessory = nil
      case .traitor:
        accessory = makeTraitorHornsEntity(for: piece.kind)
      case .lazy:
        accessory = makeLazyChipsEntity(for: piece.kind, handSide: pieceRoleCarryHand(for: piece.kind))
      case .worker:
        accessory = makeWorkerBriefcaseEntity(for: piece.kind, handSide: pieceRoleCarryHand(for: piece.kind))
      }

      guard let accessory else {
        return
      }

      accessory.name = "piece_role_accessory"
      if roleType == .lazy || roleType == .worker,
         let handEntity = pieceRoleHandEntity(in: pieceEntity, for: piece.kind, side: pieceRoleCarryHand(for: piece.kind)) {
        handEntity.addChild(accessory)
      } else {
        pieceEntity.addChild(accessory)
      }
    }

    private func makeTraitorHornsEntity(for kind: ChessPieceKind) -> Entity {
      let horns = Entity()
      horns.position = SIMD3<Float>(0, pieceRoleHeadHeight(for: kind), -0.003)
      let hornMaterial = accessoryMaterial(color: UIColor(red: 0.74, green: 0.12, blue: 0.12, alpha: 1), metallic: true)

      for side in [Float(-1), Float(1)] {
        let horn = Entity()
        horn.position = SIMD3<Float>(0.007 * side, 0, 0)
        horn.orientation = simd_normalize(
          simd_quatf(angle: side * (.pi / 9), axis: SIMD3<Float>(0, 0, 1)) *
            simd_quatf(angle: -.pi / 8, axis: SIMD3<Float>(1, 0, 0))
        )

        let base = ModelEntity(mesh: .generateSphere(radius: 0.003), materials: [hornMaterial])
        horn.addChild(base)

        let tip = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.0032, 0.011, 0.0032)),
          materials: [hornMaterial]
        )
        tip.position = SIMD3<Float>(0, 0.006, 0)
        horn.addChild(tip)

        horns.addChild(horn)
      }

      return horns
    }

    private func makeLazyChipsEntity(for kind: ChessPieceKind, handSide: PieceAccessoryHandSide) -> Entity {
      let chips = Entity()
      let handSign: Float = handSide == .left ? -1 : 1
      chips.position = SIMD3<Float>(0.0065 * handSign, -0.003, 0.011)
      chips.orientation = simd_normalize(
        simd_quatf(angle: handSign * (.pi / 7), axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: handSign * (.pi / 11), axis: SIMD3<Float>(0, 0, 1))
      )

      let bagMaterial = accessoryMaterial(color: UIColor(red: 0.93, green: 0.74, blue: 0.22, alpha: 1), metallic: false)
      let stripeMaterial = accessoryMaterial(color: UIColor(red: 0.81, green: 0.16, blue: 0.13, alpha: 1), metallic: false)
      let chipMaterial = accessoryMaterial(color: UIColor(red: 0.98, green: 0.90, blue: 0.64, alpha: 1), metallic: false)

      let bag = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.012, 0.016, 0.005)),
        materials: [bagMaterial]
      )
      chips.addChild(bag)

      let stripe = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.004, 0.0165, 0.0056)),
        materials: [stripeMaterial]
      )
      stripe.position = SIMD3<Float>(0.002, 0, 0.0006)
      chips.addChild(stripe)

      let chip = ModelEntity(mesh: .generateSphere(radius: 0.0024), materials: [chipMaterial])
      chip.scale = SIMD3<Float>(1.4, 0.4, 1.0)
      chip.position = SIMD3<Float>(-0.002, 0.010, 0.001)
      chips.addChild(chip)

      return chips
    }

    private func makeWorkerBriefcaseEntity(for kind: ChessPieceKind, handSide: PieceAccessoryHandSide) -> Entity {
      let briefcase = Entity()
      let handSign: Float = handSide == .left ? -1 : 1
      briefcase.position = SIMD3<Float>(0.006 * handSign, -0.004, 0.010)
      briefcase.orientation = simd_normalize(
        simd_quatf(angle: handSign * (.pi / 7), axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: handSign * (.pi / 16), axis: SIMD3<Float>(0, 0, 1))
      )

      let caseMaterial = accessoryMaterial(color: UIColor(red: 0.34, green: 0.20, blue: 0.10, alpha: 1), metallic: false)
      let latchMaterial = accessoryMaterial(color: UIColor(red: 0.84, green: 0.67, blue: 0.24, alpha: 1), metallic: true)

      let caseBody = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.014, 0.010, 0.006)),
        materials: [caseMaterial]
      )
      briefcase.addChild(caseBody)

      let handle = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.007, 0.002, 0.002)),
        materials: [caseMaterial]
      )
      handle.position = SIMD3<Float>(0, 0.007, 0)
      briefcase.addChild(handle)

      let latch = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.003, 0.003, 0.0014)),
        materials: [latchMaterial]
      )
      latch.position = SIMD3<Float>(0, 0, 0.0034)
      briefcase.addChild(latch)

      return briefcase
    }

    private func pieceRoleCarryHand(for kind: ChessPieceKind) -> PieceAccessoryHandSide {
      switch kind {
      case .pawn, .rook, .bishop:
        return .left
      case .knight, .queen, .king:
        return .right
      }
    }

    private func pieceRoleHandEntity(
      in pieceEntity: Entity,
      for kind: ChessPieceKind,
      side: PieceAccessoryHandSide
    ) -> Entity? {
      let name: String
      switch (kind, side) {
      case (.king, .left):
        name = "king_hand_left"
      case (.king, .right):
        name = "king_hand_right"
      case (_, .left):
        name = "piece_hand_left"
      case (_, .right):
        name = "piece_hand_right"
      }

      return pieceEntity.findEntity(named: name)
    }

    private func pieceRoleHeadHeight(for kind: ChessPieceKind) -> Float {
      switch kind {
      case .pawn:
        return 0.040
      case .rook:
        return 0.041
      case .knight:
        return 0.041
      case .bishop:
        return 0.055
      case .queen:
        return 0.049
      case .king:
        return 0.052
      }
    }

    private func knightForkChainAnchorHeight(for kind: ChessPieceKind) -> Float {
      switch kind {
      case .pawn:
        return 0.010
      case .knight:
        return 0.012
      case .bishop:
        return 0.015
      case .rook:
        return 0.015
      case .queen:
        return 0.017
      case .king:
        return 0.018
      }
    }

    private func makeKnightForkChainEntity(seed: Int) -> Entity {
      let shackle = Entity()
      let linkMaterial = SimpleMaterial(
        color: UIColor(red: 0.73, green: 0.72, blue: 0.66, alpha: 0.98),
        roughness: 0.12,
        isMetallic: true
      )
      let lockMaterial = SimpleMaterial(
        color: UIColor(red: 0.44, green: 0.37, blue: 0.22, alpha: 0.98),
        roughness: 0.18,
        isMetallic: true
      )

      func makeChainLink(width: Float, height: Float, thickness: Float) -> Entity {
        let link = Entity()
        let railThickness = thickness * 1.8
        let verticalHeight = Swift.max(Float(0.004), height - (thickness * 2.6))
        let horizontalWidth = Swift.max(Float(0.004), width - (thickness * 2.6))
        let verticalMesh = MeshResource.generateBox(
          size: SIMD3<Float>(railThickness, verticalHeight, thickness * 1.15)
        )
        let horizontalMesh = MeshResource.generateBox(
          size: SIMD3<Float>(horizontalWidth, railThickness, thickness * 1.15)
        )
        let cornerMesh = MeshResource.generateSphere(radius: thickness * 0.92)

        let leftRail = ModelEntity(mesh: verticalMesh, materials: [linkMaterial])
        leftRail.position = SIMD3<Float>(-(width * 0.5), 0, 0)
        let rightRail = ModelEntity(mesh: verticalMesh, materials: [linkMaterial])
        rightRail.position = SIMD3<Float>(width * 0.5, 0, 0)

        let topBridge = ModelEntity(mesh: horizontalMesh, materials: [linkMaterial])
        topBridge.position = SIMD3<Float>(0, height * 0.5, 0)
        topBridge.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let bottomBridge = ModelEntity(mesh: horizontalMesh, materials: [linkMaterial])
        bottomBridge.position = SIMD3<Float>(0, -(height * 0.5), 0)
        bottomBridge.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))

        link.addChild(leftRail)
        link.addChild(rightRail)
        link.addChild(topBridge)
        link.addChild(bottomBridge)

        let cornerOffsets: [SIMD3<Float>] = [
          SIMD3<Float>(-(width * 0.5), height * 0.5, 0),
          SIMD3<Float>(width * 0.5, height * 0.5, 0),
          SIMD3<Float>(-(width * 0.5), -(height * 0.5), 0),
          SIMD3<Float>(width * 0.5, -(height * 0.5), 0),
        ]
        for offset in cornerOffsets {
          let corner = ModelEntity(mesh: cornerMesh, materials: [linkMaterial])
          corner.position = offset
          link.addChild(corner)
        }

        return link
      }

      func makeChainBand(
        y: Float,
        ringRadiusX: Float,
        ringRadiusZ: Float,
        linkWidth: Float,
        linkHeight: Float,
        thickness: Float,
        linkCount: Int,
        yaw: Float
      ) -> Entity {
        let band = Entity()
        band.position = SIMD3<Float>(0, y, 0)
        band.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

        for index in 0..<linkCount {
          let angle = (Float(index) / Float(linkCount)) * (.pi * 2)
          let link = makeChainLink(width: linkWidth, height: linkHeight, thickness: thickness)
          link.position = SIMD3<Float>(
            cosf(angle) * ringRadiusX,
            index.isMultiple(of: 2) ? 0.0016 : -0.0016,
            sinf(angle) * ringRadiusZ
          )

          let tangentYaw = -angle + (.pi / 2)
          let interlockRoll: Float = index.isMultiple(of: 2) ? (.pi / 2.7) : (-.pi / 2.7)
          link.orientation = simd_normalize(
            simd_quatf(angle: tangentYaw, axis: SIMD3<Float>(0, 1, 0)) *
              simd_quatf(angle: interlockRoll, axis: SIMD3<Float>(0, 0, 1))
          )
          band.addChild(link)
        }

        return band
      }

      let lowerBand = makeChainBand(
        y: 0.012,
        ringRadiusX: 0.020,
        ringRadiusZ: 0.015,
        linkWidth: 0.007,
        linkHeight: 0.011,
        thickness: 0.00125,
        linkCount: 6,
        yaw: Float(seed) * .pi / 10
      )
      let upperBand = makeChainBand(
        y: 0.024,
        ringRadiusX: 0.018,
        ringRadiusZ: 0.0135,
        linkWidth: 0.0065,
        linkHeight: 0.010,
        thickness: 0.00115,
        linkCount: 5,
        yaw: (.pi / 9) + Float(seed) * .pi / 12
      )
      shackle.addChild(lowerBand)
      shackle.addChild(upperBand)

      let lock = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.0075, 0.0095, 0.0055)),
        materials: [lockMaterial]
      )
      lock.position = SIMD3<Float>(0.014, 0.018, 0.012)
      lock.orientation = simd_quatf(angle: .pi / 6, axis: SIMD3<Float>(0, 1, 0))
      shackle.addChild(lock)

      return shackle
    }

    private func kingEntity(for color: ChessColor) -> Entity? {
      guard let kingSquare = gameState.board.first(where: {
        $0.value.color == color && $0.value.kind == .king
      })?.key else {
        return nil
      }

      return piecesContainer.children.first(where: { $0.name == pieceName(kingSquare) })
    }

    private func updateBoardPlacement(session: ARSession, anchors: [ARAnchor]) {
      guard let frame = session.currentFrame else {
        return
      }

      guard boardAnchor == nil else {
        return
      }

      let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
      guard let selectedPlane = selectBestPlane(from: planes, frame: frame) else {
        return
      }

      boardScale = preferredInitialBoardScale(for: selectedPlane)
      let transform = boardTransform(for: selectedPlane, frame: frame)
      prepareBoardSceneIfNeeded(force: !hasPreparedBoardScene)

      if let arView {
        let boardAnchor = AnchorEntity(world: transform)
        applyBoardScale()
        boardAnchor.addChild(makeScenicBackdropEntity())
        boardAnchor.addChild(boardRoot)
        arView.scene.addAnchor(boardAnchor)
        self.boardAnchor = boardAnchor
        boardWorldTransform = transform
        applySceneBackground(for: arView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          AmbientMusicController.shared.playLoopIfNeeded()
        }
      }

      trackedPlaneID = selectedPlane.identifier
      maybeRequestLessonIntroIfNeeded()
      maybeScheduleInitialAnalysis()
      syncLessonAutoplayIfNeeded()
      syncAutomatedOpponentTurnIfNeeded()
    }

    private func updateTrackingReadiness(_ frame: ARFrame) {
      let trackingIsStable: Bool
      switch frame.camera.trackingState {
      case .normal:
        trackingIsStable = true
      default:
        trackingIsStable = false
      }

      if trackingIsStable {
        stableTrackingFrames += 1
      } else {
        stableTrackingFrames = 0
      }

      if boardAnchor == nil {
        noteWarmupStatus(
          mode.warmsStockfishAnalysis
            ? "Scanning for board placement. Local Stockfish is warming in the background..."
            : "Waiting for board placement to start the lesson..."
        )
      } else if stableTrackingFrames < 60 {
        noteWarmupStatus(
          mode.warmsStockfishAnalysis
            ? "Board placed. Waiting for AR tracking to stabilize..."
            : "Waiting for AR tracking to stabilize before starting the lesson..."
        )
      } else {
        maybeScheduleInitialAnalysis()
      }
    }

    private func maybeScheduleInitialAnalysis() {
      guard mode.warmsStockfishAnalysis else {
        noteWarmupStatus("Lesson board ready. Predict the next move.")
        return
      }

      guard !hasScheduledInitialAnalysis else {
        return
      }

      guard boardAnchor != nil else {
        return
      }

      guard stableTrackingFrames >= 60 else {
        return
      }

      hasScheduledInitialAnalysis = true
      initialAnalysisTask?.cancel()
      initialAnalysisTask = nil
      commentary.prepareEngineIfNeeded()
      noteWarmupStatus("Board ready. Local Stockfish is standing by.")
    }

    private func applySceneBackground(for arView: ARView) {
      if boardAnchor == nil {
        arView.environment.background = .cameraFeed()
      } else {
        arView.environment.background = .color(Self.scenicSkyColor)
      }
    }

    private func noteWarmupStatus(_ message: String) {
      guard lastWarmupStatusMessage != message else {
        return
      }

      lastWarmupStatusMessage = message
      Task { @MainActor [weak self] in
        self?.commentary.noteWarmupStatus(message)
      }
    }

    private func selectBestPlane(from planes: [ARPlaneAnchor], frame: ARFrame) -> ARPlaneAnchor? {
      let candidates = planes.filter { isSuitableTablePlane($0, frame: frame) }
      guard !candidates.isEmpty else {
        return nil
      }

      if let trackedPlaneID,
         let tracked = candidates.first(where: { $0.identifier == trackedPlaneID }) {
        return tracked
      }

      return candidates.max(by: { planeScore($0, frame: frame) < planeScore($1, frame: frame) })
    }

    private func isSuitableTablePlane(_ plane: ARPlaneAnchor, frame: ARFrame) -> Bool {
      guard plane.alignment == .horizontal else {
        return false
      }

      let minExtent = (boardSize * minimumBoardScale) + (boardInset * 2)
      guard plane.extent.x >= minExtent, plane.extent.z >= minExtent else {
        return false
      }

      let cameraY = frame.camera.transform.columns.3.y
      let planeY = plane.transform.columns.3.y
      let verticalDrop = cameraY - planeY

      // Beds and rough cloth-covered tables often classify as unknown or floor
      // even when they are usable flat placement surfaces.
      return verticalDrop > 0.05 && verticalDrop < 1.50 && !isCeilingClassification(plane.classification)
    }

    private func planeScore(_ plane: ARPlaneAnchor, frame: ARFrame) -> Float {
      let area = plane.extent.x * plane.extent.z
      let cameraPosition = simd_make_float3(frame.camera.transform.columns.3)
      let planePosition = simd_make_float3(plane.transform.columns.3)
      let distance = simd_distance(cameraPosition, planePosition)
      let classificationBonus: Float = isTableClassification(plane.classification) ? 2.0 : 0.0
      return classificationBonus + area - (distance * 0.35)
    }

    private func isTableClassification(_ classification: ARPlaneAnchor.Classification) -> Bool {
      switch classification {
      case ARPlaneAnchor.Classification.table:
        return true
      default:
        return false
      }
    }

    private func isCeilingClassification(_ classification: ARPlaneAnchor.Classification) -> Bool {
      switch classification {
      case ARPlaneAnchor.Classification.ceiling:
        return true
      default:
        return false
      }
    }

    private func boardTransform(for plane: ARPlaneAnchor, frame: ARFrame) -> simd_float4x4 {
      let planeTransform = plane.transform
      let cameraWorld = simd_make_float3(frame.camera.transform.columns.3)
      let cameraForward = simd_normalize(-simd_make_float3(frame.camera.transform.columns.2))
      let inversePlane = planeTransform.inverse
      let planeHeight = planeTransform.columns.3.y
      let scaledBoardSize = boardSize * boardScale

      let availableX = max(0, (plane.extent.x * 0.5) - (scaledBoardSize * 0.5) - boardInset)
      let availableZ = max(0, (plane.extent.z * 0.5) - (scaledBoardSize * 0.5) - boardInset)

      let horizontalForward = normalized(
        SIMD2<Float>(cameraForward.x, cameraForward.z),
        fallback: SIMD2<Float>(0, -1)
      )
      let cameraHeightAbovePlane = max(0.18, cameraWorld.y - planeHeight)
      let preferredViewAngleRadians: Float = 30.0 * .pi / 180.0
      let preferredDistance = cameraHeightAbovePlane / tan(preferredViewAngleRadians)
      let stableFrontDistance = clamp(preferredDistance + 0.12, min: 0.58, max: 0.82)
      let targetWorld = SIMD3<Float>(
        cameraWorld.x + (horizontalForward.x * stableFrontDistance),
        planeHeight,
        cameraWorld.z + (horizontalForward.y * stableFrontDistance)
      )

      let targetLocal4 = inversePlane * SIMD4<Float>(targetWorld.x, targetWorld.y, targetWorld.z, 1)
      let localPosition = SIMD3<Float>(
        clamp(targetLocal4.x, min: -availableX, max: availableX),
        0.012,
        clamp(targetLocal4.z, min: -availableZ, max: availableZ)
      )

      let worldPosition4 = planeTransform * SIMD4<Float>(localPosition.x, localPosition.y, localPosition.z, 1)
      let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)

      let lookVector = normalized(
        SIMD2<Float>(cameraWorld.x - worldPosition.x, cameraWorld.z - worldPosition.z),
        fallback: SIMD2<Float>(-horizontalForward.x, -horizontalForward.y)
      )
      let yaw = atan2(lookVector.x, lookVector.y) + .pi
      var result = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
      result.columns.3 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
      return result
    }

    private func preferredInitialBoardScale(for plane: ARPlaneAnchor) -> Float {
      let usableWidth = max(0, plane.extent.x - (boardInset * 2))
      let usableDepth = max(0, plane.extent.z - (boardInset * 2))
      let widthScale = usableWidth / boardSize
      let depthScale = usableDepth / boardSize
      let fitScale = min(widthScale, depthScale, 1.0)
      return clamp(fitScale, min: minimumBoardScale, max: 1.0)
    }

    private func normalized(_ value: SIMD2<Float>, fallback: SIMD2<Float>) -> SIMD2<Float> {
      let length = simd_length(value)
      guard length > 0.0001 else {
        return fallback
      }

      return value / length
    }

    private func clamp(_ value: Float, min lower: Float, max upper: Float) -> Float {
      Swift.max(lower, Swift.min(upper, value))
    }

    private func makeBoardEntity() -> Entity {
      let boardRoot = Entity()
      boardRoot.scale = SIMD3<Float>(repeating: boardScale)
      self.boardRoot = boardRoot
      piecesContainer = Entity()
      captureGhostContainer = Entity()
      highlightsContainer = Entity()
      threatOverlayContainer = Entity()
      activeThreatEntities = []

      let squareSize = boardSize / 8.0
      let baseEntity = Self.boardBasePrototype.clone(recursive: false)
      baseEntity.position = SIMD3<Float>(0, -0.010, 0)
      boardRoot.addChild(baseEntity)

      for rank in 0..<8 {
        for file in 0..<8 {
          let squareEntity = ((rank + file).isMultiple(of: 2)
            ? Self.darkSquarePrototype
            : Self.lightSquarePrototype
          ).clone(recursive: false)
          let square = BoardSquare(file: file, rank: rank)
          squareEntity.position = boardPosition(square, squareSize: squareSize)
          squareEntity.name = squareName(square)
          boardRoot.addChild(squareEntity)
        }
      }

      boardRoot.addChild(captureGhostContainer)
      boardRoot.addChild(threatOverlayContainer)
      boardRoot.addChild(highlightsContainer)
      boardRoot.addChild(piecesContainer)
      return boardRoot
    }

    private func makeScenicBackdropEntity() -> Entity {
      let backdrop = Entity()
      backdrop.name = "scenic_backdrop"

      let meadowBase = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(7.4, 0.10, 7.4)),
        materials: [Self.scenicMaterial(UIColor(red: 0.34, green: 0.48, blue: 0.22, alpha: 1), roughness: 1.0)]
      )
      meadowBase.position = SIMD3<Float>(0, -0.115, 0)
      backdrop.addChild(meadowBase)

      let meadowAccent = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(5.8, 0.042, 5.8)),
        materials: [Self.scenicMaterial(UIColor(red: 0.42, green: 0.58, blue: 0.28, alpha: 1), roughness: 1.0)]
      )
      meadowAccent.position = SIMD3<Float>(0, -0.062, 0)
      meadowAccent.orientation = simd_quatf(angle: .pi / 7.0, axis: SIMD3<Float>(0, 1, 0))
      backdrop.addChild(meadowAccent)

      let pond = makeFishingPondEntity()
      pond.position = fishingPondOffset()
      backdrop.addChild(pond)

      for index in 0..<12 {
        let angle = (Float(index) * 30.0) + (index.isMultiple(of: 2) ? 8.0 : -10.0)
        let radius: Float = index.isMultiple(of: 2) ? 3.15 : 3.45
        let width: Float = 1.05 + (Float(index % 3) * 0.22)
        let height: Float = 0.88 + (Float((index + 1) % 4) * 0.18)
        let depth: Float = 0.92 + (Float(index % 2) * 0.22)
        let mountain = makeMountainEntity(
          size: SIMD3<Float>(width, height, depth),
          baseColor: UIColor(red: 0.40, green: 0.53, blue: 0.53, alpha: 1),
          ridgeColor: UIColor(red: 0.66, green: 0.76, blue: 0.77, alpha: 1),
          snowCapColor: UIColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1)
        )
        mountain.position = ringPosition(radius: radius, degrees: angle, height: -0.03)
        backdrop.addChild(mountain)
      }

      for index in 0..<10 {
        let angle = (Float(index) * 36.0) + (index.isMultiple(of: 2) ? 18.0 : -14.0)
        let radius: Float = 4.45 + (Float(index % 2) * 0.28)
        let width: Float = 1.75 + (Float(index % 3) * 0.34)
        let height: Float = 1.35 + (Float(index % 4) * 0.22)
        let depth: Float = 1.28 + (Float((index + 1) % 3) * 0.20)
        let mountain = makeMountainEntity(
          size: SIMD3<Float>(width, height, depth),
          baseColor: UIColor(red: 0.31, green: 0.42, blue: 0.50, alpha: 1),
          ridgeColor: UIColor(red: 0.54, green: 0.65, blue: 0.72, alpha: 1),
          snowCapColor: UIColor(red: 0.93, green: 0.96, blue: 0.99, alpha: 1)
        )
        mountain.position = ringPosition(radius: radius, degrees: angle, height: 0.00)
        backdrop.addChild(mountain)
      }

      let clusterAngles: [Float] = [-162, -132, -102, -72, -42, -12, 18, 48, 78, 108, 138, 168]
      for (index, angle) in clusterAngles.enumerated() {
        let radius: Float = 1.62 + (Float(index % 3) * 0.18)
        let cluster = makeTreeClusterEntity(
          radius: radius,
          degrees: angle,
          scale: 0.92 + (Float(index % 4) * 0.08),
          trunkColor: UIColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 1),
          foliageColors: [
            UIColor(red: 0.13, green: 0.30, blue: 0.16, alpha: 1),
            UIColor(red: 0.18, green: 0.39, blue: 0.19, alpha: 1),
            UIColor(red: 0.24, green: 0.47, blue: 0.23, alpha: 1),
          ]
        )
        backdrop.addChild(cluster)
      }

      let cloudAngles: [Float] = [-122, -34, 44, 118]
      for (index, angle) in cloudAngles.enumerated() {
        let cluster = makeCloudClusterEntity(
          radius: 2.7 + (Float(index) * 0.22),
          degrees: angle,
          height: 1.42 + (Float(index % 2) * 0.18),
          scale: 0.88 + (Float(index) * 0.06)
        )
        backdrop.addChild(cluster)
      }

      return backdrop
    }

    private func makeMountainEntity(
      size: SIMD3<Float>,
      baseColor: UIColor,
      ridgeColor: UIColor,
      snowCapColor: UIColor
    ) -> Entity {
      let mountain = Entity()

      let base = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(baseColor, roughness: 0.98)]
      )
      base.scale = size
      base.position = SIMD3<Float>(0, (size.y * 0.28) - 0.10, 0)
      mountain.addChild(base)

      let ridge = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(ridgeColor, roughness: 0.96)]
      )
      ridge.scale = SIMD3<Float>(size.x * 0.56, size.y * 0.56, size.z * 0.52)
      ridge.position = SIMD3<Float>(size.x * 0.10, size.y * 0.52, -size.z * 0.08)
      mountain.addChild(ridge)

      let shoulder = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(baseColor.withAlphaComponent(0.98), roughness: 0.99)]
      )
      shoulder.scale = SIMD3<Float>(size.x * 0.38, size.y * 0.38, size.z * 0.42)
      shoulder.position = SIMD3<Float>(-size.x * 0.16, size.y * 0.34, size.z * 0.12)
      mountain.addChild(shoulder)

      let snowCap = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(snowCapColor, roughness: 0.92)]
      )
      snowCap.scale = SIMD3<Float>(size.x * 0.18, size.y * 0.16, size.z * 0.18)
      snowCap.position = SIMD3<Float>(size.x * 0.08, size.y * 0.78, -size.z * 0.03)
      mountain.addChild(snowCap)

      return mountain
    }

    private func makeTreeClusterEntity(
      radius: Float,
      degrees: Float,
      scale: Float,
      trunkColor: UIColor,
      foliageColors: [UIColor]
    ) -> Entity {
      let cluster = Entity()
      let center = ringPosition(radius: radius, degrees: degrees, height: -0.042)
      let radial = normalized(SIMD2<Float>(center.x, center.z), fallback: SIMD2<Float>(0, 1))
      let tangent = SIMD2<Float>(-radial.y, radial.x)
      let offsets: [(Float, Float, Float, UIColor)] = [
        (-0.08, -0.11, scale * 0.96, foliageColors[0]),
        (0.02, 0.00, scale * 1.10, foliageColors[1]),
        (0.10, 0.13, scale * 0.90, foliageColors[2]),
      ]

      for (radialOffset, tangentOffset, treeScale, foliageColor) in offsets {
        let position2D = SIMD2<Float>(
          center.x + (radial.x * radialOffset) + (tangent.x * tangentOffset),
          center.z + (radial.y * radialOffset) + (tangent.y * tangentOffset)
        )
        let tree = makeForestTreeEntity(
          scale: treeScale,
          trunkColor: trunkColor,
          foliageColor: foliageColor
        )
        tree.position = SIMD3<Float>(position2D.x, center.y, position2D.y)
        cluster.addChild(tree)
      }

      return cluster
    }

    private func makeForestTreeEntity(scale: Float, trunkColor: UIColor, foliageColor: UIColor) -> Entity {
      let tree = Entity()
      let trunkHeight: Float = 0.18 * scale

      let trunk = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.032 * scale, trunkHeight, 0.032 * scale)),
        materials: [Self.scenicMaterial(trunkColor, roughness: 1.0)]
      )
      trunk.position = SIMD3<Float>(0, trunkHeight * 0.5, 0)
      tree.addChild(trunk)

      let lowerCanopy = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(foliageColor, roughness: 0.97)]
      )
      lowerCanopy.scale = SIMD3<Float>(0.26 * scale, 0.22 * scale, 0.26 * scale)
      lowerCanopy.position = SIMD3<Float>(0, trunkHeight + (0.11 * scale), 0)
      tree.addChild(lowerCanopy)

      let middleCanopy = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(foliageColor.withAlphaComponent(0.98), roughness: 0.96)]
      )
      middleCanopy.scale = SIMD3<Float>(0.22 * scale, 0.19 * scale, 0.22 * scale)
      middleCanopy.position = SIMD3<Float>(0.01 * scale, trunkHeight + (0.22 * scale), -0.01 * scale)
      tree.addChild(middleCanopy)

      let upperCanopy = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.28, green: 0.50, blue: 0.24, alpha: 1), roughness: 0.95)]
      )
      upperCanopy.scale = SIMD3<Float>(0.17 * scale, 0.15 * scale, 0.17 * scale)
      upperCanopy.position = SIMD3<Float>(-0.006 * scale, trunkHeight + (0.31 * scale), 0.008 * scale)
      tree.addChild(upperCanopy)

      return tree
    }

    private func makeCloudClusterEntity(radius: Float, degrees: Float, height: Float, scale: Float) -> Entity {
      let cluster = Entity()
      let center = ringPosition(radius: radius, degrees: degrees, height: height)
      let puffOffsets: [SIMD3<Float>] = [
        SIMD3<Float>(-0.20 * scale, 0.00, 0.00),
        SIMD3<Float>(0.00, 0.06 * scale, 0.02 * scale),
        SIMD3<Float>(0.22 * scale, 0.01 * scale, -0.03 * scale),
      ]
      let puffScales: [SIMD3<Float>] = [
        SIMD3<Float>(0.36 * scale, 0.20 * scale, 0.22 * scale),
        SIMD3<Float>(0.42 * scale, 0.24 * scale, 0.24 * scale),
        SIMD3<Float>(0.30 * scale, 0.18 * scale, 0.18 * scale),
      ]

      for index in 0..<puffOffsets.count {
        let puff = ModelEntity(
          mesh: .generateSphere(radius: 0.5),
          materials: [Self.scenicMaterial(UIColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.94), roughness: 1.0)]
        )
        puff.scale = puffScales[index]
        puff.position = center + puffOffsets[index]
        cluster.addChild(puff)
      }

      return cluster
    }

    private func ringPosition(radius: Float, degrees: Float, height: Float) -> SIMD3<Float> {
      let radians = degrees * Float.pi / 180.0
      return SIMD3<Float>(sin(radians) * radius, height, cos(radians) * radius)
    }

    private func fishingPondOffset() -> SIMD3<Float> {
      let halfBoardWidth = (boardSize * boardScale) * 0.5
      let lateralDistance = max(halfBoardWidth + 0.70, 0.92)
      return SIMD3<Float>(-lateralDistance, Self.fishingPondVerticalOffset, 0.04)
    }

    @MainActor
    private func updateFishingPondPlacement() {
      fishingPondEntity?.position = fishingPondOffset()
    }

    private static func scenicMaterial(_ color: UIColor, roughness: Float) -> SimpleMaterial {
      SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: false)
    }

    private func makeFishingPondEntity() -> Entity {
      let pond = Entity()
      pond.name = "fishing_pond"

      let shoreline = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.20, green: 0.28, blue: 0.30, alpha: 1), roughness: 0.98)]
      )
      shoreline.position = SIMD3<Float>(0, 0.010, 0)
      shoreline.scale = SIMD3<Float>(1.02, 0.018, 1.02)
      pond.addChild(shoreline)

      let water = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.18, green: 0.66, blue: 0.98, alpha: 0.98), roughness: 0.04)]
      )
      water.position = SIMD3<Float>(0, 0.022, 0)
      water.scale = SIMD3<Float>(0.94, 0.018, 0.94)
      pond.addChild(water)
      fishingPondEntity = pond
      fishingPondWaterEntity = water

      let deepWater = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.08, green: 0.36, blue: 0.72, alpha: 1.0), roughness: 0.03)]
      )
      deepWater.position = SIMD3<Float>(0, 0.026, 0)
      deepWater.scale = SIMD3<Float>(0.72, 0.010, 0.72)
      pond.addChild(deepWater)

      let shimmer = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.84, green: 0.96, blue: 1.0, alpha: 0.56), roughness: 0.01)]
      )
      shimmer.position = SIMD3<Float>(0.10, 0.031, -0.06)
      shimmer.scale = SIMD3<Float>(0.42, 0.002, 0.26)
      shimmer.orientation = simd_quatf(angle: .pi / 16, axis: SIMD3<Float>(0, 1, 0))
      pond.addChild(shimmer)

      let secondaryShimmer = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.76, green: 0.92, blue: 1.0, alpha: 0.34), roughness: 0.01)]
      )
      secondaryShimmer.position = SIMD3<Float>(-0.16, 0.030, 0.10)
      secondaryShimmer.scale = SIMD3<Float>(0.26, 0.002, 0.16)
      secondaryShimmer.orientation = simd_quatf(angle: -.pi / 12, axis: SIMD3<Float>(0, 1, 0))
      pond.addChild(secondaryShimmer)

      let lilyPadColor = UIColor(red: 0.52, green: 0.80, blue: 0.26, alpha: 1)
      let lilyPads: [(position: SIMD3<Float>, scale: SIMD3<Float>, yaw: Float)] = [
        (SIMD3<Float>(-0.20, 0.031, 0.14), SIMD3<Float>(1.05, 1.0, 0.78), -.pi / 8),
        (SIMD3<Float>(0.22, 0.031, -0.05), SIMD3<Float>(1.18, 1.0, 0.86), .pi / 6),
        (SIMD3<Float>(0.04, 0.031, 0.24), SIMD3<Float>(0.92, 1.0, 0.72), .pi / 10),
      ]
      for lilyPadSpec in lilyPads {
        let lilyPad = ModelEntity(
          mesh: .generateSphere(radius: 0.5),
          materials: [Self.scenicMaterial(lilyPadColor, roughness: 0.92)]
        )
        lilyPad.scale = SIMD3<Float>(0.104, 0.004, 0.104) * lilyPadSpec.scale
        lilyPad.position = lilyPadSpec.position
        lilyPad.orientation = simd_quatf(angle: lilyPadSpec.yaw, axis: SIMD3<Float>(0, 1, 0))
        pond.addChild(lilyPad)
      }

      let shoreRockColor = UIColor(red: 0.51, green: 0.49, blue: 0.44, alpha: 1)
      let rockAngles: [Float] = [-146, -88, -26, 24, 72, 132]
      for (index, angle) in rockAngles.enumerated() {
        let rock = ModelEntity(
          mesh: .generateSphere(radius: 0.5),
          materials: [Self.scenicMaterial(shoreRockColor, roughness: 0.98)]
        )
        rock.scale = SIMD3<Float>(
          0.08 + (Float(index % 2) * 0.02),
          0.05 + (Float(index % 3) * 0.01),
          0.07 + (Float((index + 1) % 2) * 0.02)
        )
        let radians = angle * Float.pi / 180.0
        rock.position = SIMD3<Float>(sin(radians) * 0.60, 0.038, cos(radians) * 0.60)
        pond.addChild(rock)
      }

      let fin = makeFishingPondFinEntity()
      pond.addChild(fin)
      fishingPondFinEntity = fin
      let initialFinPosition = randomFishingPondFinLocalPoint()
      fin.position = initialFinPosition
      resetFishingPondFinPath(from: initialFinPosition)

      return pond
    }

    private func makeFishingPondFinEntity() -> Entity {
      let fin = Entity()
      fin.name = "fishing_pond_fin"

      let dorsal = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.016, 0.055, 0.010)),
        materials: [Self.scenicMaterial(UIColor(red: 0.22, green: 0.28, blue: 0.34, alpha: 1), roughness: 0.80)]
      )
      dorsal.position = SIMD3<Float>(0, 0, 0)
      dorsal.orientation = simd_quatf(angle: .pi / 10, axis: SIMD3<Float>(0, 0, 1))
      fin.addChild(dorsal)

      return fin
    }

    @MainActor
    private func beginFishingInteraction() {
      guard let arView,
            let frame = arView.session.currentFrame,
            let pondTarget = fishingPondCastTargetWorldPosition() else {
        return
      }

      cancelFishingTasks()
      clearFishingWorldPresentation()
      fishingSequenceID += 1
      let sequenceID = fishingSequenceID
      fishingBobberCastCompletedAt = nil
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()

      createFishingRodAnchor(cameraMatrix: frame.camera.transform)
      animateFishingRod(
        to: fishingCastTransform(cameraMatrix: frame.camera.transform, pondTarget: pondTarget),
        duration: 0.34,
        timingFunction: .easeInOut
      )
      castFishingBobber(to: pondTarget)

      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 780_000_000)
        guard let self,
              self.fishingSequenceID == sequenceID,
              self.fishing.state == .casting else {
          return
        }
        self.fishing.setWaiting()
        self.fishingBobberCastCompletedAt = CACurrentMediaTime()
        self.animateFishingRod(
          to: self.currentFishingWaitingTransform(),
          duration: 0.28,
          timingFunction: .easeOut
        )
      }

      let biteDelay = Double.random(in: Self.fishingBiteDelayRangeSeconds)
      fishingBiteTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(biteDelay * 1_000_000_000))
        guard let self,
              self.fishingSequenceID == sequenceID,
              self.fishing.state == .waiting else {
          return
        }
        self.registerFishingBite(sequenceID: sequenceID)
      }
    }

    @MainActor
    private func registerFishingBite(sequenceID: Int) {
      guard fishingSequenceID == sequenceID else {
        return
      }

      fishing.setBite()
      UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
      animateFishingRod(to: currentFishingBiteTransform(), duration: 0.11, timingFunction: .easeIn)
      animateFishingBobberBite()

      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 230_000_000)
        guard let self,
              self.fishingSequenceID == sequenceID,
              self.fishing.state == .bite else {
          return
        }
        self.fishing.setCatchWindow()
        self.animateFishingRod(
          to: self.currentFishingWaitingTransform(),
          duration: 0.20,
          timingFunction: .easeOut
        )
      }

      fishingCatchWindowTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(Self.fishingCatchWindowSeconds * 1_000_000_000))
        guard let self,
              self.fishingSequenceID == sequenceID,
              self.fishing.canAcceptCatchFlick else {
          return
        }
        self.failFishingCatch()
      }
    }

    @MainActor
    private func handleFishingCatchFlick() {
      guard fishing.canAcceptCatchFlick else {
        return
      }

      fishingCatchWindowTask?.cancel()
      fishingCatchWindowTask = nil
      fishingBiteTask?.cancel()
      fishingBiteTask = nil
      fishing.setCaught()
      UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
      animateFishingRod(to: currentFishingCatchPullTransform(), duration: 0.18, timingFunction: .easeIn)
      animateFishingBobberHookLift()
      spawnFishingCatch()
    }

    @MainActor
    private func failFishingCatch() {
      resetFishingInteraction(message: "Too slow. The fish slipped away.")
    }

    @MainActor
    private func dismissFishingRewardNote() {
      resetFishingInteraction(message: "Packing the rod away.")
    }

    @MainActor
    private func resetFishingInteraction(message: String) {
      cancelFishingTasks()
      fishingSequenceID += 1
      fishing.setResetStatus(message)
      clearFishingWorldPresentation()

      let sequenceID = fishingSequenceID
      fishingResetTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 540_000_000)
        guard let self,
              self.fishingSequenceID == sequenceID else {
          return
        }
        self.fishing.finishReset()
      }
    }

    private func cancelFishingTasks() {
      fishingBiteTask?.cancel()
      fishingBiteTask = nil
      fishingCatchWindowTask?.cancel()
      fishingCatchWindowTask = nil
      fishingRevealTask?.cancel()
      fishingRevealTask = nil
      fishingResetTask?.cancel()
      fishingResetTask = nil
    }

    @MainActor
    private func clearFishingWorldPresentation() {
      fishingRodAnchor?.removeFromParent()
      fishingRodAnchor = nil
      fishingRigEntity = nil
      fishingRodEntity = nil
      fishingLeftHandEntity = nil
      fishingRightHandEntity = nil
      fishingRodTipEntity = nil
      fishingCastLineAnchor?.removeFromParent()
      fishingCastLineAnchor = nil
      fishingCastLineEntity = nil
      fishingBobberAnchor?.removeFromParent()
      fishingBobberAnchor = nil
      fishingBobberEntity = nil
      fishingFishAnchor?.removeFromParent()
      fishingFishAnchor = nil
      fishingFishEntity = nil
      fishingFishFloatStartedAt = nil
      fishingBobberCastCompletedAt = nil
      baselineFishingOrientation = nil
      baselineFishingDownwardPitch = nil
    }

    @MainActor
    private func updateFishingInteraction(_ frame: ARFrame) {
      updatePondFocusState(frame)
      updateFishingRodCameraFollow(frame)
      updateFishingPondSurfaceMotion()
      updateFishingCastLine()
      updateFishingBobberIdleMotion()
      updateFishingCaughtFishMotion()
    }

    @MainActor
    private func updatePondFocusState(_ frame: ARFrame) {
      guard let pondTarget = fishingPondCastTargetWorldPosition() else {
        fishing.updatePondFocus(false)
        return
      }

      let cameraPosition = simd_make_float3(frame.camera.transform.columns.3)
      let cameraForward = normalized3(-simd_make_float3(frame.camera.transform.columns.2), fallback: SIMD3<Float>(0, 0, -1))
      let toPond = pondTarget - cameraPosition
      let distance = simd_length(toPond)
      guard distance > 0.001 else {
        fishing.updatePondFocus(false)
        return
      }

      let alignment = simd_dot(cameraForward, toPond / distance)
      fishing.updatePondFocus(
        distance <= Self.fishingPondFocusDistance &&
          alignment >= Self.fishingLookAlignmentThreshold
      )
    }

    @MainActor
    private func updateFishingRodCameraFollow(_ frame: ARFrame) {
      let shouldShowRig =
        (fishing.state == .eligible && fishing.isPondInFocus) ||
        fishing.state == .casting ||
        fishing.state == .waiting ||
        fishing.state == .bite ||
        fishing.state == .catchWindow ||
        fishing.state == .caught

      guard shouldShowRig else {
        if fishingRodAnchor != nil || fishingRigEntity != nil {
          clearFishingHeldRodPreview()
        }
        return
      }

      if fishingRodAnchor == nil || fishingRigEntity == nil || fishingRodEntity == nil {
        createFishingRodAnchor(cameraMatrix: frame.camera.transform)
      }

      guard let rig = fishingRigEntity else {
        return
      }

      switch fishing.state {
      case .eligible:
        rig.transform = fishingHeldTransform(cameraMatrix: frame.camera.transform)
      case .waiting, .catchWindow:
        rig.transform = fishingWaitingTransform(cameraMatrix: frame.camera.transform)
      case .caught:
        rig.transform = fishingCatchPullTransform(cameraMatrix: frame.camera.transform)
      case .casting, .bite, .idle, .revealNote, .reset:
        break
      }
    }

    @MainActor
    private func updateFishingBobberIdleMotion() {
      guard fishing.state == .waiting,
            let bobber = fishingBobberEntity,
            let startedAt = fishingBobberCastCompletedAt else {
        return
      }

      let elapsed = Float(CACurrentMediaTime() - startedAt)
      bobber.position = SIMD3<Float>(0, sin(elapsed * 1.8) * 0.008, 0)
    }

    @MainActor
    private func updateFishingCastLine() {
      guard let tip = fishingRodTipEntity else {
        fishingCastLineAnchor?.removeFromParent()
        fishingCastLineAnchor = nil
        fishingCastLineEntity = nil
        return
      }

      let tipPosition = tip.position(relativeTo: nil)
      guard let lineTarget = fishingBobberAnchor?.position(relativeTo: nil) else {
        fishingCastLineAnchor?.removeFromParent()
        fishingCastLineAnchor = nil
        fishingCastLineEntity = nil
        return
      }

      guard let arView else {
        return
      }

      if fishingCastLineAnchor == nil || fishingCastLineEntity == nil {
        let anchor = AnchorEntity(world: worldMatrix(translation: (tipPosition + lineTarget) * 0.5))
        let line = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.0035, 1.0, 0.0035)),
          materials: [SimpleMaterial(color: UIColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.92), roughness: 0.04, isMetallic: false)]
        )
        anchor.addChild(line)
        arView.scene.addAnchor(anchor)
        fishingCastLineAnchor = anchor
        fishingCastLineEntity = line
      }

      guard let anchor = fishingCastLineAnchor,
            let line = fishingCastLineEntity else {
        return
      }

      let midpoint = (tipPosition + lineTarget) * 0.5
      let delta = lineTarget - tipPosition
      let length = max(simd_length(delta), 0.001)
      let direction = delta / length
      let rotation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)

      anchor.setTransformMatrix(worldMatrix(translation: midpoint), relativeTo: nil)
      line.transform = Transform(
        scale: SIMD3<Float>(1.0, length, 1.0),
        rotation: rotation,
        translation: SIMD3<Float>(0, 0, 0)
      )
    }

    @MainActor
    private func createFishingRodAnchor(cameraMatrix: simd_float4x4? = nil) {
      guard let arView else {
        return
      }

      fishingRodAnchor?.removeFromParent()
      let activeCameraMatrix = cameraMatrix ?? arView.session.currentFrame?.camera.transform
      captureFishingBaselineIfNeeded(cameraMatrix: activeCameraMatrix)
      let anchor = AnchorEntity(.camera)
      anchor.name = "fishing_camera_anchor"
      let rig = Entity()
      rig.name = "fishing_rig"
      rig.transform = fishingHeldTransform(cameraMatrix: activeCameraMatrix)

      let leftHand = makeFishingHandEntity(
        side: .left,
        sleeveColor: UIColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1),
        skinColor: UIColor(red: 0.88, green: 0.74, blue: 0.62, alpha: 1)
      )
      leftHand.name = "fishing_left_hand"
      leftHand.position = SIMD3<Float>(-0.12, -0.05, 0)
      leftHand.orientation = simd_normalize(
        simd_quatf(angle: .pi / 26, axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: -.pi / 18, axis: SIMD3<Float>(0, 0, 1))
      )

      let rightHand = makeFishingHandEntity(
        side: .right,
        sleeveColor: UIColor(red: 0.18, green: 0.22, blue: 0.28, alpha: 1),
        skinColor: UIColor(red: 0.88, green: 0.74, blue: 0.62, alpha: 1)
      )
      rightHand.name = "fishing_right_hand"
      rightHand.position = SIMD3<Float>(0.12, -0.05, 0)
      rightHand.orientation = simd_normalize(
        simd_quatf(angle: -.pi / 26, axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: .pi / 18, axis: SIMD3<Float>(0, 0, 1))
      )

      let rod = makeFishingRodEntity()
      rod.position = SIMD3<Float>(0, -0.02, 0)

      rig.addChild(leftHand)
      rig.addChild(rightHand)
      rig.addChild(rod)
      anchor.addChild(rig)
      arView.scene.addAnchor(anchor)
      fishingRodAnchor = anchor
      fishingRigEntity = rig
      fishingRodEntity = rod
      fishingLeftHandEntity = leftHand
      fishingRightHandEntity = rightHand
      debugPrintFishingRigState(context: "created")
    }

    @MainActor
    private func ensureFishingHeldRodPreview() {
      guard fishingRodAnchor == nil || fishingRigEntity == nil || fishingRodEntity == nil else {
        return
      }

      createFishingRodAnchor(cameraMatrix: arView?.session.currentFrame?.camera.transform)
    }

    @MainActor
    private func clearFishingHeldRodPreview() {
      fishingRodAnchor?.removeFromParent()
      fishingRodAnchor = nil
      fishingRigEntity = nil
      fishingRodEntity = nil
      fishingLeftHandEntity = nil
      fishingRightHandEntity = nil
      fishingRodTipEntity = nil
      baselineFishingOrientation = nil
      baselineFishingDownwardPitch = nil
    }

    private func makeFishingRodEntity() -> Entity {
      let rod = Entity()
      rod.name = "fishing_rod"

      let handle = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.042, 0.30, 0.042)),
        materials: [Self.scenicMaterial(UIColor(red: 0.34, green: 0.22, blue: 0.12, alpha: 1), roughness: 1.0)]
      )
      handle.position = SIMD3<Float>(0, -0.17, 0.02)
      rod.addChild(handle)

      let handleCap = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.20, green: 0.12, blue: 0.07, alpha: 1), roughness: 0.98)]
      )
      handleCap.scale = SIMD3<Float>(0.052, 0.052, 0.052)
      handleCap.position = SIMD3<Float>(0, -0.33, 0.02)
      rod.addChild(handleCap)

      let reel = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [SimpleMaterial(color: UIColor(red: 0.90, green: 0.74, blue: 0.32, alpha: 1), roughness: 0.15, isMetallic: true)]
      )
      reel.scale = SIMD3<Float>(0.050, 0.050, 0.050)
      reel.position = SIMD3<Float>(0.050, -0.08, 0.030)
      rod.addChild(reel)

      let lowerRod = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.015, 0.015, 0.76)),
        materials: [Self.scenicMaterial(UIColor(red: 0.59, green: 0.42, blue: 0.18, alpha: 1), roughness: 0.78)]
      )
      lowerRod.position = SIMD3<Float>(0.0, 0.17, -0.28)
      lowerRod.orientation = simd_quatf(angle: -.pi / 3.7, axis: SIMD3<Float>(1, 0, 0))
      rod.addChild(lowerRod)

      let upperRod = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.010, 0.010, 0.48)),
        materials: [Self.scenicMaterial(UIColor(red: 0.67, green: 0.52, blue: 0.24, alpha: 1), roughness: 0.72)]
      )
      upperRod.position = SIMD3<Float>(0.0, 0.38, -0.58)
      upperRod.orientation = simd_quatf(angle: -.pi / 3.2, axis: SIMD3<Float>(1, 0, 0))
      rod.addChild(upperRod)

      let tip = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [SimpleMaterial(color: UIColor(red: 0.90, green: 0.82, blue: 0.60, alpha: 1), roughness: 0.14, isMetallic: true)]
      )
      tip.scale = SIMD3<Float>(0.020, 0.020, 0.020)
      tip.position = SIMD3<Float>(0.0, 0.54, -0.84)
      tip.name = "fishing_rod_tip"
      rod.addChild(tip)
      fishingRodTipEntity = tip

      let guide = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.003, 0.003, 0.18)),
        materials: [SimpleMaterial(color: UIColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.92), roughness: 0.04, isMetallic: false)]
      )
      guide.position = SIMD3<Float>(0.0, 0.46, -0.72)
      guide.orientation = simd_quatf(angle: -.pi / 3.2, axis: SIMD3<Float>(1, 0, 0))
      rod.addChild(guide)

      return rod
    }

    private func makeFishingHandEntity(side: FishingHandSide, sleeveColor: UIColor, skinColor: UIColor) -> Entity {
      let hand = Entity()
      let direction: Float = side == .left ? -1 : 1

      let forearm = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.14, 0.22, 0.14)),
        materials: [Self.scenicMaterial(sleeveColor, roughness: 0.96)]
      )
      forearm.position = SIMD3<Float>(direction * 0.05, -0.15, 0.05)
      forearm.orientation = simd_quatf(angle: direction * -.pi / 7, axis: SIMD3<Float>(0, 0, 1))
      hand.addChild(forearm)

      let palm = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.078, 0.050, 0.080)),
        materials: [Self.scenicMaterial(skinColor, roughness: 0.92)]
      )
      palm.position = SIMD3<Float>(0.0, -0.01, 0.0)
      hand.addChild(palm)

      let thumb = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.026, 0.028, 0.036)),
        materials: [Self.scenicMaterial(skinColor, roughness: 0.92)]
      )
      thumb.position = SIMD3<Float>(direction * 0.038, -0.008, 0.030)
      thumb.orientation = simd_quatf(angle: direction * -.pi / 6, axis: SIMD3<Float>(0, 1, 0))
      hand.addChild(thumb)

      let knuckles = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.074, 0.022, 0.030)),
        materials: [Self.scenicMaterial(skinColor.withAlphaComponent(0.98), roughness: 0.90)]
      )
      knuckles.position = SIMD3<Float>(0.0, 0.020, 0.018)
      hand.addChild(knuckles)

      return hand
    }

    @MainActor
    private func animateFishingRod(to transform: Transform, duration: TimeInterval, timingFunction: AnimationTimingFunction) {
      guard let rig = fishingRigEntity,
            let parent = rig.parent else {
        return
      }

      rig.move(to: transform, relativeTo: parent, duration: duration, timingFunction: timingFunction)
    }

    @MainActor
    private func castFishingBobber(to pondTarget: SIMD3<Float>) {
      guard let arView else {
        return
      }

      fishingBobberAnchor?.removeFromParent()
      let startPosition = fishingRodTipEntity?.position(relativeTo: nil) ?? SIMD3<Float>(0, 0, 0)
      let target = fishingCastTargetWorldPosition(from: startPosition, pondTarget: pondTarget)

      let anchor = AnchorEntity(world: worldMatrix(translation: startPosition))
      let bobber = makeFishingBobberEntity()
      anchor.addChild(bobber)
      arView.scene.addAnchor(anchor)
      fishingBobberAnchor = anchor
      fishingBobberEntity = bobber

      anchor.move(
        to: worldTransform(translation: target),
        relativeTo: nil as Entity?,
        duration: 0.78,
        timingFunction: AnimationTimingFunction.easeInOut
      )
      debugPrintFishingRigState(context: "cast")
    }

    private func makeFishingBobberEntity() -> ModelEntity {
      let bobber = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [SimpleMaterial(color: UIColor(red: 0.96, green: 0.30, blue: 0.24, alpha: 1), roughness: 0.18, isMetallic: false)]
      )
      bobber.scale = SIMD3<Float>(0.050, 0.050, 0.050)
      return bobber
    }

    @MainActor
    private func animateFishingBobberBite() {
      guard let bobber = fishingBobberEntity,
            let parent = bobber.parent else {
        return
      }

      let dive = transformed(
        bobber.transform,
        translation: SIMD3<Float>(0, -0.026, -0.010),
        rotation: simd_quatf(angle: .pi / 10, axis: SIMD3<Float>(1, 0, 0))
      )
      bobber.move(to: dive, relativeTo: parent, duration: 0.10, timingFunction: .easeIn)
    }

    @MainActor
    private func animateFishingBobberHookLift() {
      guard let bobberAnchor = fishingBobberAnchor else {
        return
      }

      if let bobberEntity = fishingBobberEntity,
         let parent = bobberEntity.parent {
        let tightened = transformed(
          bobberEntity.transform,
          translation: SIMD3<Float>(0, 0.010, 0.012),
          rotation: simd_quatf(angle: -.pi / 12, axis: SIMD3<Float>(1, 0, 0)),
          scale: bobberEntity.transform.scale * 0.88
        )
        bobberEntity.move(to: tightened, relativeTo: parent, duration: 0.18, timingFunction: .easeOut)
      }

      let current = bobberAnchor.transform
      let lifted = Transform(
        scale: current.scale,
        rotation: current.rotation,
        translation: current.translation + SIMD3<Float>(0, 0.18, 0.04)
      )
      bobberAnchor.move(
        to: lifted,
        relativeTo: nil as Entity?,
        duration: 0.24,
        timingFunction: AnimationTimingFunction.easeIn
      )
    }

    @MainActor
    private func spawnFishingCatch() {
      guard let arView,
            let pondTarget = fishingPondCastTargetWorldPosition() else {
        return
      }

      if let bobberEntity = fishingBobberEntity,
         let parent = bobberEntity.parent {
        let tuckedAway = transformed(
          bobberEntity.transform,
          translation: SIMD3<Float>(0, 0.030, 0.020),
          scale: bobberEntity.transform.scale * 0.45
        )
        bobberEntity.move(to: tuckedAway, relativeTo: parent, duration: 0.16, timingFunction: .easeIn)
      }

      let bobberAnchorToClear = fishingBobberAnchor
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self, weak bobberAnchorToClear] in
        bobberAnchorToClear?.removeFromParent()
        if self?.fishingBobberAnchor === bobberAnchorToClear {
          self?.fishingBobberAnchor = nil
          self?.fishingBobberEntity = nil
        }
      }

      fishingFishAnchor?.removeFromParent()
      let anchor = AnchorEntity(world: worldMatrix(translation: pondTarget))
      let fish = makeFishingFishEntity()
      fish.transform = Transform(
        scale: SIMD3<Float>(repeating: 0.84),
        rotation: simd_quatf(angle: -.pi / 10, axis: SIMD3<Float>(0, 1, 0)),
        translation: SIMD3<Float>(0, -0.06, 0)
      )
      anchor.addChild(fish)
      arView.scene.addAnchor(anchor)
      fishingFishAnchor = anchor
      fishingFishEntity = fish
      fishingFishFloatStartedAt = CACurrentMediaTime()

      fish.move(
        to: Transform(
          scale: SIMD3<Float>(repeating: 1.08),
          rotation: simd_quatf(angle: .pi / 11, axis: SIMD3<Float>(0, 1, 0)),
          translation: SIMD3<Float>(0.03, 0.34, 0.09)
        ),
        relativeTo: anchor,
        duration: 0.78,
        timingFunction: .easeOut
      )

      let sequenceID = fishingSequenceID
      fishingRevealTask = Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        let rewardLines = await self.commentary.fishingRewardMoveLines(limit: 5)
        try? await Task.sleep(nanoseconds: 860_000_000)
        guard self.fishingSequenceID == sequenceID,
              self.fishing.state == .caught else {
          return
        }
        self.fishing.armRewardFromCaughtFish(
          lines: rewardLines.isEmpty
            ? [
                "1. No Stockfish line ready yet.",
                "2. Trigger a fresh position analysis and cast again.",
              ]
            : rewardLines
        )
      }
    }

    private func makeFishingFishEntity() -> Entity {
      let fish = Entity()
      fish.name = "fishing_reward_fish"

      let body = ModelEntity(
        mesh: .generateSphere(radius: 0.5),
        materials: [Self.scenicMaterial(UIColor(red: 0.89, green: 0.59, blue: 0.26, alpha: 1), roughness: 0.62)]
      )
      body.scale = SIMD3<Float>(0.20, 0.12, 0.10)
      body.generateCollisionShapes(recursive: false)
      fish.addChild(body)

      let tail = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.080, 0.070, 0.018)),
        materials: [Self.scenicMaterial(UIColor(red: 0.94, green: 0.72, blue: 0.34, alpha: 1), roughness: 0.70)]
      )
      tail.position = SIMD3<Float>(-0.11, 0, 0)
      tail.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
      tail.generateCollisionShapes(recursive: false)
      fish.addChild(tail)

      let fin = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.020, 0.050, 0.010)),
        materials: [Self.scenicMaterial(UIColor(red: 0.95, green: 0.77, blue: 0.36, alpha: 1), roughness: 0.72)]
      )
      fin.position = SIMD3<Float>(0.01, 0.06, 0)
      fin.orientation = simd_quatf(angle: -.pi / 8, axis: SIMD3<Float>(0, 0, 1))
      fin.generateCollisionShapes(recursive: false)
      fish.addChild(fin)

      for side in [Float(-1), Float(1)] {
        let eye = ModelEntity(
          mesh: .generateSphere(radius: 0.5),
          materials: [SimpleMaterial(color: UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1), roughness: 0.24, isMetallic: false)]
        )
        eye.scale = SIMD3<Float>(0.016, 0.016, 0.016)
        eye.position = SIMD3<Float>(0.06, 0.02, 0.032 * side)
        eye.generateCollisionShapes(recursive: false)
        fish.addChild(eye)
      }

      let note = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(0.090, 0.050, 0.010)),
        materials: [Self.scenicMaterial(UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1), roughness: 1.0)]
      )
      note.position = SIMD3<Float>(0.10, -0.01, 0)
      note.orientation = simd_quatf(angle: .pi / 18, axis: SIMD3<Float>(0, 0, 1))
      note.generateCollisionShapes(recursive: false)
      fish.addChild(note)

      return fish
    }

    @MainActor
    private func updateFishingPondSurfaceMotion() {
      guard let fin = fishingPondFinEntity else {
        return
      }

      let now = CACurrentMediaTime()
      if fishingPondFinTravelDuration <= 0 {
        resetFishingPondFinPath(from: fin.position)
      }

      let rawProgress = Float((now - fishingPondFinTravelStartedAt) / Double(fishingPondFinTravelDuration))
      let progress = clamp(rawProgress, min: 0, max: 1)
      let eased = progress * progress * (3 - (2 * progress))
      let travelPosition = interpolatedVector(
        fishingPondFinStartLocalPosition,
        fishingPondFinTargetLocalPosition,
        progress: eased
      )
      let bob = sin(Float(now) * 3.8) * 0.003
      let heading = normalized3(
        fishingPondFinTargetLocalPosition - fishingPondFinStartLocalPosition,
        fallback: SIMD3<Float>(0, 0, 1)
      )
      let yaw = atan2(heading.x, heading.z)
      fin.position = SIMD3<Float>(travelPosition.x, 0.031 + bob, travelPosition.z)
      fin.orientation = simd_normalize(
        simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) *
          simd_quatf(angle: (.pi / 12) + (sin(Float(now) * 5.0) * 0.08), axis: SIMD3<Float>(0, 0, 1))
      )

      if progress >= 0.999 {
        resetFishingPondFinPath(from: travelPosition)
      }
    }

    private func resetFishingPondFinPath(from start: SIMD3<Float>) {
      fishingPondFinStartLocalPosition = SIMD3<Float>(start.x, 0.031, start.z)
      var nextTarget = randomFishingPondFinLocalPoint()
      var attempts = 0
      while simd_length(nextTarget - fishingPondFinStartLocalPosition) < 0.10 && attempts < 6 {
        nextTarget = randomFishingPondFinLocalPoint()
        attempts += 1
      }
      fishingPondFinTargetLocalPosition = nextTarget
      fishingPondFinTravelStartedAt = CACurrentMediaTime()
      fishingPondFinTravelDuration = Float.random(in: 2.6...4.8)
    }

    private func randomFishingPondFinLocalPoint() -> SIMD3<Float> {
      let angle = Float.random(in: 0..<(Float.pi * 2))
      let radius = sqrt(Float.random(in: 0.04...1.0)) * 0.34
      return SIMD3<Float>(cos(angle) * radius, 0.031, sin(angle) * radius)
    }

    @MainActor
    private func updateFishingCaughtFishMotion() {
      guard fishing.state == .caught,
            let fish = fishingFishEntity,
            let startedAt = fishingFishFloatStartedAt else {
        return
      }

      let elapsed = Float(CACurrentMediaTime() - startedAt)
      guard elapsed >= 0.82 else {
        return
      }

      let hoverTime = elapsed - 0.82
      let yaw = (.pi / 11) + (hoverTime * 0.60)
      let roll = sin(hoverTime * 1.15) * 0.08
      fish.transform = Transform(
        scale: SIMD3<Float>(repeating: 1.08),
        rotation: simd_normalize(
          simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) *
            simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        ),
        translation: SIMD3<Float>(0.03, 0.34 + (sin(hoverTime * 1.45) * 0.016), 0.09)
      )
    }

    private func fishingPondCastTargetWorldPosition() -> SIMD3<Float>? {
      let pondTargetEntity = fishingPondWaterEntity ?? fishingPondEntity
      return pondTargetEntity?.position(relativeTo: nil)
    }

    private func worldTransform(
      translation: SIMD3<Float>,
      rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    ) -> Transform {
      Transform(scale: SIMD3<Float>(repeating: 1), rotation: rotation, translation: translation)
    }

    private func worldMatrix(translation: SIMD3<Float>) -> simd_float4x4 {
      var matrix = matrix_identity_float4x4
      matrix.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
      return matrix
    }

    private func fishingHeldTransform(
      cameraMatrix: simd_float4x4? = nil,
      pondTarget: SIMD3<Float>? = nil
    ) -> Transform {
      _ = pondTarget
      return fishingFirstPersonTransform(
        cameraMatrix: cameraMatrix,
        translation: Self.fishingRigBasePosition,
        scale: 1.0,
        pitchAngle: Self.fishingRigBasePitch,
        yawAngle: Self.fishingRigBaseYaw,
        rollAngle: Self.fishingRigBaseRoll
      )
    }

    private func fishingCastTransform(
      cameraMatrix: simd_float4x4? = nil,
      pondTarget: SIMD3<Float>? = nil
    ) -> Transform {
      _ = pondTarget
      return fishingFirstPersonTransform(
        cameraMatrix: cameraMatrix,
        translation: Self.fishingRigBasePosition + SIMD3<Float>(0.00, 0.02, 0.03),
        scale: 1.0,
        pitchAngle: -.pi / 64,
        yawAngle: 0,
        rollAngle: -.pi / 96
      )
    }

    private func fishingWaitingTransform(
      cameraMatrix: simd_float4x4? = nil,
      pondTarget: SIMD3<Float>? = nil
    ) -> Transform {
      _ = pondTarget
      return fishingFirstPersonTransform(
        cameraMatrix: cameraMatrix,
        translation: Self.fishingRigBasePosition + SIMD3<Float>(0.00, 0.005, 0.00),
        scale: 1.0,
        pitchAngle: 0,
        yawAngle: 0,
        rollAngle: -.pi / 120
      )
    }

    private func fishingBiteTransform(
      cameraMatrix: simd_float4x4? = nil,
      pondTarget: SIMD3<Float>? = nil
    ) -> Transform {
      _ = pondTarget
      return fishingFirstPersonTransform(
        cameraMatrix: cameraMatrix,
        translation: Self.fishingRigBasePosition + SIMD3<Float>(0.00, 0.03, 0.03),
        scale: 1.0,
        pitchAngle: -.pi / 72,
        yawAngle: 0,
        rollAngle: .pi / 96
      )
    }

    private func fishingCatchPullTransform(
      cameraMatrix: simd_float4x4? = nil,
      pondTarget: SIMD3<Float>? = nil
    ) -> Transform {
      _ = pondTarget
      return fishingFirstPersonTransform(
        cameraMatrix: cameraMatrix,
        translation: Self.fishingRigBasePosition + SIMD3<Float>(0.00, 0.07, 0.07),
        scale: 1.0,
        pitchAngle: -.pi / 18,
        yawAngle: 0,
        rollAngle: -.pi / 84
      )
    }

    private func currentFishingWaitingTransform() -> Transform {
      fishingWaitingTransform(
        cameraMatrix: arView?.session.currentFrame?.camera.transform,
        pondTarget: fishingPondCastTargetWorldPosition()
      )
    }

    private func currentFishingBiteTransform() -> Transform {
      fishingBiteTransform(
        cameraMatrix: arView?.session.currentFrame?.camera.transform,
        pondTarget: fishingPondCastTargetWorldPosition()
      )
    }

    private func currentFishingCatchPullTransform() -> Transform {
      fishingCatchPullTransform(
        cameraMatrix: arView?.session.currentFrame?.camera.transform,
        pondTarget: fishingPondCastTargetWorldPosition()
      )
    }

    private func fishingFirstPersonTransform(
      cameraMatrix: simd_float4x4? = nil,
      translation: SIMD3<Float>,
      scale: Float,
      pitchAngle: Float,
      yawAngle: Float,
      rollAngle: Float
    ) -> Transform {
      let relativePitchDelta = fishingRigRelativePitchDeltaFromBaseline(cameraMatrix: cameraMatrix)
      let finalPitch = pitchAngle - relativePitchDelta
      let pitch = simd_quatf(angle: finalPitch, axis: SIMD3<Float>(1, 0, 0))
      let yaw = simd_quatf(angle: yawAngle, axis: SIMD3<Float>(0, 1, 0))
      let roll = simd_quatf(angle: rollAngle, axis: SIMD3<Float>(0, 0, 1))
      let rotation = simd_normalize(yaw * roll * pitch)
      var adjustedTranslation = translation

      if let cameraMatrix,
         let groundPlaneHeight = fishingGroundPlaneHeight() {
        let lowestWorldY = fishingRigLowestWorldY(
          cameraMatrix: cameraMatrix,
          translation: adjustedTranslation,
          rotation: rotation
        )
        let minimumAllowedY = groundPlaneHeight + Self.fishingRigGroundClearance
        if lowestWorldY < minimumAllowedY {
          let cameraUp = normalized3(simd_make_float3(cameraMatrix.columns.1), fallback: SIMD3<Float>(0, 1, 0))
          let worldLiftNeeded = minimumAllowedY - lowestWorldY
          let localLift = worldLiftNeeded / max(cameraUp.y, Self.fishingRigMinimumCameraUpComponent)
          adjustedTranslation.y += localLift
        }
      }

      return Transform(
        scale: SIMD3<Float>(repeating: scale),
        rotation: rotation,
        translation: adjustedTranslation
      )
    }

    private func captureFishingBaselineIfNeeded(cameraMatrix: simd_float4x4?) {
      guard baselineFishingOrientation == nil,
            let cameraMatrix else {
        return
      }

      baselineFishingOrientation = cameraMatrix
      baselineFishingDownwardPitch = fishingDownwardPitch(for: cameraMatrix)
    }

    private func fishingGroundPlaneHeight() -> Float? {
      if let boardAnchor {
        return boardAnchor.position(relativeTo: nil).y + Self.fishingTerrainPlaneLocalY
      }

      if let boardWorldTransform {
        return boardWorldTransform.columns.3.y + Self.fishingTerrainPlaneLocalY
      }

      return nil
    }

    private func fishingRigLowestWorldY(
      cameraMatrix: simd_float4x4,
      translation: SIMD3<Float>,
      rotation: simd_quatf
    ) -> Float {
      fishingRigLowestWorldY(
        rigWorldMatrix: cameraMatrix * localMatrix(translation: translation, rotation: rotation)
      )
    }

    private func fishingRigLowestWorldY(rigWorldMatrix: simd_float4x4) -> Float {
      fishingRigLowestSampleLocalPoints()
        .map { point in
          let worldPoint = rigWorldMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
          return worldPoint.y
        }
        .min() ?? rigWorldMatrix.columns.3.y
    }

    private func fishingRigLowestSampleLocalPoints() -> [SIMD3<Float>] {
      [
        SIMD3<Float>(0.0, -0.376, 0.020),
        SIMD3<Float>(0.021, -0.340, 0.041),
        SIMD3<Float>(-0.021, -0.340, -0.001),
        SIMD3<Float>(-0.170, -0.332, 0.050),
        SIMD3<Float>(-0.070, -0.332, 0.050),
        SIMD3<Float>(0.070, -0.332, 0.050),
        SIMD3<Float>(0.170, -0.332, 0.050),
        SIMD3<Float>(0.0, 0.530, -0.840),
        SIMD3<Float>(0.0, 0.460, -0.720),
        SIMD3<Float>(0.0, 0.380, -0.600),
        SIMD3<Float>(0.0, 0.250, -0.400),
      ]
    }

    private func localMatrix(translation: SIMD3<Float>, rotation: simd_quatf) -> simd_float4x4 {
      var matrix = simd_float4x4(rotation)
      matrix.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
      return matrix
    }

    private func fishingRigRelativePitchDeltaFromBaseline(cameraMatrix: simd_float4x4?) -> Float {
      guard let cameraMatrix,
            let baselineDownwardPitch = baselineFishingDownwardPitch else {
        return Self.fishingRigRelativePitchDeltaMin
      }

      let currentDownwardPitch = fishingDownwardPitch(for: cameraMatrix)
      let upwardDeltaFromBaseline = baselineDownwardPitch - currentDownwardPitch
      return clamp(
        upwardDeltaFromBaseline,
        min: Self.fishingRigRelativePitchDeltaMin,
        max: Self.fishingRigRelativePitchDeltaMax
      )
    }

    private func fishingDownwardPitch(for cameraMatrix: simd_float4x4) -> Float {
      let forward = normalized3(-simd_make_float3(cameraMatrix.columns.2), fallback: SIMD3<Float>(0, 0, -1))
      let horizontalLength = max(sqrt((forward.x * forward.x) + (forward.z * forward.z)), 0.0001)
      return atan2(max(0, -forward.y), horizontalLength)
    }

    private func fishingCastTargetWorldPosition(
      from rodTipWorldPosition: SIMD3<Float>,
      pondTarget: SIMD3<Float>
    ) -> SIMD3<Float> {
      guard let tip = fishingRodTipEntity else {
        return pondTarget + SIMD3<Float>(0, 0.012, 0)
      }

      let tipForward = normalized3(
        -simd_make_float3(tip.transformMatrix(relativeTo: nil).columns.2),
        fallback: normalized3(pondTarget - rodTipWorldPosition, fallback: SIMD3<Float>(0, -1, 0))
      )
      let waterY = pondTarget.y + 0.012
      let denominator = tipForward.y
      guard abs(denominator) > 0.0001 else {
        return pondTarget + SIMD3<Float>(0, 0.012, 0)
      }

      let travel = (waterY - rodTipWorldPosition.y) / denominator
      guard travel > 0 else {
        return pondTarget + SIMD3<Float>(0, 0.012, 0)
      }

      let intersection = rodTipWorldPosition + (tipForward * travel)
      let pondOffset = SIMD2<Float>(intersection.x - pondTarget.x, intersection.z - pondTarget.z)
      guard simd_length(pondOffset) <= 0.72 else {
        return pondTarget + SIMD3<Float>(0, 0.012, 0)
      }

      return SIMD3<Float>(intersection.x, waterY, intersection.z)
    }

    private func debugPrintFishingRigState(context: String) {
      guard let anchor = fishingRodAnchor,
            let rig = fishingRigEntity,
            let leftHand = fishingLeftHandEntity,
            let rightHand = fishingRightHandEntity,
            let tip = fishingRodTipEntity else {
        return
      }

      let usesCameraAnchor = anchor.name == "fishing_camera_anchor"
      let currentRelativePitchDelta = fishingRigRelativePitchDeltaFromBaseline(cameraMatrix: arView?.session.currentFrame?.camera.transform)
      let lowestDetectedY = fishingRigLowestWorldY(rigWorldMatrix: rig.transformMatrix(relativeTo: nil))
      let groundPlaneHeight = fishingGroundPlaneHeight()
      print("Fishing debug [\(context)] captured baseline fishing orientation: \(String(describing: baselineFishingOrientation))")
      print("Fishing debug [\(context)] current relative pitch delta from baseline: \(currentRelativePitchDelta)")
      print("Fishing debug [\(context)] clamp range being applied: min=\(Self.fishingRigRelativePitchDeltaMin) max=\(Self.fishingRigRelativePitchDeltaMax)")
      print("Fishing debug [\(context)] final local transform of the fishing rig: \(rig.transform)")
      print("Fishing debug [\(context)] rig local position: \(rig.position)")
      print("Fishing debug [\(context)] left hand local position: \(leftHand.position)")
      print("Fishing debug [\(context)] right hand local position: \(rightHand.position)")
      print("Fishing debug [\(context)] rod tip world transform: \(tip.transformMatrix(relativeTo: nil))")
      print("Fishing debug [\(context)] parent anchor is AnchorEntity(.camera): \(usesCameraAnchor)")
      print("Fishing debug [\(context)] current fishing rig position: \(rig.position)")
      print("Fishing debug [\(context)] lowest detected Y value of the rig: \(lowestDetectedY)")
      print("Fishing debug [\(context)] ground plane height used for clamp: \(String(describing: groundPlaneHeight))")
    }

    private func refreshBoardPresentation() {
      syncPieceEntities()
      syncHighlights()
      syncThreatOverlay()
    }

    private func syncPieceEntities() {
      Array(piecesContainer.children).forEach { $0.removeFromParent() }
      let squareSize = boardSize / 8.0
      let draggingOriginSquare = activePieceDrag?.originSquare
      let draggingPreviewSquare = activePieceDrag?.previewSquare
      let draggingPieceColor = draggingOriginSquare.flatMap { gameState.piece(at: $0)?.color }

      let orderedSquares = gameState.board.keys.sorted {
        if $0.rank == $1.rank {
          return $0.file < $1.file
        }
        return $0.rank < $1.rank
      }

      for square in orderedSquares {
        guard let piece = gameState.board[square] else {
          continue
        }

        if let draggingPreviewSquare,
           let draggingPieceColor,
           square == draggingPreviewSquare,
           square != draggingOriginSquare,
           piece.color != draggingPieceColor {
          continue
        }

        let pieceEntity = piecePrototype(for: piece.kind, color: piece.color).clone(recursive: true)
        pieceEntity.name = pieceName(square)
        pieceEntity.position = boardPosition(square, squareSize: squareSize)
        pieceEntity.orientation = pieceFacingOrientation(for: piece.color)

        if let activePieceDrag, activePieceDrag.originSquare == square {
          let presentedSquare = activePieceDrag.previewSquare ?? square
          pieceEntity.position = boardPosition(presentedSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.022, 0)
          pieceEntity.scale = SIMD3<Float>(repeating: 1.08)
        } else if selectedSquare == square {
          pieceEntity.position.y += 0.016
          pieceEntity.scale = SIMD3<Float>(repeating: 1.06)
        }

        if activeKnightForkBinding?.targetSquares.contains(square) == true {
          attachKnightForkShackle(
            to: pieceEntity,
            piece: piece,
            seed: square.file + (square.rank * 8),
            animated: false
          )
        }

        if piece.color == pieceRoleSnapshot.currentPlayer,
           let roleAssignment = pieceRoleSnapshot.assignmentsBySquare[square] {
          attachPieceRoleAccessory(
            to: pieceEntity,
            piece: piece,
            roleType: roleAssignment.roleType
          )
        }

        piecesContainer.addChild(pieceEntity)
      }
    }

    private func syncHighlights() {
      Array(highlightsContainer.children).forEach { $0.removeFromParent() }
      let squareSize = boardSize / 8.0

      if let selectedSquare {
        let selectedHighlight = makeHighlightEntity(
          size: squareSize,
          color: UIColor(red: 0.87, green: 0.73, blue: 0.37, alpha: 0.44)
        )
        selectedHighlight.position = boardPosition(selectedSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.0032, 0)
        highlightsContainer.addChild(selectedHighlight)
      }

      for move in selectedMoves {
        let isCapture = gameState.piece(at: move.to) != nil || move.isEnPassant
        let color = isCapture
          ? UIColor(red: 0.86, green: 0.34, blue: 0.29, alpha: 0.42)
          : UIColor(red: 0.24, green: 0.72, blue: 0.46, alpha: 0.34)
        let highlight = makeHighlightEntity(size: squareSize * (isCapture ? 0.94 : 0.58), color: color)
        highlight.position = boardPosition(move.to, squareSize: squareSize) + SIMD3<Float>(0, 0.0026, 0)
        highlightsContainer.addChild(highlight)
      }

      if let speakingPieceHighlightSquare {
        let speakingHighlight = makeHighlightEntity(
          size: squareSize * 0.90,
          color: UIColor(red: 0.18, green: 0.76, blue: 0.70, alpha: 0.42)
        )
        speakingHighlight.position = boardPosition(speakingPieceHighlightSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.0034, 0)
        highlightsContainer.addChild(speakingHighlight)
      }

      if let wantedPosterHighlightSquare {
        let wantedHighlight = makeHighlightEntity(
          size: squareSize * 0.96,
          color: UIColor(red: 0.94, green: 0.68, blue: 0.17, alpha: 0.48)
        )
        wantedHighlight.position = boardPosition(wantedPosterHighlightSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.0035, 0)
        highlightsContainer.addChild(wantedHighlight)
      }

      if mode.isLessonMode,
         lessonStore.isActive,
         lessonStore.isMoveRevealed,
         let step = lessonStore.currentStep,
         let expectedMove = expectedLessonMove(for: step, in: gameState),
         let revealSquare = step.destinationSquare {
        let revealHighlight = makeHighlightEntity(
          size: squareSize * 0.94,
          color: UIColor(red: 0.35, green: 0.67, blue: 0.96, alpha: 0.42)
        )
        revealHighlight.position = boardPosition(revealSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.0036, 0)
        highlightsContainer.addChild(revealHighlight)

        let ghost = piecePrototype(
          for: expectedMove.piece.kind,
          color: expectedMove.piece.color,
          isGhost: true
        ).clone(recursive: true)
        ghost.name = "lesson_ghost_piece"
        ghost.position = boardPosition(revealSquare, squareSize: squareSize) + SIMD3<Float>(0, 0.0015, 0)
        ghost.scale = SIMD3<Float>(repeating: 0.96)
        ghost.orientation = pieceFacingOrientation(for: expectedMove.piece.color)
        highlightsContainer.addChild(ghost)
      }
    }

    private func syncThreatOverlay() {
      Array(threatOverlayContainer.children).forEach { $0.removeFromParent() }
      activeThreatEntities.removeAll(keepingCapacity: false)

      let visibleThreatSquares = deduplicatedSquares(activeThreatSquares + persistentThreatSquares)
      guard !visibleThreatSquares.isEmpty else {
        return
      }

      let squareSize = boardSize / 8.0
      let alpha = currentThreatPulseAlpha()
      for square in visibleThreatSquares {
        let threatEntity = makeThreatOverlayEntity(size: squareSize * 0.96, alpha: alpha)
        threatEntity.position = boardPosition(square, squareSize: squareSize) + SIMD3<Float>(0, 0.0042, 0)
        threatOverlayContainer.addChild(threatEntity)
        activeThreatEntities.append(threatEntity)
      }
    }

    private func makeHighlightEntity(size: Float, color: UIColor) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(size, 0.0012, size)),
        materials: [SimpleMaterial(color: color, roughness: 0.15, isMetallic: false)]
      )
    }

    private func makeThreatOverlayEntity(size: Float, alpha: CGFloat) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(size, 0.0014, size)),
        materials: [
          SimpleMaterial(
            color: UIColor(red: 0.92, green: 0.18, blue: 0.24, alpha: alpha),
            roughness: 0.10,
            isMetallic: false
          )
        ]
      )
    }

    private func squareName(_ square: BoardSquare) -> String {
      "square_\(square.file)_\(square.rank)"
    }

    private func pieceName(_ square: BoardSquare) -> String {
      "piece_\(square.file)_\(square.rank)"
    }

    private func piecePrototype(
      for kind: ChessPieceKind,
      color: ChessColor,
      isGhost: Bool = false
    ) -> Entity {
      let key = PiecePrototypeKey(kind: kind, color: color, isGhost: isGhost)
      if let cached = Self.piecePrototypeCache[key] {
        return cached
      }

      let material = isGhost ? ghostPieceMaterial(for: color) : pieceMaterial(for: color)
      let prototype = makePieceEntity(kind: kind, material: material)
      if !isGhost {
        prototype.generateCollisionShapes(recursive: true)
      }
      Self.piecePrototypeCache[key] = prototype
      return prototype
    }

    private func square(for entity: Entity, prefix: String) -> BoardSquare? {
      var current: Entity? = entity

      while let candidate = current {
        let components = candidate.name.split(separator: "_")
        if components.count == 3,
           components[0] == Substring(prefix),
           let file = Int(components[1]),
           let rank = Int(components[2]) {
          return BoardSquare(file: file, rank: rank)
        }

        current = candidate.parent
      }

      return nil
    }

    private func fishingFishRoot(for entity: Entity) -> Entity? {
      var current: Entity? = entity

      while let candidate = current {
        if candidate.name == "fishing_reward_fish" {
          return candidate
        }
        current = candidate.parent
      }

      return nil
    }

    private func pieceMaterial(for color: ChessColor) -> SimpleMaterial {
      switch color {
      case .white:
        return SimpleMaterial(
          color: UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1),
          roughness: 0.98,
          isMetallic: false
        )
      case .black:
        return SimpleMaterial(
          color: UIColor(red: 0.26, green: 0.27, blue: 0.30, alpha: 1),
          roughness: 0.98,
          isMetallic: false
        )
      }
    }

    private func ghostPieceMaterial(for color: ChessColor) -> SimpleMaterial {
      switch color {
      case .white:
        return SimpleMaterial(
          color: UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 0.34),
          roughness: 0.98,
          isMetallic: false
        )
      case .black:
        return SimpleMaterial(
          color: UIColor(red: 0.26, green: 0.27, blue: 0.30, alpha: 0.34),
          roughness: 0.98,
          isMetallic: false
        )
      }
    }

    private func pieceFacingOrientation(for color: ChessColor) -> simd_quatf {
      color == boardViewerColor
        ? simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        : simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }

    private func boardPosition(_ square: BoardSquare, squareSize: Float) -> SIMD3<Float> {
      let presentedFile = boardViewerColor == .white ? 7 - square.file : square.file
      let presentedRank = boardViewerColor == .white ? 7 - square.rank : square.rank
      let x = (Float(presentedFile) - 3.5) * squareSize
      let z = (3.5 - Float(presentedRank)) * squareSize
      return SIMD3<Float>(x, 0.004, z)
    }

    private func makeColumn(width: Float, height: Float, depth: Float, material: SimpleMaterial) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width, height, depth)),
        materials: [material]
      )
    }

    private func accessoryMaterial(color: UIColor, metallic: Bool = true) -> SimpleMaterial {
      SimpleMaterial(color: color, roughness: 0.92, isMetallic: false)
    }

    private func addHands(
      to root: Entity,
      material: SimpleMaterial,
      leftName: String? = nil,
      rightName: String? = nil,
      spread: Float,
      height: Float,
      forward: Float
    ) {
      let leftHand = ModelEntity(mesh: .generateSphere(radius: 0.0048), materials: [material])
      leftHand.name = leftName ?? "piece_hand_left"
      leftHand.position = SIMD3<Float>(-spread, height, forward)
      root.addChild(leftHand)

      let rightHand = ModelEntity(mesh: .generateSphere(radius: 0.0048), materials: [material])
      rightHand.name = rightName ?? "piece_hand_right"
      rightHand.position = SIMD3<Float>(spread, height, forward)
      root.addChild(rightHand)
    }

    private func addSunglasses(to root: Entity, name: String? = nil, height: Float, width: Float) {
      let glassesMaterial = accessoryMaterial(color: UIColor(white: 0.04, alpha: 0.96), metallic: true)
      let glasses = Entity()
      glasses.name = name ?? "piece_sunglasses"
      glasses.position = SIMD3<Float>(0, height, -0.013)

      let leftLens = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width, 0.006, 0.0024)),
        materials: [glassesMaterial]
      )
      leftLens.position = SIMD3<Float>(-width * 0.68, 0, 0)
      glasses.addChild(leftLens)

      let rightLens = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width, 0.006, 0.0024)),
        materials: [glassesMaterial]
      )
      rightLens.position = SIMD3<Float>(width * 0.68, 0, 0)
      glasses.addChild(rightLens)

      let bridge = ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width * 0.58, 0.0018, 0.002)),
        materials: [glassesMaterial]
      )
      glasses.addChild(bridge)

      root.addChild(glasses)
    }

    private func makePieceEntity(kind: ChessPieceKind, material: SimpleMaterial) -> Entity {
      let root = Entity()
      let weaponMaterial = accessoryMaterial(color: UIColor(red: 0.67, green: 0.55, blue: 0.36, alpha: 1))
      let accentMaterial = accessoryMaterial(color: UIColor(red: 0.94, green: 0.82, blue: 0.24, alpha: 1))

      let base = makeColumn(width: 0.030, height: 0.006, depth: 0.030, material: material)
      base.position.y = 0.003
      root.addChild(base)

      switch kind {
      case .pawn:
        let stem = makeColumn(width: 0.015, height: 0.020, depth: 0.015, material: material)
        stem.position.y = 0.016
        root.addChild(stem)

        let head = ModelEntity(mesh: .generateSphere(radius: 0.010), materials: [material])
        head.position.y = 0.033
        root.addChild(head)

        addHands(to: root, material: material, spread: 0.017, height: 0.020, forward: 0.002)
        addSunglasses(to: root, height: 0.031, width: 0.007)

        let knife = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.003, 0.020, 0.002)),
          materials: [weaponMaterial]
        )
        knife.name = "pawn_knife"
        knife.position = SIMD3<Float>(0.016, 0.022, 0.010)
        knife.orientation = simd_quatf(angle: -.pi / 4.8, axis: SIMD3<Float>(1, 0, 0))
        root.addChild(knife)

      case .rook:
        let tower = makeColumn(width: 0.020, height: 0.026, depth: 0.020, material: material)
        tower.position.y = 0.019
        root.addChild(tower)

        let crown = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.024, 0.007, 0.024)), materials: [material])
        crown.position.y = 0.036
        root.addChild(crown)

        addHands(to: root, material: material, spread: 0.020, height: 0.024, forward: 0.003)
        addSunglasses(to: root, height: 0.032, width: 0.008)

        let bazookaBody = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.010, 0.034, 0.010)),
          materials: [weaponMaterial]
        )
        bazookaBody.name = "rook_bazooka"
        bazookaBody.position = SIMD3<Float>(0.020, 0.028, 0.010)
        bazookaBody.orientation = simd_quatf(angle: -.pi / 2.8, axis: SIMD3<Float>(1, 0, 0))
        root.addChild(bazookaBody)

        let bazookaTip = ModelEntity(
          mesh: .generateSphere(radius: 0.005),
          materials: [accentMaterial]
        )
        bazookaTip.position = SIMD3<Float>(0, 0.018, 0)
        bazookaBody.addChild(bazookaTip)

      case .knight:
        let body = makeColumn(width: 0.018, height: 0.018, depth: 0.018, material: material)
        body.position.y = 0.015
        root.addChild(body)

        let neck = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.016, 0.028, 0.010)), materials: [material])
        neck.position = SIMD3<Float>(0, 0.034, -0.003)
        neck.orientation = simd_quatf(angle: -.pi / 9, axis: SIMD3<Float>(1, 0, 0))
        root.addChild(neck)

        addHands(to: root, material: material, spread: 0.019, height: 0.023, forward: 0.002)
        addSunglasses(to: root, height: 0.034, width: 0.008)

      case .bishop:
        let body = makeColumn(width: 0.018, height: 0.024, depth: 0.018, material: material)
        body.position.y = 0.018
        root.addChild(body)

        let cap = ModelEntity(mesh: .generateSphere(radius: 0.011), materials: [material])
        cap.position.y = 0.036
        root.addChild(cap)

        let finial = ModelEntity(mesh: .generateSphere(radius: 0.004), materials: [material])
        finial.position.y = 0.050
        root.addChild(finial)

        addHands(to: root, material: material, spread: 0.018, height: 0.026, forward: 0.002)
        addSunglasses(to: root, height: 0.034, width: 0.0075)

        let sniperBody = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.004, 0.034, 0.004)),
          materials: [weaponMaterial]
        )
        sniperBody.name = "bishop_sniper"
        sniperBody.position = SIMD3<Float>(0.019, 0.030, 0.010)
        sniperBody.orientation = simd_quatf(angle: -.pi / 2.9, axis: SIMD3<Float>(1, 0, 0))
        root.addChild(sniperBody)

        let sniperCrossBar = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.014, 0.003, 0.003)),
          materials: [accentMaterial]
        )
        sniperCrossBar.position = SIMD3<Float>(0, 0.009, 0)
        sniperBody.addChild(sniperCrossBar)

      case .queen:
        let body = makeColumn(width: 0.020, height: 0.030, depth: 0.020, material: material)
        body.position.y = 0.021
        root.addChild(body)

        let crown = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [material])
        crown.position.y = 0.044
        root.addChild(crown)

        addHands(to: root, material: material, spread: 0.020, height: 0.028, forward: 0.002)
        addSunglasses(to: root, name: "queen_sunglasses", height: 0.039, width: 0.0084)

      case .king:
        let body = makeColumn(width: 0.020, height: 0.034, depth: 0.020, material: material)
        body.position.y = 0.023
        root.addChild(body)

        addHands(
          to: root,
          material: material,
          leftName: "king_hand_left",
          rightName: "king_hand_right",
          spread: 0.022,
          height: 0.029,
          forward: 0.001
        )
        addSunglasses(to: root, height: 0.040, width: 0.0084)

        let crownBase = ModelEntity(
          mesh: .generateBox(size: SIMD3<Float>(0.022, 0.005, 0.022)),
          materials: [accentMaterial]
        )
        crownBase.name = "king_crown"
        crownBase.position.y = 0.045
        root.addChild(crownBase)

        let crownGem = ModelEntity(
          mesh: .generateSphere(radius: 0.0055),
          materials: [accentMaterial]
        )
        crownGem.position.y = 0.010
        crownBase.addChild(crownGem)

        let tearMaterial = SimpleMaterial(
          color: UIColor(red: 0.46, green: 0.76, blue: 0.96, alpha: 0.88),
          roughness: 0.18,
          isMetallic: false
        )

        let leftTear = ModelEntity(mesh: .generateSphere(radius: 0.0035), materials: [tearMaterial])
        leftTear.name = "king_tear_left"
        leftTear.position = SIMD3<Float>(-0.009, 0.032, -0.011)
        leftTear.scale = SIMD3<Float>(repeating: 0.001)
        root.addChild(leftTear)

        let rightTear = ModelEntity(mesh: .generateSphere(radius: 0.0035), materials: [tearMaterial])
        rightTear.name = "king_tear_right"
        rightTear.position = SIMD3<Float>(0.009, 0.032, -0.011)
        rightTear.scale = SIMD3<Float>(repeating: 0.001)
        root.addChild(rightTear)
      }

      return root
    }
  }
}
