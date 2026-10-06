import SwiftUI

/// Дерево утра: растёт с подъёмами, вянет от провалов. Рисуется кодом, без картинок.
struct TreeView: View {
    let stage: Int
    let wilt: Int

    private var leafColor: Color {
        switch wilt {
        case 0: return Color(red: 0.30, green: 0.78, blue: 0.40)
        case 1: return Color(red: 0.55, green: 0.78, blue: 0.30)
        case 2: return Color(red: 0.75, green: 0.68, blue: 0.25)
        default: return Color(red: 0.62, green: 0.45, blue: 0.25)
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
            let trunkHeight = height * (0.16 + 0.46 * growth)
            let trunkWidth = max(3, width * (0.015 + 0.05 * growth))
            let top = CGPoint(x: base.x, y: base.y - trunkHeight)

            var trunk = Path()
            trunk.move(to: CGPoint(x: base.x - trunkWidth / 2, y: base.y))
            trunk.addLine(to: CGPoint(x: top.x - trunkWidth / 4, y: top.y))
            trunk.addLine(to: CGPoint(x: top.x + trunkWidth / 4, y: top.y))
            trunk.addLine(to: CGPoint(x: base.x + trunkWidth / 2, y: base.y))
            trunk.closeSubpath()
            context.fill(trunk, with: .color(Color(red: 0.45, green: 0.30, blue: 0.20)))

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
                    context.stroke(branch, with: .color(Color(red: 0.45, green: 0.30, blue: 0.20)),
                                   lineWidth: max(2, trunkWidth * 0.35))
                }
            }

            // Крона.
            let leaves = clamped == 1 ? 2 : 3 + clamped * 2
            let radius = width * (0.05 + 0.06 * growth)
            let spread = width * 0.22 * growth + radius
            for index in 0..<leaves {
                let angle = Double(index) / Double(leaves) * 2 * .pi
                let distance = index.isMultiple(of: 3) ? 0.45 : 0.85
                let center = CGPoint(
                    x: top.x + CGFloat(cos(angle) * distance) * spread,
                    y: top.y + CGFloat(sin(angle) * distance) * spread * 0.6 - radius * 0.3
                )
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(leafColor.opacity(0.9)))
            }
        }
        .accessibilityLabel("Дерево утра, стадия \(stage + 1) из 8")
    }
}
