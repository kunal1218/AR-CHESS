import AVFoundation
import ARKit
import Foundation
import RealityKit
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

private enum NativeScreen {
  case landing
  case lobby(PlayerMode)
  case experience(PlayerMode)
}

private struct AppRuntimeConfig {
  let apiBaseURL: URL?

  static let current = AppRuntimeConfig()

  init() {
    let sources = [
      Bundle.main.object(forInfoDictionaryKey: "ARChessAPIBaseURL") as? String,
      ProcessInfo.processInfo.environment["AR_CHESS_API_BASE_URL"],
    ]

    for candidate in sources {
      guard let candidate else {
        continue
      }

      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
        continue
      }

      apiBaseURL = url.deletingTrailingSlash()
      return
    }

    apiBaseURL = nil
  }
}

private struct RemoteGameResponse: Decodable {
  let game_id: String
}

private struct RemoteMoveRequest: Encodable {
  let ply: Int
  let move_uci: String
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

  init(apiBaseURL: URL? = AppRuntimeConfig.current.apiBaseURL) {
    self.apiBaseURL = apiBaseURL
  }

  func prepareRemoteGameIfNeeded() async {
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

    Task {
      await persistEntry(withID: entry.id)
    }
  }

  func resetSession() {
    entries = []
    remoteGameID = nil
    syncStatus = "Moves stay local until ARChessAPIBaseURL is set."
  }

  private func persistEntry(withID entryID: UUID) async {
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

private extension URL {
  func deletingTrailingSlash() -> URL {
    let raw = absoluteString
    guard raw.hasSuffix("/") else {
      return self
    }

    return URL(string: String(raw.dropLast())) ?? self
  }
}

private struct StockfishAnalysis {
  let scoreCp: Int?
  let mateIn: Int?
  let pv: [String]
  let bestMove: String?

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
      return 1.72
    case .knight:
      return 1.46
    case .bishop:
      return 0.86
    case .queen:
      return 0.68
    case .king:
      return 1.28
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

@MainActor
private final class StockfishWASMAnalyzer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private let messageHandlerName = "stockfishBridge"
  private var webView: WKWebView?
  private var pendingContinuations: [String: CheckedContinuation<StockfishAnalysis, Error>] = [:]
  private var timeoutTasks: [String: Task<Void, Never>] = [:]
  private var readyContinuations: [CheckedContinuation<Void, Error>] = []
  private var readyTimeoutTask: Task<Void, Never>?
  private var isEngineReady = false
  private(set) var lastError: String?
  private(set) var lastStatus = "Stockfish idle."
  private let analysisTimeoutNanoseconds: UInt64 = 10_000_000_000

  func analyze(fen: String, depth: Int = 10) async throws -> StockfishAnalysis {
    ensureWebView()

    guard webView != nil else {
      throw NSError(
        domain: "ARChess.Stockfish",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: lastError ?? "Bundled Stockfish assets are unavailable."]
      )
    }

    try await waitUntilReady()

    let requestID = UUID().uuidString
    let requestScript = """
    window.__archessAnalyze(\(javaScriptStringLiteral(requestID)), \(javaScriptStringLiteral(fen)), \(depth));
    """

    return try await withCheckedThrowingContinuation { continuation in
      pendingContinuations[requestID] = continuation
      timeoutTasks[requestID] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: self?.analysisTimeoutNanoseconds ?? 25_000_000_000)
        await MainActor.run {
          guard let self,
                let continuation = self.pendingContinuations.removeValue(forKey: requestID) else {
            return
          }

          self.timeoutTasks[requestID]?.cancel()
          self.timeoutTasks[requestID] = nil
          self.lastError = "Stockfish request timed out."
          self.lastStatus = "Stockfish search timed out at depth \(depth)."
          self.cancelCurrentAnalysis()
          continuation.resume(
            throwing: NSError(
              domain: "ARChess.Stockfish",
              code: -1,
              userInfo: [NSLocalizedDescriptionKey: "Stockfish request timed out."]
            )
          )
        }
      }

      webView?.evaluateJavaScript(requestScript) { [weak self] _, error in
        guard let self, let error else {
          return
        }

        guard let continuation = self.pendingContinuations.removeValue(forKey: requestID) else {
          return
        }

        self.timeoutTasks[requestID]?.cancel()
        self.timeoutTasks[requestID] = nil
        self.lastError = error.localizedDescription
        continuation.resume(throwing: error)
      }
    }
  }

  func reset() {
    lastError = nil
    lastStatus = "Stockfish idle."
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    readyContinuations.removeAll()
    pendingContinuations.removeAll()
    timeoutTasks.values.forEach { $0.cancel() }
    timeoutTasks.removeAll()
    isEngineReady = false
    webView = nil
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
    case "ready":
      isEngineReady = true
      lastError = nil
      lastStatus = "Stockfish ready."
      readyTimeoutTask?.cancel()
      readyTimeoutTask = nil
      let continuations = readyContinuations
      readyContinuations.removeAll()
      continuations.forEach { $0.resume() }
    case "error":
      let message = payload["message"] as? String ?? "Unknown Stockfish bridge error."
      lastError = message
      lastStatus = "Stockfish error: \(message)"
      if !isEngineReady, !readyContinuations.isEmpty {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        let continuations = readyContinuations
        readyContinuations.removeAll()
        continuations.forEach {
          $0.resume(
            throwing: NSError(
              domain: "ARChess.Stockfish",
              code: -3,
              userInfo: [NSLocalizedDescriptionKey: message]
            )
          )
        }
      }
    case "result":
      guard let requestID = payload["id"] as? String,
            let continuation = pendingContinuations.removeValue(forKey: requestID) else {
        return
      }

      timeoutTasks[requestID]?.cancel()
      timeoutTasks[requestID] = nil

      continuation.resume(
        returning: StockfishAnalysis(
          scoreCp: payload["scoreCp"] as? Int,
          mateIn: payload["mateIn"] as? Int,
          pv: payload["pv"] as? [String] ?? [],
          bestMove: payload["bestMove"] as? String
        )
      )
    default:
      return
    }
  }

  private func ensureWebView() {
    guard webView == nil else {
      return
    }

    guard let payload = Self.stockfishBridgePayload() else {
      lastError = "Bundled Stockfish assets are missing or unreadable."
      return
    }

    let userContentController = WKUserContentController()
    userContentController.add(self, name: messageHandlerName)

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isHidden = true
    webView.navigationDelegate = self
    lastStatus = "Stockfish booting..."
    webView.loadHTMLString(
      Self.stockfishBridgeHTML(
        messageHandlerName: messageHandlerName,
        engineSource: payload.engineSource,
        wasmBase64: payload.wasmBase64
      ),
      baseURL: nil
    )
    self.webView = webView
  }

  private func cancelCurrentAnalysis() {
    webView?.evaluateJavaScript("window.__archessCancelCurrentAnalysis && window.__archessCancelCurrentAnalysis();")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    lastError = error.localizedDescription
    lastStatus = "Stockfish webview navigation failed."
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    lastError = error.localizedDescription
    lastStatus = "Stockfish webview provisional navigation failed."
  }

  private func waitUntilReady() async throws {
    if isEngineReady {
      return
    }

    try await withCheckedThrowingContinuation { continuation in
      readyContinuations.append(continuation)
      if readyTimeoutTask == nil {
        readyTimeoutTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 8_000_000_000)
          await MainActor.run {
            guard let self, !self.isEngineReady, !self.readyContinuations.isEmpty else {
              return
            }

            let errorMessage = self.lastError ?? self.lastStatus
            let continuations = self.readyContinuations
            self.readyContinuations.removeAll()
            self.readyTimeoutTask = nil
            self.lastError = errorMessage
            continuations.forEach {
              $0.resume(
                throwing: NSError(
                  domain: "ARChess.Stockfish",
                  code: -4,
                  userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
              )
            }
          }
        }
      }
    }
  }

  private static func stockfishBridgePayload() -> (engineSource: String, wasmBase64: String)? {
    guard let bundledJSURL = Bundle.main.url(forResource: "stockfish-nnue-16-single", withExtension: "js"),
          let bundledWASMURL = Bundle.main.url(forResource: "stockfish-nnue-16-single", withExtension: "wasm"),
          let engineSource = try? String(contentsOf: bundledJSURL, encoding: .utf8),
          let wasmData = try? Data(contentsOf: bundledWASMURL) else {
      return nil
    }

    let sanitizedEngineSource = engineSource.replacingOccurrences(of: "</script", with: "<\\/script")
    return (engineSource: sanitizedEngineSource, wasmBase64: wasmData.base64EncodedString())
  }

  private func javaScriptStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[\"\"]"
    return String(json.dropFirst().dropLast())
  }

  private static func stockfishBridgeHTML(
    messageHandlerName: String,
    engineSource: String,
    wasmBase64: String
  ) -> String {
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <script id="stockfish-engine">
        \(engineSource)
        </script>
        <script>
          const bridgeState = {
            ready: false,
            engine: null,
            queue: [],
            current: null,
          };
          const wasmBase64 = \(jsonStringLiteral(wasmBase64));

          function bridgePost(payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName)) {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload);
            }
          }

          function bridgeStatus(message) {
            bridgePost({ type: 'status', message });
          }

          function decodeBase64ToUint8Array(base64) {
            const binary = atob(base64);
            const length = binary.length;
            const bytes = new Uint8Array(length);
            for (let index = 0; index < length; index += 1) {
              bytes[index] = binary.charCodeAt(index);
            }
            return bytes;
          }

          function sendEngineCommand(command) {
            const engine = bridgeState.engine;
            if (!engine) {
              bridgePost({ type: 'error', message: 'Stockfish engine missing while sending command.' });
              return false;
            }

            if (typeof engine.onCustomMessage === 'function') {
              engine.onCustomMessage(command);
              return true;
            }

            if (typeof engine.postMessage === 'function') {
              engine.postMessage(command);
              return true;
            }

            bridgePost({ type: 'error', message: 'Stockfish command API missing.' });
            return false;
          }

          async function bootStockfish() {
            try {
              bridgeStatus('Preparing Stockfish engine...');
              const factory = document.getElementById('stockfish-engine')._exports;
              if (!factory) {
                bridgePost({ type: 'error', message: 'Stockfish engine factory missing.' });
                return;
              }

              bridgeStatus('Decoding bundled WASM...');
              const wasmBinary = decodeBase64ToUint8Array(wasmBase64);
              bridgeStatus('Instantiating engine...');
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

              bridgeStatus('Waiting for uciok...');
              sendEngineCommand('uci');
            } catch (error) {
              bridgePost({ type: 'error', message: String(error) });
            }
          }

          function handleEngineLine(line) {
            line = String(line);

            if (line === 'uciok') {
              bridgeStatus('uciok received. Waiting for readyok...');
              sendEngineCommand('setoption name UCI_AnalyseMode value true');
              sendEngineCommand('setoption name Hash value 16');
              sendEngineCommand('isready');
              return;
            }

            if (line === 'readyok') {
              bridgeState.ready = true;
              bridgeStatus('readyok received.');
              bridgePost({ type: 'ready' });
              drainAnalysisQueue();
              return;
            }

            if (!bridgeState.current) {
              return;
            }

            const state = bridgeState.current;
            const cpMatch = line.match(/score cp (-?\\d+)/);
            if (cpMatch) {
              state.scoreCp = parseInt(cpMatch[1], 10);
              state.mateIn = null;
            }

            const mateMatch = line.match(/score mate (-?\\d+)/);
            if (mateMatch) {
              state.mateIn = parseInt(mateMatch[1], 10);
              state.scoreCp = null;
            }

            const pvMatch = line.match(/\\spv\\s(.+)/);
            if (pvMatch) {
              state.pv = pvMatch[1].trim().split(/\\s+/).filter(Boolean);
            }

            if (line.startsWith('bestmove ')) {
              const parts = line.trim().split(/\\s+/);
              bridgePost({
                type: 'result',
                id: state.id,
                scoreCp: state.scoreCp,
                mateIn: state.mateIn,
                pv: state.pv || [],
                bestMove: parts[1] || null,
              });
              bridgeState.current = null;
              drainAnalysisQueue();
            }
          }

          function drainAnalysisQueue() {
            if (!bridgeState.ready || bridgeState.current || !bridgeState.engine || bridgeState.queue.length === 0) {
              return;
            }

            const next = bridgeState.queue.shift();
            bridgeState.current = {
              id: next.id,
              fen: next.fen,
              depth: next.depth,
              scoreCp: null,
              mateIn: null,
              pv: [],
            };

            bridgeStatus('Analyzing depth ' + next.depth + '...');
            sendEngineCommand('stop');
            sendEngineCommand('position fen ' + next.fen);
            sendEngineCommand('go depth ' + next.depth);
          }

          window.__archessCancelCurrentAnalysis = function() {
            if (bridgeState.engine) {
              sendEngineCommand('stop');
            }

            bridgeState.current = null;
            bridgeState.queue = [];
            bridgeStatus('Current Stockfish search cancelled.');
            return true;
          };

          window.__archessAnalyze = function(id, fen, depth) {
            bridgeState.queue = [{ id, fen, depth }];
            if (bridgeState.current) {
              bridgeStatus('Prioritizing latest board state...');
              sendEngineCommand('stop');
              return true;
            }
            drainAnalysisQueue();
            return true;
          };
          bootStockfish();
        </script>
      </head>
      <body></body>
    </html>
    """
  }

  private static func jsonStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[\"\"]"
    return String(json.dropFirst().dropLast())
  }
}

@MainActor
private final class PiecePersonalityDirector: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
  private static let preferredAnalysisDepth = 5
  private static let commentaryIntervalRange = 3...4

  struct Caption {
    let speaker: PersonalitySpeaker
    let line: String

    var speakerName: String {
      speaker.displayName
    }
  }

  @Published private(set) var caption: Caption?
  @Published private(set) var analysisStatus = "Stockfish depth 5 warming up..."
  @Published private(set) var latestAssessment = "Waiting for initial analysis."
  @Published private(set) var suggestedMoveText = "Next best move: waiting on Stockfish..."

  private let analyzer = StockfishWASMAnalyzer()
  private let synthesizer = AVSpeechSynthesizer()
  private var utteranceCaptions: [ObjectIdentifier: Caption] = [:]
  private var cachedAnalysis: CachedAnalysis?
  private var completedPlyCount = 0
  private var nextCommentaryPly = Int.random(in: commentaryIntervalRange)

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func prepare(with state: ChessGameState) async {
    let fen = state.fenString
    guard cachedAnalysis?.fen != fen else {
      return
    }

    do {
      let analysis = try await analyzer.analyze(fen: fen, depth: Self.preferredAnalysisDepth)
      cachedAnalysis = CachedAnalysis(fen: fen, analysis: analysis)
      analysisStatus = "Stockfish depth \(Self.preferredAnalysisDepth) ready."
      latestAssessment = "Prep eval: \(describe(analysis: analysis, moverColor: state.turn))."
      suggestedMoveText = bestMoveDescription(from: analysis)
    } catch {
      let message = analyzer.lastError ?? error.localizedDescription
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(message)"
      suggestedMoveText = "Next best move unavailable."
    }
  }

  func resetSession() {
    synthesizer.stopSpeaking(at: .immediate)
    utteranceCaptions.removeAll()
    caption = nil
    cachedAnalysis = nil
    completedPlyCount = 0
    nextCommentaryPly = Int.random(in: Self.commentaryIntervalRange)
    analyzer.reset()
    analysisStatus = "Stockfish depth \(Self.preferredAnalysisDepth) warming up..."
    latestAssessment = "Waiting for initial analysis."
    suggestedMoveText = "Next best move: waiting on Stockfish..."
  }

  func handleMove(
    move: ChessMove,
    before beforeState: ChessGameState,
    after afterState: ChessGameState
  ) async {
    completedPlyCount += 1
    let beforeAnalysis = await analysisForCurrentTurn(state: beforeState)
    let afterAnalysis = await analysisForCurrentTurn(state: afterState)

    if let afterAnalysis {
      cachedAnalysis = CachedAnalysis(fen: afterState.fenString, analysis: afterAnalysis)
      analysisStatus = "Stockfish depth \(Self.preferredAnalysisDepth) live."
      suggestedMoveText = bestMoveDescription(from: afterAnalysis)
    } else if analyzer.lastError != nil {
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(analyzer.lastError ?? analyzer.lastStatus)"
      suggestedMoveText = "Next best move unavailable."
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
      latestAssessment = "Checkmate."
      if speakRandomLine(from: checkmateLines(), priority: .urgent) {
        scheduleNextCommentaryWindow()
      }
      return
    }

    guard completedPlyCount >= nextCommentaryPly else {
      return
    }

    let dialogueLines: [SpokenLine]
    let priority: SpeechPriority
    if afterState.isInCheck(for: afterState.turn) {
      latestAssessment = "Check."
      dialogueLines = checkLines()
      priority = .urgent
    } else if let captured = move.captured {
      dialogueLines = captureLines(for: captured.kind)
      priority = .normal
    } else if let assessment {
      dialogueLines = lines(for: assessment)
      priority = .normal
    } else {
      dialogueLines = ambientMoveFlavorLines()
      priority = .normal
    }

    if speakRandomLine(from: dialogueLines, priority: priority) {
      scheduleNextCommentaryWindow()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    caption = utteranceCaptions[ObjectIdentifier(utterance)]
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    utteranceCaptions[ObjectIdentifier(utterance)] = nil
    if !synthesizer.isSpeaking {
      caption = nil
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    utteranceCaptions[ObjectIdentifier(utterance)] = nil
    if !synthesizer.isSpeaking {
      caption = nil
    }
  }

  private func analysisForCurrentTurn(state: ChessGameState) async -> StockfishAnalysis? {
    let fen = state.fenString

    if cachedAnalysis?.fen == fen {
      return cachedAnalysis?.analysis
    }

    do {
      let analysis = try await analyzer.analyze(fen: fen, depth: Self.preferredAnalysisDepth)
      cachedAnalysis = CachedAnalysis(fen: fen, analysis: analysis)
      return analysis
    } catch {
      return nil
    }
  }

  private func classifyMove(
    before: StockfishAnalysis?,
    after: StockfishAnalysis?,
    moverColor: ChessColor
  ) -> MoveClassification? {
    guard let before, let after else {
      return nil
    }

    let beforeScore = scoreForMoverPerspective(before, moverColor: moverColor, isPostMove: false)
    let afterScore = scoreForMoverPerspective(after, moverColor: moverColor, isPostMove: true)
    let swing = afterScore - beforeScore

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
    guard let before, let after else {
      return "Stockfish unavailable"
    }

    let beforeScore = scoreForMoverPerspective(before, moverColor: moverColor, isPostMove: false)
    let afterScore = scoreForMoverPerspective(after, moverColor: moverColor, isPostMove: true)
    let swing = afterScore - beforeScore
    let sign = swing >= 0 ? "+" : ""
    return "\(sign)\(swing) cp swing"
  }

  private func scoreForMoverPerspective(_ analysis: StockfishAnalysis, moverColor: ChessColor, isPostMove: Bool) -> Int {
    let sideToMoveScore = analysis.normalizedScore
    _ = moverColor
    if isPostMove {
      return -sideToMoveScore
    }

    return sideToMoveScore
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

  private func scheduleNextCommentaryWindow() {
    nextCommentaryPly = completedPlyCount + Int.random(in: Self.commentaryIntervalRange)
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
        SpokenLine(speaker: .pawn, text: "Forward. Hold the line and draw blood later.", pitch: 0.98, rate: 0.44, volume: 0.84),
        SpokenLine(speaker: .rook, text: "Slow hunt. Strong walls.", pitch: 1.34, rate: 0.46, volume: 0.96),
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
        SpokenLine(speaker: .rook, text: "You do not cage a hunter for long.", pitch: 1.44, rate: 0.50, volume: 1.0),
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
        SpokenLine(speaker: .pawn, text: "I would have taken blood with me.", pitch: 0.98, rate: 0.42, volume: 0.86),
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
        SpokenLine(speaker: .king, text: "Keep this quiet and I may still survive the headlines.", pitch: 1.20, rate: 0.38, volume: 0.96),
        SpokenLine(speaker: .king, text: "Stay calm. We can still broker a deal.", pitch: 1.16, rate: 0.36, volume: 0.94),
      ]
    case .queen:
      return [
        SpokenLine(speaker: .queen, text: "Power looks better on me, do you not think?", pitch: 0.72, rate: 0.28, volume: 0.94),
        SpokenLine(speaker: .queen, text: "I could rule either side, but this one wears me well.", pitch: 0.70, rate: 0.27, volume: 0.92),
      ]
    case .bishop:
      return [
        SpokenLine(speaker: .bishop, text: "Only Christ can save us, so move with purpose.", pitch: 0.84, rate: 0.34, volume: 0.90),
        SpokenLine(speaker: .bishop, text: "This diagonal is scripture. Read it carefully.", pitch: 0.86, rate: 0.35, volume: 0.88),
      ]
    case .knight:
      return [
        SpokenLine(speaker: .knight, text: "I smell panic. Let me off the leash.", pitch: 1.48, rate: 0.60, volume: 0.98),
        SpokenLine(speaker: .knight, text: "I hunt crooked and strike hard.", pitch: 1.44, rate: 0.58, volume: 0.96),
      ]
    case .rook:
      return [
        SpokenLine(speaker: .rook, text: "This beast guards the file. Nothing escapes.", pitch: 1.34, rate: 0.48, volume: 1.0),
        SpokenLine(speaker: .rook, text: "A wall with teeth still counts as a wall.", pitch: 1.30, rate: 0.46, volume: 0.98),
      ]
    case .pawn:
      return [
        SpokenLine(speaker: .pawn, text: "Forward. I was born for blood and promotion.", pitch: 0.98, rate: 0.43, volume: 0.86),
        SpokenLine(speaker: .pawn, text: "I march first and I taste the danger first.", pitch: 0.96, rate: 0.41, volume: 0.84),
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
    utterance.pitchMultiplier = min(max(line.pitch ?? line.speaker.defaultPitch, 0.5), 2.0)
    utterance.rate = min(max(line.rate ?? line.speaker.defaultRate, 0.1), 0.65)
    utterance.volume = min(max(line.volume ?? line.speaker.defaultVolume, 0.0), 1.0)
    utterance.preUtteranceDelay = 0.02
    utteranceCaptions[ObjectIdentifier(utterance)] = Caption(
      speaker: line.speaker,
      line: line.text
    )
    synthesizer.speak(utterance)
    return true
  }
}

private struct PieceSpeechBubble: View {
  let caption: PiecePersonalityDirector.Caption

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      PiecePortraitView(speaker: caption.speaker)

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
  @State private var screen: NativeScreen = .landing

  var body: some View {
    ZStack {
      switch screen {
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
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .experience(mode)
            }
          },
          goBack: {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .landing
            }
          }
        )
      case .experience(let mode):
        NativeARExperienceView(mode: mode) {
          withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            screen = .lobby(mode)
          }
        }
      }
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

          Text("AR Chess")
            .font(.system(size: 50, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

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

private struct NativeARExperienceView: View {
  let mode: PlayerMode
  let closeExperience: () -> Void
  @StateObject private var matchLog = MatchLogStore()
  @StateObject private var commentary = PiecePersonalityDirector()

  var body: some View {
    ZStack {
      NativeARView(matchLog: matchLog, commentary: commentary)
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

      VStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          Text(mode.title + " Mode")
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

          Text(commentary.suggestedMoveText)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
        )
        .allowsHitTesting(false)

        Spacer()

        if let caption = commentary.caption {
          PieceSpeechBubble(caption: caption)
          .allowsHitTesting(false)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        ZStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 10) {
            Text("Match log")
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .tracking(1.8)
              .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

            Text(matchLog.syncStatus)
              .font(.system(size: 15, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.86))

            Text(commentary.latestAssessment)
              .font(.system(size: 13, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.70))

            if let remoteGameID = matchLog.remoteGameID {
              Text("Game ID: \(remoteGameID)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
                .textSelection(.enabled)
            }

            if matchLog.entries.isEmpty {
              Text("Make a legal move to start the UCI move log.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
            } else {
              ForEach(Array(matchLog.entries.suffix(6))) { entry in
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
          .padding(.top, 18)
          .padding(.horizontal, 18)
          .padding(.bottom, 116)
          .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .fill(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.82))
              .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                  .stroke(Color.white.opacity(0.14), lineWidth: 1)
              )
          )
          .allowsHitTesting(false)

          NativeActionButton(title: "Exit AR", style: .solid) {
            closeExperience()
          }
          .padding(18)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 24)
    }
    .task {
      await matchLog.prepareRemoteGameIfNeeded()
      Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await commentary.prepare(with: ChessGameState.initial())
      }
    }
    .onDisappear {
      commentary.resetSession()
      matchLog.resetSession()
    }
  }
}

private struct ChessboardBackdrop: View {
  private let rows = 14
  private let columns = 10

  var body: some View {
    GeometryReader { geometry in
      let squareSize = max(geometry.size.width / CGFloat(columns), geometry.size.height / CGFloat(rows))

      ZStack {
        Color(red: 0.07, green: 0.10, blue: 0.13)
          .ignoresSafeArea()

        ForEach(0..<rows, id: \.self) { row in
          ForEach(0..<columns, id: \.self) { column in
            Rectangle()
              .fill(squareColor(row: row, column: column))
              .frame(width: squareSize, height: squareSize)
              .position(
                x: (CGFloat(column) + 0.5) * squareSize,
                y: (CGFloat(row) + 0.5) * squareSize
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

private struct NativeActionButton: View {
  enum ButtonStyleKind {
    case solid
    case outline
  }

  let title: String
  let style: ButtonStyleKind
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .foregroundStyle(foregroundColor)
        .background(background)
    }
    .buttonStyle(.plain)
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
}

private enum ChessPieceKind {
  case pawn
  case rook
  case knight
  case bishop
  case queen
  case king

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
}

private struct BoardSquare: Hashable {
  let file: Int
  let rank: Int

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
  var board: [BoardSquare: ChessPieceState]
  var turn: ChessColor
  var castlingRights: CastlingRights
  var enPassantTarget: BoardSquare?
  var halfmoveClock: Int
  var fullmoveNumber: Int

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

  func isInCheck(for color: ChessColor) -> Bool {
    guard let kingSquare = board.first(where: { $0.value.color == color && $0.value.kind == .king })?.key else {
      return false
    }

    return isSquareAttacked(kingSquare, by: color.opponent)
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
    for (origin, piece) in board where piece.color == attacker {
      switch piece.kind {
      case .pawn:
        let direction = piece.color == .white ? 1 : -1
        if origin.offset(file: -1, rank: direction) == target || origin.offset(file: 1, rank: direction) == target {
          return true
        }
      case .knight:
        let offsets = [
          (1, 2), (2, 1), (2, -1), (1, -2),
          (-1, -2), (-2, -1), (-2, 1), (-1, 2),
        ]
        if offsets.contains(where: { origin.offset(file: $0.0, rank: $0.1) == target }) {
          return true
        }
      case .bishop:
        if attacksAlongDirections(from: origin, target: target, directions: [(1, 1), (1, -1), (-1, -1), (-1, 1)]) {
          return true
        }
      case .rook:
        if attacksAlongDirections(from: origin, target: target, directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          return true
        }
      case .queen:
        if attacksAlongDirections(
          from: origin,
          target: target,
          directions: [
            (1, 1), (1, -1), (-1, -1), (-1, 1),
            (1, 0), (-1, 0), (0, 1), (0, -1),
          ]
        ) {
          return true
        }
      case .king:
        if abs(origin.file - target.file) <= 1, abs(origin.rank - target.rank) <= 1 {
          return true
        }
      }
    }

    return false
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

private struct NativeARView: UIViewRepresentable {
  @ObservedObject var matchLog: MatchLogStore
  @ObservedObject var commentary: PiecePersonalityDirector

  func makeCoordinator() -> Coordinator {
    Coordinator(matchLog: matchLog, commentary: commentary)
  }

  func makeUIView(context: Context) -> ARView {
    let arView = ARView(frame: .zero)
    context.coordinator.configure(arView)
    return arView
  }

  func updateUIView(_ uiView: ARView, context: Context) {}

  final class Coordinator: NSObject, ARSessionDelegate {
    private let boardSize: Float = 0.40
    private let boardInset: Float = 0.08
    private let matchLog: MatchLogStore
    private let commentary: PiecePersonalityDirector
    private weak var arView: ARView?
    private var boardAnchor: AnchorEntity?
    private var boardWorldTransform: simd_float4x4?
    private var boardRoot = Entity()
    private var piecesContainer = Entity()
    private var highlightsContainer = Entity()
    private var trackedPlaneID: UUID?
    private var gameState = ChessGameState.initial()
    private var selectedSquare: BoardSquare?
    private var selectedMoves: [ChessMove] = []

    init(matchLog: MatchLogStore, commentary: PiecePersonalityDirector) {
      self.matchLog = matchLog
      self.commentary = commentary
    }

    func configure(_ arView: ARView) {
      self.arView = arView
      arView.automaticallyConfigureSession = false
      arView.environment.background = .cameraFeed()
      arView.renderOptions.insert(.disableMotionBlur)

      let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      arView.addGestureRecognizer(tapRecognizer)

      guard ARWorldTrackingConfiguration.isSupported else {
        return
      }

      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.environmentTexturing = .automatic

      if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        configuration.frameSemantics.insert(.sceneDepth)
      }

      if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
        configuration.frameSemantics.insert(.personSegmentationWithDepth)
      }

      if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
        configuration.sceneReconstruction = .meshWithClassification
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        arView.environment.sceneUnderstanding.options.insert(.physics)
      } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
        configuration.sceneReconstruction = .mesh
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
      }

      arView.session.delegate = self
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

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
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      updateBoardPlacement(session: session, anchors: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      updateBoardPlacement(session: session, anchors: anchors)
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard let arView else {
        return
      }

      let location = recognizer.location(in: arView)

      if let entity = arView.entity(at: location) {
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

    private func boardSquare(at location: CGPoint, in arView: ARView) -> BoardSquare? {
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
      let localX = localPoint4.x
      let localZ = localPoint4.z
      let halfBoard = boardSize * 0.5

      guard localX >= -halfBoard, localX <= halfBoard, localZ >= -halfBoard, localZ <= halfBoard else {
        clearSelection()
        return nil
      }

      let squareSize = boardSize / 8.0
      let file = Int(floor((localX + halfBoard) / squareSize))
      let rank = Int(floor((halfBoard - localZ) / squareSize))
      let square = BoardSquare(
        file: max(0, min(7, file)),
        rank: max(0, min(7, rank))
      )

      guard square.isValid else {
        return nil
      }

      return square
    }

    private func handleTapOnPiece(at square: BoardSquare) {
      guard let piece = gameState.piece(at: square) else {
        clearSelection()
        return
      }

      if piece.color == gameState.turn {
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

      if let piece = gameState.piece(at: square), piece.color == gameState.turn {
        select(square)
      } else {
        clearSelection()
      }
    }

    private func select(_ square: BoardSquare) {
      selectedSquare = square
      selectedMoves = gameState.legalMoves(from: square)

      if selectedMoves.isEmpty {
        selectedSquare = nil
      }

      refreshBoardPresentation()
    }

    private func clearSelection() {
      selectedSquare = nil
      selectedMoves = []
      refreshBoardPresentation()
    }

    private func apply(_ move: ChessMove) {
      let movingColor = gameState.turn
      let beforeState = gameState
      let afterState = gameState.applying(move)
      gameState = afterState
      selectedSquare = nil
      selectedMoves = []
      refreshBoardPresentation()
      Task { @MainActor in
        matchLog.recordMove(move.uciString, color: movingColor)
        await commentary.handleMove(move: move, before: beforeState, after: afterState)
      }
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

      let transform = boardTransform(for: selectedPlane, frame: frame)

      if let arView {
        let boardAnchor = AnchorEntity(world: transform)
        boardAnchor.addChild(makeBoardEntity())
        arView.scene.addAnchor(boardAnchor)
        self.boardAnchor = boardAnchor
        boardWorldTransform = transform
        refreshBoardPresentation()
      }

      trackedPlaneID = selectedPlane.identifier
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

      let minExtent = boardSize + (boardInset * 2)
      guard plane.extent.x >= minExtent, plane.extent.z >= minExtent else {
        return false
      }

      if isTableClassification(plane.classification) {
        return true
      }

      if isUnknownClassification(plane.classification) {
        let cameraY = frame.camera.transform.columns.3.y
        let planeY = plane.transform.columns.3.y
        let verticalDrop = cameraY - planeY
        return verticalDrop > 0.10 && verticalDrop < 1.40
      }

      return false
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

    private func isUnknownClassification(_ classification: ARPlaneAnchor.Classification) -> Bool {
      switch classification {
      case ARPlaneAnchor.Classification.none:
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

      let availableX = max(0, (plane.extent.x * 0.5) - (boardSize * 0.5) - boardInset)
      let availableZ = max(0, (plane.extent.z * 0.5) - (boardSize * 0.5) - boardInset)

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
      self.boardRoot = boardRoot
      piecesContainer = Entity()
      highlightsContainer = Entity()

      let squareSize = boardSize / 8.0
      let baseMesh = MeshResource.generateBox(size: SIMD3<Float>(boardSize + 0.03, 0.012, boardSize + 0.03))
      let baseMaterial = SimpleMaterial(
        color: UIColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 1),
        roughness: 0.65,
        isMetallic: false
      )
      let baseEntity = ModelEntity(mesh: baseMesh, materials: [baseMaterial])
      baseEntity.position = SIMD3<Float>(0, -0.010, 0)
      boardRoot.addChild(baseEntity)

      for rank in 0..<8 {
        for file in 0..<8 {
          let squareMesh = MeshResource.generateBox(size: SIMD3<Float>(squareSize, 0.004, squareSize))
          let squareColor: UIColor = (rank + file).isMultiple(of: 2)
            ? UIColor(red: 0.93, green: 0.88, blue: 0.79, alpha: 1)
            : UIColor(red: 0.22, green: 0.18, blue: 0.15, alpha: 1)

          let squareMaterial = SimpleMaterial(color: squareColor, roughness: 0.35, isMetallic: false)
          let squareEntity = ModelEntity(mesh: squareMesh, materials: [squareMaterial])
          let square = BoardSquare(file: file, rank: rank)
          squareEntity.position = boardPosition(square, squareSize: squareSize)
          squareEntity.name = squareName(square)
          squareEntity.generateCollisionShapes(recursive: false)
          boardRoot.addChild(squareEntity)
        }
      }

      boardRoot.addChild(highlightsContainer)
      boardRoot.addChild(piecesContainer)
      return boardRoot
    }

    private func refreshBoardPresentation() {
      syncPieceEntities()
      syncHighlights()
    }

    private func syncPieceEntities() {
      Array(piecesContainer.children).forEach { $0.removeFromParent() }
      let squareSize = boardSize / 8.0

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

        let pieceEntity = makePieceEntity(kind: piece.kind, material: pieceMaterial(for: piece.color))
        pieceEntity.name = pieceName(square)
        pieceEntity.position = boardPosition(square, squareSize: squareSize)

        if selectedSquare == square {
          pieceEntity.position.y += 0.016
          pieceEntity.scale = SIMD3<Float>(repeating: 1.06)
        }

        pieceEntity.generateCollisionShapes(recursive: true)
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
    }

    private func makeHighlightEntity(size: Float, color: UIColor) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(size, 0.0012, size)),
        materials: [SimpleMaterial(color: color, roughness: 0.15, isMetallic: false)]
      )
    }

    private func squareName(_ square: BoardSquare) -> String {
      "square_\(square.file)_\(square.rank)"
    }

    private func pieceName(_ square: BoardSquare) -> String {
      "piece_\(square.file)_\(square.rank)"
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

    private func pieceMaterial(for color: ChessColor) -> SimpleMaterial {
      switch color {
      case .white:
        return SimpleMaterial(
          color: UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1),
          roughness: 0.24,
          isMetallic: true
        )
      case .black:
        return SimpleMaterial(
          color: UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1),
          roughness: 0.28,
          isMetallic: true
        )
      }
    }

    private func boardPosition(_ square: BoardSquare, squareSize: Float) -> SIMD3<Float> {
      let x = (Float(square.file) - 3.5) * squareSize
      let z = (3.5 - Float(square.rank)) * squareSize
      return SIMD3<Float>(x, 0.004, z)
    }

    private func makeColumn(width: Float, height: Float, depth: Float, material: SimpleMaterial) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width, height, depth)),
        materials: [material]
      )
    }

    private func makePieceEntity(kind: ChessPieceKind, material: SimpleMaterial) -> Entity {
      let root = Entity()

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

      case .rook:
        let tower = makeColumn(width: 0.020, height: 0.026, depth: 0.020, material: material)
        tower.position.y = 0.019
        root.addChild(tower)

        let crown = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.024, 0.007, 0.024)), materials: [material])
        crown.position.y = 0.036
        root.addChild(crown)

      case .knight:
        let body = makeColumn(width: 0.018, height: 0.018, depth: 0.018, material: material)
        body.position.y = 0.015
        root.addChild(body)

        let neck = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.016, 0.028, 0.010)), materials: [material])
        neck.position = SIMD3<Float>(0, 0.034, -0.003)
        neck.orientation = simd_quatf(angle: -.pi / 9, axis: SIMD3<Float>(1, 0, 0))
        root.addChild(neck)

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

      case .queen:
        let body = makeColumn(width: 0.020, height: 0.030, depth: 0.020, material: material)
        body.position.y = 0.021
        root.addChild(body)

        let crown = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [material])
        crown.position.y = 0.044
        root.addChild(crown)

      case .king:
        let body = makeColumn(width: 0.020, height: 0.034, depth: 0.020, material: material)
        body.position.y = 0.023
        root.addChild(body)

        let crossStem = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.004, 0.014, 0.004)), materials: [material])
        crossStem.position.y = 0.046
        root.addChild(crossStem)

        let crossBar = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.012, 0.004, 0.004)), materials: [material])
        crossBar.position.y = 0.048
        root.addChild(crossBar)
      }

      return root
    }
  }
}
