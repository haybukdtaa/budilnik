import SwiftUI

/// Дерево утра: растёт с подъёмами, вянет от провалов, цветёт и плодоносит от серии.
/// Рисуется кодом, без картинок; у каждого вида своя крона и свой цвет.
struct TreeView: View {
    let stage: Int
    let wilt: Int
    var species: TreeSpecies = .oak
    var flowers = false
    var fruits = false

    private var trunkColor: Color {
        species == .birch ? Color(red: 0.92, green: 0.90, blue: 0.86) : Color(red: 0.45, green: 0.30, blue: 0.20)
    }

    /// Цвет листвы по виду; при увядании смешивается с жёлто-коричневым.
    private var leafColor: Color {
        let base: (Double, Double, Double)
        switch species {
        case .oak: base = (0.30, 0.70, 0.35)
        case .sakura: base = (0.98, 0.70, 0.80)
        case .pine: base = (0.13, 0.48, 0.30)
        case .birch: base = (0.62, 0.82, 0.35)
        case .maple: base = (0.95, 0.45, 0.20)
        case .palm: base = (0.35, 0.75, 0.30)
        }
        let dry = (0.62, 0.48, 0.25)
        let t = Double(min(max(wilt, 0), 3)) / 3 * 0.8
        return Color(
            red: base.0 + (dry.0 - base.0) * t,
            green: base.1 + (dry.1 - base.1) * t,
            blue: base.2 + (dry.2 - base.2) * t
        )
    }

    private var flowerColor: Color {
        species == .sakura ? .white : Color(red: 1.0, green: 0.75, blue: 0.85)
    }

    private var fruitColor: Color {
        switch species {
        case .pine: return Color(red: 0.55, green: 0.35, blue: 0.20) // шишки
        case .palm: return Color(red: 0.55, green: 0.40, blue: 0.25) // кокосы
        case .oak: return Color(red: 0.60, green: 0.45, blue: 0.20)  // жёлуди
        default: return Color(red: 0.90, green: 0.20, blue: 0.20)
        }
    }

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let ground = CGRect(x: width * 0.2, y: height * 0.86, width: width * 0.6, height: height * 0.08)
            context.fill(Path(ellipseIn: ground), with: .color(Color(red: 0.36, green: 0.25, blue: 0.18)))

            let clamped = min(max(stage, 0), 7)
            let base = CGPoint(x: width / 2, y: height * 0.88)

            if clamped == 0 {
                let seed = CGRect(x: base.x - 7, y: base.y - 9, width: 14, height: 10)
                context.fill(Path(ellipseIn: seed), with: .color(Color(red: 0.55, green: 0.38, blue: 0.22)))
                return
            }

            let growth = Double(clamped) / 7
            let tallness = species == .palm || species == .pine ? 1.15 : 1.0
            let trunkHeight = height * (0.16 + 0.46 * growth) * tallness
            let trunkWidth = max(3, width * (0.015 + 0.05 * growth) * (species == .palm ? 0.7 : 1))
            let top = CGPoint(x: base.x, y: base.y - trunkHeight)

            var trunk = Path()
            trunk.move(to: CGPoint(x: base.x - trunkWidth / 2, y: base.y))
            trunk.addLine(to: CGPoint(x: top.x - trunkWidth / 4, y: top.y))
            trunk.addLine(to: CGPoint(x: top.x + trunkWidth / 4, y: top.y))
            trunk.addLine(to: CGPoint(x: base.x + trunkWidth / 2, y: base.y))
            trunk.closeSubpath()
            context.fill(trunk, with: .color(trunkColor))

            if species == .birch && clamped >= 2 {
                // Тёмные отметины на белом стволе.
                for index in 0..<4 {
                    let y = base.y - trunkHeight * (0.2 + 0.18 * Double(index))
                    let mark = CGRect(x: base.x - trunkWidth * 0.3, y: y, width: trunkWidth * 0.5, height: 2)
                    context.fill(Path(mark), with: .color(.black.opacity(0.7)))
                }
            }

            var spots: [CGPoint] = []
            let radius = width * (0.05 + 0.06 * growth)

            switch species {
            case .pine:
                // Ярусы-треугольники.
                let tiers = max(1, min(clamped, 5))
                for tier in 0..<tiers {
                    let tierWidth = width * (0.10 + 0.07 * growth) * (1 + Double(tiers - tier) * 0.35)
                    let tierTop = top.y + Double(tier) * trunkHeight * 0.16 - radius
                    var triangle = Path()
                    triangle.move(to: CGPoint(x: top.x, y: tierTop))
                    triangle.addLine(to: CGPoint(x: top.x - tierWidth, y: tierTop + radius * 2.2))
                    triangle.addLine(to: CGPoint(x: top.x + tierWidth, y: tierTop + radius * 2.2))
                    triangle.closeSubpath()
                    context.fill(triangle, with: .color(leafColor))
                    spots.append(CGPoint(x: top.x - tierWidth * 0.5, y: tierTop + radius * 1.8))
                    spots.append(CGPoint(x: top.x + tierWidth * 0.5, y: tierTop + radius * 1.8))
                }
            case .palm:
                // Широкие листья веером.
                let fronds = 3 + clamped
                for index in 0..<fronds {
                    let angle = Double.pi + Double(index) / Double(max(fronds - 1, 1)) * Double.pi
                    let length = width * (0.12 + 0.18 * growth)
                    let end = CGPoint(x: top.x + CGFloat(cos(angle)) * length, y: top.y + CGFloat(sin(angle)) * length * 0.55 + length * 0.25)
                    var frond = Path()
                    frond.move(to: top)
                    frond.addQuadCurve(to: end, control: CGPoint(x: (top.x + end.x) / 2, y: top.y - length * 0.25))
                    context.stroke(frond, with: .color(leafColor), lineWidth: max(3, radius * 0.5))
                    spots.append(CGPoint(x: top.x + (end.x - top.x) * 0.25, y: top.y + radius * 0.4))
                }
            default:
                // Ветви появляются с третьей стадии.
                if clamped >= 3 {
                    for index in 0..<min(clamped - 1, 5) {
                        let along = 0.45 + 0.1 * Double(index)
                        let start = CGPoint(x: base.x, y: base.y - trunkHeight * along)
                        let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                        let end = CGPoint(x: start.x + side * width * 0.16 * growth, y: start.y - height * 0.08)
                        var branch = Path()
                        branch.move(to: start)
                        branch.addLine(to: end)
                        context.stroke(branch, with: .color(trunkColor), lineWidth: max(2, trunkWidth * 0.35))
                    }
                }
                let leaves = clamped == 1 ? 2 : 3 + clamped * 2
                let spread = width * 0.22 * growth + radius
                let leafRadius = species == .birch ? radius * 0.8 : radius
                for index in 0..<leaves {
                    let angle = Double(index) / Double(leaves) * 2 * .pi
                    let distance = index.isMultiple(of: 3) ? 0.45 : 0.85
                    let center = CGPoint(
                        x: top.x + CGFloat(cos(angle) * distance) * spread,
                        y: top.y + CGFloat(sin(angle) * distance) * spread * 0.6 - radius * 0.3
                    )
                    let rect = CGRect(x: center.x - leafRadius, y: center.y - leafRadius, width: leafRadius * 2, height: leafRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(leafColor.opacity(0.92)))
                    spots.append(center)
                }
            }

            // Цветы и плоды — по точкам кроны.
            let dot = max(2.5, radius * 0.28)
            if flowers {
                for (index, point) in spots.enumerated() where index.isMultiple(of: 2) {
                    let rect = CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(flowerColor))
                }
            }
            if fruits {
                for (index, point) in spots.enumerated() where !index.isMultiple(of: 2) {
                    let rect = CGRect(x: point.x - dot * 1.2, y: point.y + dot, width: dot * 2.4, height: dot * 2.4)
                    context.fill(Path(ellipseIn: rect), with: .color(fruitColor))
                }
            }
        }
        .accessibilityLabel("\(species.title), стадия \(stage + 1) из 8" + (flowers ? ", цветёт" : "") + (fruits ? ", с плодами" : ""))
    }
}
