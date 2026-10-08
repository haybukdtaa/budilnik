import Combine
import RealityKit
import SwiftUI
import UIKit

/// Одно дерево в 3D-саду.
struct GardenTreeSpec: Equatable, Identifiable {
    var index: Int
    var species: TreeSpecies
    /// 0 = семечко ... 7 = вековое дерево.
    var stage: Int
    var wilt: Int = 0
    var flowers = false
    var fruits = false
    /// Дерево, которое растёт сейчас (стоит в центре сада).
    var isCurrent = false
    /// Когда выросло (у выросших деревьев).
    var grownAt: Date?

    var id: Int { index }
}

/// Где стоит каждое дерево: растущее — в центре, выросшие — по спирали золотого угла, чтобы не загораживать друг друга.
enum GardenLayout {
    static let goldenAngle: Float = 2.399963

    static func position(forGrown order: Int) -> SIMD3<Float> {
        let angle = Float(order) * goldenAngle
        let radius = 2.0 + 1.05 * Float(order).squareRoot()
        return SIMD3(radius * sin(angle), 0, radius * cos(angle))
    }

    static func groundRadius(grownCount: Int) -> Float {
        guard grownCount > 0 else { return 3.2 }
        return 2.0 + 1.05 * Float(grownCount - 1).squareRoot() + 1.8
    }

    /// Сад для предпросмотра: как он будет выглядеть через годы.
    static var preview: [GardenTreeSpec] {
        let species: [TreeSpecies] = [.oak, .sakura, .pine, .birch, .maple, .palm]
        var trees = (0..<11).map { i in
            GardenTreeSpec(index: i, species: species[i % species.count], stage: 7, flowers: i % 2 == 0, fruits: i % 3 == 0)
        }
        trees.append(GardenTreeSpec(index: 11, species: .sakura, stage: 5, flowers: true, isCurrent: true))
        return trees
    }
}

/// Время суток для света и неба.
enum GardenDaytime {
    case dawn, day, evening, night

    static func at(hour: Int) -> GardenDaytime {
        switch hour {
        case 5..<8: return .dawn
        case 8..<17: return .day
        case 17..<21: return .evening
        default: return .night
        }
    }
}

/// 3D-сад: вращается пальцем, приближается щипком, дерево выбирается касанием.
struct Garden3DView: UIViewRepresentable {
    let trees: [GardenTreeSpec]
    var daytime: GardenDaytime = .at(hour: Calendar.current.component(.hour, from: Date()))
    var onSelect: (GardenTreeSpec?) -> Void = { _ in }

    func makeCoordinator() -> GardenSceneController { GardenSceneController() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        context.coordinator.attach(to: view)
        context.coordinator.onSelect = onSelect
        context.coordinator.build(trees: trees, daytime: daytime)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.trees != trees || context.coordinator.daytime != daytime {
            context.coordinator.build(trees: trees, daytime: daytime)
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: GardenSceneController) {
        coordinator.stop()
    }
}

@MainActor
final class GardenSceneController: NSObject {
    private weak var view: ARView?
    private var root = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private var updates: Cancellable?

    private(set) var trees: [GardenTreeSpec] = []
    private(set) var daytime: GardenDaytime = .day
    var onSelect: (GardenTreeSpec?) -> Void = { _ in }

    // Камера по орбите вокруг центра сада.
    private var azimuth: Float = 0.7
    private var elevation: Float = 0.38
    private var distance: Float = 9
    private var minDistance: Float = 3
    private var maxDistance: Float = 30
    private var target = SIMD3<Float>(0, 1.1, 0)
    private var lastTouch = Date.distantPast

    private var swaying: [(entity: Entity, phase: Float)] = []
    private var falling: [(entity: Entity, origin: SIMD3<Float>, speed: Float, phase: Float)] = []
    private var fireflies: [(entity: Entity, center: SIMD3<Float>, phase: Float)] = []
    private var time: Float = 0

    func attach(to view: ARView) {
        self.view = view
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableCameraGrain)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(Float(event.deltaTime)) }
        }
    }

    func stop() {
        updates?.cancel()
        updates = nil
    }

    // MARK: - Сцена

    func build(trees: [GardenTreeSpec], daytime: GardenDaytime) {
        guard let view else { return }
        self.trees = trees
        self.daytime = daytime
        view.scene.anchors.removeAll()
        swaying = []
        falling = []
        fireflies = []
        root = AnchorEntity(world: .zero)
        view.scene.addAnchor(root)

        let grown = trees.filter { !$0.isCurrent }
        let groundRadius = GardenLayout.groundRadius(grownCount: grown.count)
        view.environment.background = .color(GardenPalette.sky(daytime))
        addLights(daytime: daytime, radius: groundRadius)
        addGround(radius: groundRadius)

        for (order, spec) in grown.enumerated() {
            let tree = GardenTreeBuilder.make(spec)
            tree.position = GardenLayout.position(forGrown: order)
            // Каждое дерево чуть повёрнуто: сад выглядит живым, а не расставленным по линейке.
            tree.orientation = simd_quatf(angle: Float(order) * 1.3, axis: [0, 1, 0])
            register(tree, spec: spec)
            root.addChild(tree)
        }
        if let current = trees.first(where: \.isCurrent) {
            let tree = GardenTreeBuilder.make(current)
            register(tree, spec: current)
            root.addChild(tree)
        }
        if daytime == .night || daytime == .evening { addFireflies(radius: groundRadius, count: daytime == .night ? 26 : 10) }

        maxDistance = max(12, groundRadius * 3.2)
        distance = min(maxDistance, max(6.5, groundRadius * 2.2))
        target = SIMD3(0, grown.isEmpty ? 0.7 : 1.1, 0)
        root.addChild(camera)
        camera.camera.fieldOfViewInDegrees = 48
        placeCamera()
    }

    private func register(_ tree: Entity, spec: GardenTreeSpec) {
        tree.name = "tree-\(spec.index)"
        tree.generateCollisionShapes(recursive: true)
        if let crown = tree.findEntity(named: "crown") {
            swaying.append((crown, Float(spec.index) * 0.9))
        }
        // Лепестки падают с цветущей сакуры и с цветущих деревьев.
        if spec.stage >= 3 && (spec.species == .sakura || spec.flowers) {
            let color = spec.species == .sakura ? GardenPalette.petal : GardenPalette.blossom
            let height = GardenTreeBuilder.trunkHeight(spec) + 0.4
            for i in 0..<(spec.species == .sakura ? 9 : 4) {
                let petal = ModelEntity(mesh: .generateBox(size: [0.05, 0.008, 0.035], cornerRadius: 0.004),
                                        materials: [GardenPalette.matte(color)])
                let angle = Float(i) * 2.1 + Float(spec.index)
                let origin = SIMD3<Float>(cos(angle) * 0.6, height, sin(angle) * 0.6)
                petal.position = origin
                tree.addChild(petal)
                falling.append((petal, origin, 0.18 + Float(i % 3) * 0.05, Float(i) * 0.7))
            }
        }
    }

    private func addLights(daytime: GardenDaytime, radius: Float) {
        let sun = DirectionalLight()
        sun.light.color = GardenPalette.sunColor(daytime)
        sun.light.intensity = GardenPalette.sunIntensity(daytime)
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: radius * 4, depthBias: 1.5)
        let elevation: Float = daytime == .day ? 9 : 3.5
        sun.look(at: .zero, from: [radius * 1.4, elevation, radius * 0.9], relativeTo: nil)
        root.addChild(sun)

        // Мягкая подсветка с другой стороны, чтобы тени не были чёрными.
        let fill = DirectionalLight()
        fill.light.color = GardenPalette.fillColor(daytime)
        fill.light.intensity = GardenPalette.sunIntensity(daytime) * 0.35
        fill.look(at: .zero, from: [-radius, 4, -radius * 1.2], relativeTo: nil)
        root.addChild(fill)
    }

    private func addGround(radius: Float) {
        let ground = ModelEntity(mesh: .generateCylinder(height: 0.24, radius: radius),
                                 materials: [GardenPalette.matte(GardenPalette.grass(daytime))])
        ground.position.y = -0.12
        root.addChild(ground)
        // Земляной край острова.
        let soil = ModelEntity(mesh: .generateCylinder(height: 0.5, radius: radius * 0.97),
                               materials: [GardenPalette.matte(GardenPalette.soil)])
        soil.position.y = -0.45
        root.addChild(soil)

        var random = SeededRandom(seed: 7)
        // Трава и камни: случайные, но одинаковые при каждом открытии.
        for _ in 0..<Int(radius * radius * 3) {
            let angle = random.next() * 2 * .pi
            let distance = (random.next().squareRoot()) * (radius - 0.3)
            let position = SIMD3<Float>(cos(angle) * distance, 0, sin(angle) * distance)
            if length(position) < 0.9 { continue }
            let tuft = ModelEntity(mesh: .generateCone(height: 0.12 + random.next() * 0.12, radius: 0.035),
                                   materials: [GardenPalette.matte(GardenPalette.tuft)])
            tuft.position = position + [0, 0.06, 0]
            root.addChild(tuft)
        }
        for _ in 0..<Int(radius * 2) {
            let angle = random.next() * 2 * .pi
            let distance = 1.2 + random.next() * (radius - 1.6)
            let stone = ModelEntity(mesh: .generateSphere(radius: 0.09 + random.next() * 0.1),
                                    materials: [GardenPalette.matte(GardenPalette.stone)])
            stone.scale = [1.4, 0.55, 1.1]
            stone.position = [cos(angle) * distance, 0.02, sin(angle) * distance]
            root.addChild(stone)
        }
    }

    private func addFireflies(radius: Float, count: Int) {
        var random = SeededRandom(seed: 21)
        for i in 0..<count {
            let fly = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [UnlitMaterial(color: GardenPalette.firefly)])
            let angle = random.next() * 2 * .pi
            let distance = 0.8 + random.next() * (radius - 1)
            let center = SIMD3<Float>(cos(angle) * distance, 0.5 + random.next() * 1.6, sin(angle) * distance)
            fly.position = center
            root.addChild(fly)
            fireflies.append((fly, center, Float(i) * 0.83))
        }
    }

    // MARK: - Движение

    private func tick(_ dt: Float) {
        time += dt
        for item in swaying {
            let angle = sin(time * 0.9 + item.phase) * 0.025
            item.entity.orientation = simd_quatf(angle: angle, axis: [0, 0, 1]) * simd_quatf(angle: angle * 0.6, axis: [1, 0, 0])
        }
        for item in falling {
            let fallen = (time * item.speed + item.phase).truncatingRemainder(dividingBy: 1)
            let y = item.origin.y * (1 - fallen)
            let drift = sin(time * 1.7 + item.phase) * 0.25
            item.entity.position = [item.origin.x + drift, max(0.01, y), item.origin.z + drift * 0.6]
            item.entity.orientation = simd_quatf(angle: time * 2 + item.phase, axis: normalize([1, 0.4, 0.2]))
        }
        for item in fireflies {
            let t = time * 0.5 + item.phase
            item.entity.position = item.center + [sin(t) * 0.35, sin(t * 1.7) * 0.2, cos(t * 0.8) * 0.35]
            let glow = 0.6 + 0.4 * sin(t * 3)
            item.entity.scale = SIMD3(repeating: glow)
        }
        // Пока сад не трогают, он медленно поворачивается.
        if Date().timeIntervalSince(lastTouch) > 4 {
            azimuth += dt * 0.06
            placeCamera()
        }
    }

    private func placeCamera() {
        let horizontal = distance * cos(elevation)
        let position = target + SIMD3(horizontal * sin(azimuth), distance * sin(elevation), horizontal * cos(azimuth))
        camera.look(at: target, from: position, relativeTo: nil)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        lastTouch = Date()
        let delta = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        azimuth -= Float(delta.x) * 0.008
        elevation = min(1.25, max(0.08, elevation + Float(delta.y) * 0.006))
        placeCamera()
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        lastTouch = Date()
        distance = min(maxDistance, max(minDistance, distance / Float(gesture.scale)))
        gesture.scale = 1
        placeCamera()
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        lastTouch = Date()
        guard let view else { return }
        var entity = view.entity(at: gesture.location(in: view))
        while let current = entity, !current.name.hasPrefix("tree-") { entity = current.parent }
        guard let name = entity?.name, let index = Int(name.dropFirst(5)) else {
            onSelect(nil)
            return
        }
        onSelect(trees.first { $0.index == index })
    }
}

/// Мягкие цвета сада.
enum GardenPalette {
    static let soil = UIColor(red: 0.55, green: 0.42, blue: 0.33, alpha: 1)
    static let tuft = UIColor(red: 0.52, green: 0.66, blue: 0.47, alpha: 1)
    static let stone = UIColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 1)
    static let petal = UIColor(red: 0.98, green: 0.82, blue: 0.86, alpha: 1)
    static let blossom = UIColor(red: 0.99, green: 0.93, blue: 0.90, alpha: 1)
    static let firefly = UIColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 1)

    static func grass(_ time: GardenDaytime) -> UIColor {
        time == .night ? UIColor(red: 0.34, green: 0.45, blue: 0.38, alpha: 1) : UIColor(red: 0.66, green: 0.77, blue: 0.60, alpha: 1)
    }

    static func sky(_ time: GardenDaytime) -> UIColor {
        switch time {
        case .dawn: return UIColor(red: 0.97, green: 0.86, blue: 0.80, alpha: 1)
        case .day: return UIColor(red: 0.84, green: 0.90, blue: 0.93, alpha: 1)
        case .evening: return UIColor(red: 0.95, green: 0.78, blue: 0.68, alpha: 1)
        case .night: return UIColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1)
        }
    }

    static func sunColor(_ time: GardenDaytime) -> UIColor {
        switch time {
        case .dawn: return UIColor(red: 1.0, green: 0.86, blue: 0.72, alpha: 1)
        case .day: return UIColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        case .evening: return UIColor(red: 1.0, green: 0.76, blue: 0.58, alpha: 1)
        case .night: return UIColor(red: 0.62, green: 0.70, blue: 0.95, alpha: 1)
        }
    }

    static func fillColor(_ time: GardenDaytime) -> UIColor {
        time == .night ? UIColor(red: 0.35, green: 0.40, blue: 0.62, alpha: 1) : UIColor(red: 0.80, green: 0.86, blue: 1.0, alpha: 1)
    }

    static func sunIntensity(_ time: GardenDaytime) -> Float {
        switch time {
        case .dawn, .evening: return 2600
        case .day: return 3400
        case .night: return 700
        }
    }

    static func matte(_ color: UIColor) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: .float(0.9), isMetallic: false)
    }
}

/// Строит дерево из простых мягких форм. Вид определяет силуэт и цвета, стадия — размер.
enum GardenTreeBuilder {
    static func scale(_ spec: GardenTreeSpec) -> Float { 0.25 + 0.75 * Float(min(max(spec.stage, 0), 7)) / 7 }

    static func trunkHeight(_ spec: GardenTreeSpec) -> Float {
        let tall: Float = spec.species == .palm ? 1.6 : (spec.species == .pine ? 1.2 : 1)
        return (0.35 + 1.5 * scale(spec)) * tall
    }

    static func make(_ spec: GardenTreeSpec) -> Entity {
        let tree = Entity()
        if spec.stage == 0 {
            // Семечко в земле.
            let mound = ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [GardenPalette.matte(GardenPalette.soil)])
            mound.scale = [1, 0.35, 1]
            tree.addChild(mound)
            let seed = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [GardenPalette.matte(trunkColor(spec.species))])
            seed.position.y = 0.06
            tree.addChild(seed)
            return tree
        }
        let s = scale(spec)
        let height = trunkHeight(spec)
        let radius = (spec.species == .palm ? 0.05 : 0.06) + 0.09 * s
        let trunk = ModelEntity(mesh: .generateCylinder(height: height, radius: radius),
                                materials: [GardenPalette.matte(trunkColor(spec.species))])
        trunk.position.y = height / 2
        tree.addChild(trunk)
        if spec.species == .birch {
            for i in 0..<Int(3 + 4 * s) {
                let mark = ModelEntity(mesh: .generateBox(size: [radius * 1.2, 0.02, radius * 0.5]),
                                       materials: [GardenPalette.matte(UIColor(white: 0.25, alpha: 1))])
                mark.position = [0, height * (0.15 + 0.12 * Float(i)), radius * 0.7]
                tree.addChild(mark)
            }
        }

        let crown = Entity()
        crown.name = "crown"
        crown.position.y = height
        tree.addChild(crown)
        let leaves = GardenPalette.matte(leafColor(spec))

        switch spec.species {
        case .pine:
            let tiers = 2 + min(spec.stage, 4)
            for i in 0..<tiers {
                let tierRadius = (0.85 - 0.14 * Float(i)) * s
                let cone = ModelEntity(mesh: .generateCone(height: 0.75 * s, radius: tierRadius), materials: [leaves])
                cone.position.y = -0.35 * s + Float(i) * 0.38 * s
                crown.addChild(cone)
            }
        case .palm:
            let fronds = 4 + spec.stage
            for i in 0..<fronds {
                let frond = ModelEntity(mesh: .generateBox(size: [1.1 * s, 0.025, 0.2 * s], cornerRadius: 0.01), materials: [leaves])
                let pivot = Entity()
                pivot.orientation = simd_quatf(angle: Float(i) / Float(fronds) * 2 * .pi, axis: [0, 1, 0])
                    * simd_quatf(angle: -0.45, axis: [0, 0, 1])
                frond.position.x = 0.5 * s
                pivot.addChild(frond)
                crown.addChild(pivot)
            }
        default:
            let blobs: [SIMD4<Float>] = [
                [0, 0.25, 0, 0.62], [-0.45, 0.02, 0.12, 0.46], [0.44, 0.06, -0.1, 0.5], [0.05, 0.62, 0.12, 0.44],
                [0, 0.05, 0.45, 0.42], [-0.12, 0.15, -0.46, 0.44], [0.32, 0.45, 0.3, 0.36],
            ]
            let count = min(blobs.count, 2 + spec.stage)
            for blob in blobs.prefix(count) {
                let sphere = ModelEntity(mesh: .generateSphere(radius: blob.w * s), materials: [leaves])
                sphere.position = SIMD3(blob.x, blob.y, blob.z) * s
                crown.addChild(sphere)
            }
        }

        // Цветы: неделя без провалов. Плоды: месяц без провалов.
        if spec.stage >= 3 && (spec.flowers || spec.species == .sakura) {
            addDots(to: crown, count: 14, radius: 0.04 * s + 0.02, color: spec.species == .sakura ? GardenPalette.petal : GardenPalette.blossom, s: s, seed: spec.index)
        }
        if spec.stage >= 4 && spec.fruits && spec.species != .pine {
            addDots(to: crown, count: 8, radius: 0.05 * s + 0.025, color: fruitColor(spec.species), s: s, seed: spec.index + 50)
        }
        return tree
    }

    private static func addDots(to crown: Entity, count: Int, radius: Float, color: UIColor, s: Float, seed: Int) {
        var random = SeededRandom(seed: UInt64(seed + 3))
        for _ in 0..<count {
            let theta = random.next() * 2 * .pi
            let phi = random.next() * .pi * 0.7
            let r = 0.62 * s
            let dot = ModelEntity(mesh: .generateSphere(radius: radius), materials: [GardenPalette.matte(color)])
            dot.position = [r * sin(phi) * cos(theta), 0.25 * s + r * cos(phi), r * sin(phi) * sin(theta)]
            crown.addChild(dot)
        }
    }

    static func trunkColor(_ species: TreeSpecies) -> UIColor {
        switch species {
        case .birch: return UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1)
        case .palm: return UIColor(red: 0.69, green: 0.55, blue: 0.40, alpha: 1)
        case .sakura: return UIColor(red: 0.43, green: 0.32, blue: 0.29, alpha: 1)
        default: return UIColor(red: 0.53, green: 0.41, blue: 0.31, alpha: 1)
        }
    }

    static func leafColor(_ spec: GardenTreeSpec) -> UIColor {
        let base: (CGFloat, CGFloat, CGFloat)
        switch spec.species {
        case .oak: base = (0.55, 0.69, 0.50)
        case .sakura: base = (0.95, 0.77, 0.81)
        case .pine: base = (0.37, 0.54, 0.43)
        case .birch: base = (0.71, 0.80, 0.55)
        case .maple: base = (0.90, 0.60, 0.40)
        case .palm: base = (0.50, 0.68, 0.43)
        }
        // Увядание от недавних провалов: листья желтеют.
        let t = CGFloat(min(max(spec.wilt, 0), 3)) / 3 * 0.7
        return UIColor(red: base.0 + (0.72 - base.0) * t, green: base.1 + (0.62 - base.1) * t, blue: base.2 + (0.38 - base.2) * t, alpha: 1)
    }

    static func fruitColor(_ species: TreeSpecies) -> UIColor {
        switch species {
        case .maple: return UIColor(red: 0.75, green: 0.35, blue: 0.25, alpha: 1)
        case .palm: return UIColor(red: 0.55, green: 0.40, blue: 0.25, alpha: 1)
        default: return UIColor(red: 0.88, green: 0.42, blue: 0.36, alpha: 1)
        }
    }
}

/// Предсказуемые «случайные» числа: трава и камни лежат на тех же местах при каждом открытии.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    /// Число от 0 до 1.
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000
    }
}
