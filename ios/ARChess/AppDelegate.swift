import ARKit
import RealityKit
import SwiftUI
import UIKit
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

  var body: some View {
    ZStack {
      NativeARView()
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

      VStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          Text(mode.title + " Mode")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(Color(red: 0.87, green: 0.79, blue: 0.64))

          Text("Native AR Sandbox")
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)

          Text("RealityKit and ARKit are running inside the iOS app. Scan a clear table and the board will settle closer to you for a higher-angle playing view.")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.86))
            .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
        )

        Spacer()

        VStack(alignment: .leading, spacing: 10) {
          Text("Native only")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(Color(red: 0.88, green: 0.82, blue: 0.70))

          Text("The board now waits for a clear table-sized surface and uses native placeholder pieces until real assets are added.")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.86))

          NativeActionButton(title: "Exit AR", style: .solid) {
            closeExperience()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.82))
            .overlay(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        )
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 24)
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

private struct NativeARView: UIViewRepresentable {
  func makeCoordinator() -> Coordinator {
    Coordinator()
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
    private weak var arView: ARView?
    private var boardAnchor: AnchorEntity?
    private var trackedPlaneID: UUID?

    func configure(_ arView: ARView) {
      self.arView = arView
      arView.automaticallyConfigureSession = false
      arView.environment.background = .cameraFeed()
      arView.renderOptions.insert(.disableMotionBlur)

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

    private func updateBoardPlacement(session: ARSession, anchors: [ARAnchor]) {
      guard let frame = session.currentFrame else {
        return
      }

      let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
      guard let selectedPlane = selectBestPlane(from: planes, frame: frame) else {
        return
      }

      let transform = boardTransform(for: selectedPlane, frame: frame)

      if let boardAnchor {
        boardAnchor.transform = Transform(matrix: transform)
      } else if let arView {
        let boardAnchor = AnchorEntity(world: transform)
        boardAnchor.addChild(makeBoardEntity())
        arView.scene.addAnchor(boardAnchor)
        self.boardAnchor = boardAnchor
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

      if plane.classification.rawValue == ARPlaneAnchor.Classification.table.rawValue {
        return true
      }

      if plane.classification.rawValue == ARPlaneAnchor.Classification.none.rawValue {
        let cameraY = frame.camera.transform.columns.3.y
        let planeY = plane.transform.columns.3.y
        let verticalDrop = cameraY - planeY
        let largestExtent = max(plane.extent.x, plane.extent.z)
        return verticalDrop > 0.22 && verticalDrop < 1.15 && largestExtent < 1.75
      }

      return false
    }

    private func planeScore(_ plane: ARPlaneAnchor, frame: ARFrame) -> Float {
      let area = plane.extent.x * plane.extent.z
      let cameraPosition = simd_make_float3(frame.camera.transform.columns.3)
      let planePosition = simd_make_float3(plane.transform.columns.3)
      let distance = simd_distance(cameraPosition, planePosition)
      let classificationBonus: Float =
        plane.classification.rawValue == ARPlaneAnchor.Classification.table.rawValue ? 2.0 : 0.0
      return classificationBonus + area - (distance * 0.35)
    }

    private func boardTransform(for plane: ARPlaneAnchor, frame: ARFrame) -> simd_float4x4 {
      let planeTransform = plane.transform
      let cameraWorld = simd_make_float3(frame.camera.transform.columns.3)
      let inversePlane = planeTransform.inverse
      let cameraLocal4 = inversePlane * SIMD4<Float>(cameraWorld.x, cameraWorld.y, cameraWorld.z, 1)
      let cameraLocal = SIMD2<Float>(cameraLocal4.x, cameraLocal4.z)

      let availableX = max(0, (plane.extent.x * 0.5) - (boardSize * 0.5) - boardInset)
      let availableZ = max(0, (plane.extent.z * 0.5) - (boardSize * 0.5) - boardInset)

      let directionToPlayer = normalized(cameraLocal, fallback: SIMD2<Float>(0, 1))
      let desiredOffset = SIMD2<Float>(
        clamp(directionToPlayer.x * min(0.10, availableX), min: -availableX, max: availableX),
        clamp(directionToPlayer.y * min(0.16, availableZ), min: -availableZ, max: availableZ)
      )

      let localPosition = SIMD3<Float>(desiredOffset.x, 0.008, desiredOffset.y)
      let worldPosition4 = planeTransform * SIMD4<Float>(localPosition.x, localPosition.y, localPosition.z, 1)
      let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)

      let lookVector = normalized(
        SIMD2<Float>(cameraWorld.x - worldPosition.x, cameraWorld.z - worldPosition.z),
        fallback: SIMD2<Float>(0, 1)
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

      for row in 0..<8 {
        for column in 0..<8 {
          let squareMesh = MeshResource.generateBox(size: SIMD3<Float>(squareSize, 0.004, squareSize))
          let squareColor: UIColor = (row + column).isMultiple(of: 2)
            ? UIColor(red: 0.93, green: 0.88, blue: 0.79, alpha: 1)
            : UIColor(red: 0.22, green: 0.18, blue: 0.15, alpha: 1)

          let squareMaterial = SimpleMaterial(color: squareColor, roughness: 0.35, isMetallic: false)
          let squareEntity = ModelEntity(mesh: squareMesh, materials: [squareMaterial])
          squareEntity.position = SIMD3<Float>((Float(column) - 3.5) * squareSize, 0, (Float(row) - 3.5) * squareSize)
          boardRoot.addChild(squareEntity)
        }
      }

      addInitialPieces(to: boardRoot, squareSize: squareSize)

      return boardRoot
    }

    private func addInitialPieces(to boardRoot: Entity, squareSize: Float) {
      let backRank: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
      let whiteMaterial = SimpleMaterial(color: UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1), roughness: 0.24, isMetallic: true)
      let blackMaterial = SimpleMaterial(color: UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1), roughness: 0.28, isMetallic: true)

      for file in 0..<8 {
        let whiteBackPiece = makePieceEntity(kind: backRank[file], material: whiteMaterial)
        whiteBackPiece.position = boardPosition(file: file, rankFromWhiteSide: 0, squareSize: squareSize)
        boardRoot.addChild(whiteBackPiece)

        let whitePawn = makePieceEntity(kind: .pawn, material: whiteMaterial)
        whitePawn.position = boardPosition(file: file, rankFromWhiteSide: 1, squareSize: squareSize)
        boardRoot.addChild(whitePawn)

        let blackPawn = makePieceEntity(kind: .pawn, material: blackMaterial)
        blackPawn.position = boardPosition(file: file, rankFromWhiteSide: 6, squareSize: squareSize)
        boardRoot.addChild(blackPawn)

        let blackBackPiece = makePieceEntity(kind: backRank[file], material: blackMaterial)
        blackBackPiece.position = boardPosition(file: file, rankFromWhiteSide: 7, squareSize: squareSize)
        boardRoot.addChild(blackBackPiece)
      }
    }

    private func boardPosition(file: Int, rankFromWhiteSide: Int, squareSize: Float) -> SIMD3<Float> {
      let x = (Float(file) - 3.5) * squareSize
      let z = (3.5 - Float(rankFromWhiteSide)) * squareSize
      return SIMD3<Float>(x, 0.004, z)
    }

    private func makeColumn(width: Float, height: Float, depth: Float, material: SimpleMaterial) -> ModelEntity {
      ModelEntity(
        mesh: .generateBox(size: SIMD3<Float>(width, height, depth)),
        materials: [material]
      )
    }

    private func makePieceEntity(kind: PieceKind, material: SimpleMaterial) -> Entity {
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

  enum PieceKind {
    case pawn
    case rook
    case knight
    case bishop
    case queen
    case king
  }
}
