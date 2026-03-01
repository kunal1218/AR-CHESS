import AVFoundation
import ARKit
import CryptoKit
import Foundation
import OSLog
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

private enum PlayModeChoice: Hashable {
  case passAndPlay
  case queueMatch

  var title: String {
    switch self {
    case .passAndPlay:
      return "Pass & Play"
    case .queueMatch:
      return "Queue Match"
    }
  }
}

private enum ExperienceMode: Hashable {
  case passAndPlay(PlayerMode)
  case queueMatch
}

private enum NativeScreen {
  case modeSelection
  case landing
  case lobby(PlayerMode)
  case queueMatch
  case experience(ExperienceMode)
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

private struct StockfishAnalysis {
  let fen: String
  let sideToMove: ChessColor
  let requestID: String
  let durationMs: Int
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

  var whitePerspectiveScore: Int {
    sideToMove == .white ? normalizedScore : -normalizedScore
  }

  var blackPerspectiveScore: Int {
    -whitePerspectiveScore
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
  // Cold boot inside a hidden WKWebView is slower than a normal search and should not share the same budget.
  var startupTimeoutMs = 6_000
  var readyTimeoutMs = 1_500
  var threads = 1
  var hashMB = 16
  var strictFENValidation = false
}

private struct StockfishSearchOptions {
  var movetimeMs: Int?
  var debugDepth: Int?
  var hardTimeoutMs: Int?

  static func realtime(movetimeMs: Int = 80, hardTimeoutMs: Int = 600) -> Self {
    StockfishSearchOptions(
      movetimeMs: movetimeMs,
      debugDepth: nil,
      hardTimeoutMs: hardTimeoutMs
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
  private var engineState: StockfishControllerState = .initialize
  private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var currentSearch: PendingSearch?
  private var timeoutTask: Task<Void, Never>?
  private var commandBuffer = FixedRingBuffer<String>(capacity: 50)
  private var lineBuffer = FixedRingBuffer<String>(capacity: 300)
  private var requestCounter = 0
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
      hardTimeoutMs: options.hardTimeoutMs ?? max(config.hardTimeoutMs, (options.movetimeMs ?? config.defaultMovetimeMs) * 4)
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

    if let webView {
      webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
      webView.navigationDelegate = nil
      webView.stopLoading()
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

    try await waitUntilReady(timeoutMs: config.startupTimeoutMs)
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
    webView.isHidden = true
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
    let analysis = StockfishAnalysis(
      fen: pending.fen,
      sideToMove: pending.sideToMove,
      requestID: requestID,
      durationMs: durationMs,
      scoreCp: payload["scoreCp"] as? Int,
      mateIn: payload["mateIn"] as? Int,
      pv: payload["pv"] as? [String] ?? [],
      bestMove: bestMove
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
              startedAtMs: Date.now(),
              scoreCp: null,
              mateIn: null,
              pv: [],
            };
            bridgeState.queuedRequest = null;
            const searchLabel = request.debugDepth ? ('Analyzing depth ' + request.debugDepth + '...') : ('Analyzing movetime ' + request.movetimeMs + 'ms...');
            bridgeStateChange('THINKING', searchLabel);
            sendEngineCommand('position fen ' + request.fen);
            if (request.debugDepth) {
              sendEngineCommand('go depth ' + request.debugDepth);
            } else {
              sendEngineCommand('go movetime ' + request.movetimeMs);
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

            const cpMatch = line.match(/score cp (-?\\d+)/);
            if (cpMatch) {
              current.scoreCp = parseInt(cpMatch[1], 10);
              current.mateIn = null;
            }

            const mateMatch = line.match(/score mate (-?\\d+)/);
            if (mateMatch) {
              current.mateIn = parseInt(mateMatch[1], 10);
              current.scoreCp = null;
            }

            const pvMatch = line.match(/\\spv\\s(.+)/);
            if (pvMatch) {
              current.pv = pvMatch[1].trim().split(/\\s+/).filter(Boolean);
            }
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

              bridgePost({
                type: 'result',
                id: finished.id,
                scoreCp: finished.scoreCp,
                mateIn: finished.mateIn,
                pv: finished.pv || [],
                bestMove: parts[1] || null,
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
  private static let preferredMovetimeMs = 80
  private static let preferredHardTimeoutMs = 600
  private static let commentaryIntervalRange = 3...4
  private static let substantialGainThreshold = 120
  private static let substantialDropThreshold = -140

  struct ReactionCue {
    enum Kind {
      case enemyKingPrays(color: ChessColor)
      case currentKingCries(color: ChessColor)
    }

    let kind: Kind
  }

  struct Caption {
    let speaker: PersonalitySpeaker
    let line: String

    var speakerName: String {
      speaker.displayName
    }
  }

  @Published private(set) var caption: Caption?
  @Published private(set) var analysisStatus = "Waiting for AR tracking to settle before warming Stockfish..."
  @Published private(set) var latestAssessment = "Waiting for initial analysis."
  @Published private(set) var suggestedMoveText = "Next best move: waiting on Stockfish..."
  @Published private(set) var whiteEvalText = "White eval: --"
  @Published private(set) var blackEvalText = "Black eval: --"
  @Published private(set) var analysisTimingText = "No completed analysis yet."

  private let analyzer = StockfishWASMAnalyzer()
  private let synthesizer = AVSpeechSynthesizer()
  private var utteranceCaptions: [ObjectIdentifier: Caption] = [:]
  private var cachedAnalysis: CachedAnalysis?
  private var completedPlyCount = 0
  private var nextCommentaryPly = Int.random(in: commentaryIntervalRange)
  private var reactionHandler: ((ReactionCue) -> Void)?
  private var stateProvider: (() -> ChessGameState?)?

  override init() {
    super.init()
    synthesizer.delegate = self
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
          hardTimeoutMs: Self.preferredHardTimeoutMs
        )
      )
      cachedAnalysis = CachedAnalysis(fen: fen, analysis: analysis)
      updateAnalysisPresentation(analysis)
      analysisStatus = "Stockfish movetime \(Self.preferredMovetimeMs)ms ready."
      latestAssessment = "Prep eval: \(describe(analysis: analysis, moverColor: state.turn))."
    } catch {
      let message = analyzer.lastError ?? error.localizedDescription
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(message)"
      suggestedMoveText = "Next best move unavailable."
      whiteEvalText = "White eval: --"
      blackEvalText = "Black eval: --"
      analysisTimingText = "Analysis failed."
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
    analysisStatus = "Waiting for AR tracking to settle before warming Stockfish..."
    latestAssessment = "Waiting for initial analysis."
    suggestedMoveText = "Next best move: waiting on Stockfish..."
    whiteEvalText = "White eval: --"
    blackEvalText = "Black eval: --"
    analysisTimingText = "No completed analysis yet."
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
  }

  func unbindStateProvider() {
    stateProvider = nil
  }

  func analyzeCurrentPosition() async {
    guard let state = stateProvider?() else {
      latestAssessment = "No board state available for manual analysis."
      return
    }

    analysisStatus = "Manual analysis requested..."
    await prepare(with: state, force: true)
  }

  func bindReactionHandler(_ handler: @escaping (ReactionCue) -> Void) {
    reactionHandler = handler
  }

  func unbindReactionHandler() {
    reactionHandler = nil
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
      updateAnalysisPresentation(afterAnalysis)
      analysisStatus = "Stockfish movetime \(Self.preferredMovetimeMs)ms live."
    } else if analyzer.lastError != nil {
      analysisStatus = "Stockfish unavailable. Last stage: \(analyzer.lastStatus)"
      latestAssessment = "Stockfish error: \(analyzer.lastError ?? analyzer.lastStatus)"
      suggestedMoveText = "Next best move unavailable."
      whiteEvalText = "White eval: --"
      blackEvalText = "Black eval: --"
      analysisTimingText = "Analysis failed."
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

    if let swing = evalSwing(before: beforeAnalysis, after: afterAnalysis, moverColor: beforeState.turn) {
      if swing >= Self.substantialGainThreshold {
        reactionHandler?(ReactionCue(kind: .enemyKingPrays(color: beforeState.turn.opponent)))
      } else if swing <= Self.substantialDropThreshold {
        reactionHandler?(ReactionCue(kind: .currentKingCries(color: beforeState.turn)))
        if speakRandomLine(
          from: [
            SpokenLine(
              speaker: .king,
              text: "I'm cooked.",
              pitch: 1.18,
              rate: 0.46,
              volume: 1.0
            )
          ],
          priority: .urgent
        ) {
          scheduleNextCommentaryWindow()
        }
        return
      }
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
      let analysis = try await analyzer.analyze(
        fen: fen,
        options: .realtime(
          movetimeMs: Self.preferredMovetimeMs,
          hardTimeoutMs: Self.preferredHardTimeoutMs
        )
      )
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
    guard let before, let after else {
      return nil
    }

    let beforeScore = scoreForMoverPerspective(before, moverColor: moverColor, isPostMove: false)
    let afterScore = scoreForMoverPerspective(after, moverColor: moverColor, isPostMove: true)
    return afterScore - beforeScore
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

  private func updateAnalysisPresentation(_ analysis: StockfishAnalysis) {
    suggestedMoveText = bestMoveDescription(from: analysis)
    whiteEvalText = "White eval: \(analysis.formattedEval(for: .white))"
    blackEvalText = "Black eval: \(analysis.formattedEval(for: .black))"
    analysisTimingText = "Last analysis: \(analysis.durationMs)ms"
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
  @State private var screen: NativeScreen = .modeSelection
  @StateObject private var queueMatch = QueueMatchStore()

  var body: some View {
    ZStack {
      switch screen {
      case .modeSelection:
        ModeSelectionView { mode in
          withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            switch mode {
            case .passAndPlay:
              screen = .landing
            case .queueMatch:
              screen = .queueMatch
            }
          }
        }
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
              screen = .experience(.passAndPlay(mode))
            }
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
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
              screen = .experience(.queueMatch)
            }
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
      case .experience(let mode):
        NativeARExperienceView(mode: mode, queueMatch: queueMatch) {
          switch mode {
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
          }
        }
      }
    }
  }
}

private struct ModeSelectionView: View {
  let onSelect: (PlayModeChoice) -> Void

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

          Text("AR Chess")
            .font(.system(size: 50, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text("Choose a local pass-and-play board or a synced queue match.")
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
        }

        VStack(spacing: 14) {
          NativeActionButton(title: "Pass & Play", style: .solid) {
            onSelect(.passAndPlay)
          }

          NativeActionButton(title: "Queue Match", style: .outline) {
            onSelect(.queueMatch)
          }
        }
        .frame(maxWidth: 340)

        Text("Pass & Play stays unchanged • Queue Match syncs through Railway")
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.72))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)

        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 30)
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

private struct NativeARExperienceView: View {
  let mode: ExperienceMode
  @ObservedObject var queueMatch: QueueMatchStore
  let closeExperience: () -> Void
  @StateObject private var matchLog = MatchLogStore()
  @StateObject private var commentary = PiecePersonalityDirector()

  var body: some View {
    ZStack {
      NativeARView(matchLog: matchLog, queueMatch: queueMatch, mode: mode, commentary: commentary)
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

          Text(commentary.suggestedMoveText)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))

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

            NativeActionButton(title: "Analyze current position", style: .outline) {
              Task {
                await commentary.analyzeCurrentPosition()
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
        )

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
      if case .passAndPlay(_) = mode {
        await matchLog.prepareRemoteGameIfNeeded()
      } else {
        await queueMatch.activateMatchSync()
      }
    }
    .onDisappear {
      commentary.resetSession()
      commentary.unbindStateProvider()
      commentary.unbindReactionHandler()
      switch mode {
      case .passAndPlay(_):
        matchLog.resetSession()
      case .queueMatch:
        Task {
          await queueMatch.exitQueueFlow()
        }
      }
    }
  }

  private var modeTitle: String {
    switch mode {
    case .passAndPlay(let playerMode):
      return playerMode.title + " Mode"
    case .queueMatch:
      return "Queue Match"
    }
  }

  private var activeEntries: [MatchLogStore.Entry] {
    switch mode {
    case .passAndPlay(_):
      return matchLog.entries
    case .queueMatch:
      return queueMatch.logEntries
    }
  }

  private var activeRemoteGameID: String? {
    switch mode {
    case .passAndPlay(_):
      return matchLog.remoteGameID
    case .queueMatch:
      return queueMatch.remoteGameID
    }
  }

  private var activeSyncStatus: String {
    switch mode {
    case .passAndPlay(_):
      return matchLog.syncStatus
    case .queueMatch:
      return queueMatch.statusText
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
  @ObservedObject var queueMatch: QueueMatchStore
  let mode: ExperienceMode
  @ObservedObject var commentary: PiecePersonalityDirector

  func makeCoordinator() -> Coordinator {
    Coordinator(matchLog: matchLog, queueMatch: queueMatch, mode: mode, commentary: commentary)
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
    private let queueMatch: QueueMatchStore
    private let mode: ExperienceMode
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
    private var syncedQueueMoves: [QueueMatchMovePayload] = []
    private var queueAssignedColor: ChessColor?
    private var hasBoundReactionHandler = false
    private var stableTrackingFrames = 0
    private var hasScheduledInitialAnalysis = false
    private var initialAnalysisTask: Task<Void, Never>?
    private var lastWarmupStatusMessage: String?

    init(
      matchLog: MatchLogStore,
      queueMatch: QueueMatchStore,
      mode: ExperienceMode,
      commentary: PiecePersonalityDirector
    ) {
      self.matchLog = matchLog
      self.queueMatch = queueMatch
      self.mode = mode
      self.commentary = commentary
    }

    deinit {
      initialAnalysisTask?.cancel()
    }

    func configure(_ arView: ARView) {
      self.arView = arView
      arView.automaticallyConfigureSession = false
      arView.environment.background = .cameraFeed()
      arView.renderOptions.insert(.disableMotionBlur)
      noteWarmupStatus("Waiting for board placement before warming Stockfish...")

      let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      arView.addGestureRecognizer(tapRecognizer)

      guard ARWorldTrackingConfiguration.isSupported else {
        return
      }

      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.environmentTexturing = .automatic

      if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
        configuration.sceneReconstruction = .meshWithClassification
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
      } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
        configuration.sceneReconstruction = .mesh
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
      }

      arView.session.delegate = self
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

      if !hasBoundReactionHandler {
        hasBoundReactionHandler = true
        Task { @MainActor [weak self] in
          guard let self else {
            return
          }

          self.commentary.bindReactionHandler { [weak self] cue in
            self?.handleReactionCue(cue)
          }
          self.commentary.bindStateProvider { [weak self] in
            self?.gameState
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
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      updateBoardPlacement(session: session, anchors: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      updateBoardPlacement(session: session, anchors: anchors)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      updateTrackingReadiness(frame)
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

    private func applyServerMoveSet(_ moves: [QueueMatchMovePayload]) {
      let orderedMoves = moves.sorted(by: { $0.ply < $1.ply })
      guard orderedMoves != syncedQueueMoves else {
        return
      }

      let previousMoveCount = syncedQueueMoves.count
      var rebuiltState = ChessGameState.initial()
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
        if payload.ply > previousMoveCount {
          newMoves.append((move: move, before: beforeState, after: afterState))
        }
        rebuiltState = afterState
      }

      syncedQueueMoves = orderedMoves
      gameState = rebuiltState
      selectedSquare = nil
      selectedMoves = []
      refreshBoardPresentation()

      guard !newMoves.isEmpty else {
        return
      }

      Task { @MainActor in
        for item in newMoves {
          await commentary.handleMove(move: item.move, before: item.before, after: item.after)
        }
      }
    }

    private func handleReactionCue(_ cue: PiecePersonalityDirector.ReactionCue) {
      switch cue.kind {
      case .enemyKingPrays(let color):
        animateKingPrayer(for: color)
      case .currentKingCries(let color):
        animateKingCrying(for: color)
      }
    }

    private func canControlPiece(_ piece: ChessPieceState, at square: BoardSquare) -> Bool {
      guard piece.color == gameState.turn else {
        return false
      }

      switch mode {
      case .passAndPlay(_):
        return true
      case .queueMatch:
        guard let assignedColor = queueAssignedColor,
              assignedColor == gameState.turn else {
          clearSelection()
          return false
        }
        return piece.color == assignedColor
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
      maybeScheduleInitialAnalysis()
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
        noteWarmupStatus("Waiting for board placement before warming Stockfish...")
      } else if stableTrackingFrames < 30 {
        noteWarmupStatus("Waiting for AR tracking to stabilize before warming Stockfish...")
      } else {
        maybeScheduleInitialAnalysis()
      }
    }

    private func maybeScheduleInitialAnalysis() {
      guard !hasScheduledInitialAnalysis else {
        return
      }

      guard boardAnchor != nil else {
        return
      }

      guard stableTrackingFrames >= 30 else {
        return
      }

      hasScheduledInitialAnalysis = true
      noteWarmupStatus("Tracking stable. Warming local Stockfish...")
      initialAnalysisTask?.cancel()
      initialAnalysisTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let self else {
          return
        }

        guard self.boardAnchor != nil, self.stableTrackingFrames >= 30 else {
          self.hasScheduledInitialAnalysis = false
          self.noteWarmupStatus("AR tracking slipped. Waiting to warm Stockfish again...")
          return
        }

        await self.commentary.prepare(with: self.gameState, force: true)
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

        let leftHand = ModelEntity(mesh: .generateSphere(radius: 0.0048), materials: [material])
        leftHand.name = "king_hand_left"
        leftHand.position = SIMD3<Float>(-0.022, 0.029, 0.001)
        root.addChild(leftHand)

        let rightHand = ModelEntity(mesh: .generateSphere(radius: 0.0048), materials: [material])
        rightHand.name = "king_hand_right"
        rightHand.position = SIMD3<Float>(0.022, 0.029, 0.001)
        root.addChild(rightHand)

        let crossStem = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.004, 0.014, 0.004)), materials: [material])
        crossStem.position.y = 0.046
        root.addChild(crossStem)

        let crossBar = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.012, 0.004, 0.004)), materials: [material])
        crossBar.position.y = 0.048
        root.addChild(crossBar)

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
