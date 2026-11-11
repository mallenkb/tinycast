import AppKit
import SwiftUI

struct SettingsBreadcrumbs: NSViewRepresentable {
    let titles: [String]
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        control.backgroundColor = .clear
        control.setAccessibilityLabel(String(localized: "Settings"))
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        control.unregisterDraggedTypes()
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.select = select
        guard control.pathItems.map(\.title) != titles else { return }
        control.pathItems = titles.map { title in
            let item = NSPathControlItem()
            item.title = title
            return item
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPathControl, context: Context) -> CGSize? {
        let font = nsView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = titles.reduce(CGFloat.zero) { width, title in
            width + (title as NSString).size(withAttributes: [.font: font]).width + Theme.Spacing.xxl
        }
        return CGSize(width: ceil(width), height: Theme.Size.settingsControlHeight)
    }

    @MainActor
    final class Coordinator: NSObject {
        var select: (Int) -> Void

        init(select: @escaping (Int) -> Void) { self.select = select }

        @objc func choose(_ control: NSPathControl) {
            guard let clicked = control.clickedPathItem,
                let index = control.pathItems.firstIndex(where: { $0 === clicked }) else { return }
            select(index)
        }
    }
}
