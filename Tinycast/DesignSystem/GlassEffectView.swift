import SwiftUI

struct GlassEffectView: NSViewRepresentable {
    var cornerRadius: CGFloat?
    var tint: Color?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        if let cornerRadius { view.cornerRadius = cornerRadius }
        view.tintColor = tint.flatMap { NSColor(cgColor: $0.resolve(in: context.environment).cgColor) }
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        if let cornerRadius { nsView.cornerRadius = cornerRadius }
        nsView.tintColor = tint.flatMap { NSColor(cgColor: $0.resolve(in: context.environment).cgColor) }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSGlassEffectView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}
