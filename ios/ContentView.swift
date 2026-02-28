import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    var body: some View {
        ARViewContainer()
            .ignoresSafeArea()
    }
}

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Basic world tracking + horizontal plane detection
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config)

        // Add a simple red sphere 0.3m in front of the camera
        let sphere = MeshResource.generateSphere(radius: 0.05)
        let material = SimpleMaterial(color: .red, isMetallic: false)
        let entity = ModelEntity(mesh: sphere, materials: [material])

        let anchor = AnchorEntity(world: [0, 0, -0.3])
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
