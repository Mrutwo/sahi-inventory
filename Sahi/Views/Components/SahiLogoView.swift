import SwiftUI
import UIKit

/// The organization's logo. Add the official artwork to Assets.xcassets as
/// the image set "SahiLogo" and it is used everywhere automatically; until
/// then a brand-colored shield placeholder (echoing the shield in the logo)
/// is drawn.
struct SahiLogoView: View {
    var size: CGFloat = 56

    var body: some View {
        Group {
            if UIImage(named: "SahiLogo") != nil {
                Image("SahiLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: size)
            } else {
                ShieldBadge(size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("סח״י – סיירת חסד ייחודית"))
    }
}

private struct ShieldBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ShieldShape()
                .fill(Brand.blue)
            ShieldShape()
                .stroke(Color.white.opacity(0.9), lineWidth: max(1.5, size * 0.035))
                .padding(size * 0.07)
            VStack(spacing: size * 0.02) {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Brand.gold)
                Text(verbatim: "סח״י")
                    .font(.system(size: size * 0.26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .offset(y: -size * 0.04)
        }
        .frame(width: size * 0.86, height: size)
    }
}

/// Shield outline: straight top, sides that curve into a point at the bottom.
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let corner = w * 0.12
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.52))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX - w * 0.04, y: rect.minY + h * 0.86))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.52), control: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.86))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        SahiLogoView(size: 44)
        SahiLogoView(size: 96)
    }
    .padding()
}
