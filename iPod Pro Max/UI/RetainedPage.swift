@_spi(Backends) import SwiftCrossUI
#if canImport(AppKitBackend)
import AppKit
#endif

/// Builds a page on its first visit, then retains its native widgets and local state.
/// Inactive pages are detached, have no hit-test surface and do no layout work.
/// The cache is owned by this view graph, so unplugging a device releases its page.
struct RetainedPage<Content: View>: View {
    var active: Bool
    @ViewBuilder var content: () -> Content
    var body = EmptyView()

    func children<Backend: BaseAppBackend>(backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?, environment: EnvironmentValues) -> any ViewGraphNodeChildren {
        Children<Content>()
    }
    func asWidget<Backend: BaseAppBackend>(_ children: any ViewGraphNodeChildren, backend: Backend) -> Backend.Widget {
        backend.createContainer()
    }
    func computeLayout<Backend: BaseAppBackend>(_ widget: Backend.Widget,
        children: any ViewGraphNodeChildren, proposedSize: ProposedViewSize,
        environment: EnvironmentValues, backend: Backend) -> ViewLayoutResult {
        let children = children as! Children<Content>
        children.active = active
        guard active else {
            return ViewLayoutResult(size: .zero, childResults: [], participateInStackLayoutsWhenEmpty: false)
        }
        let view = content()
        if children.node == nil {
            children.node = AnyViewGraphNode(for: view, backend: backend, environment: environment)
        }
        #if canImport(AppKitBackend)
        if MacChrome.shared.isSliding, var cached = children.lastLayout {
            children.frozen = true
            cached.size = ViewSize(proposedSize.width ?? cached.size.width, proposedSize.height ?? cached.size.height)
            return cached
        }
        #endif
        children.frozen = false
        let result = children.node!.computeLayout(with: view, proposedSize: proposedSize, environment: environment)
        children.lastLayout = result
        return result
    }
    func commit<Backend: BaseAppBackend>(_ widget: Backend.Widget,
        children: any ViewGraphNodeChildren, layout: ViewLayoutResult,
        environment: EnvironmentValues, backend: Backend) {
        let children = children as! Children<Content>
        if children.attached != children.active {
            backend.removeAllChildren(of: widget)
            if children.active, let node = children.node {
                backend.insert(node.widget.into(), into: widget, at: 0)
                backend.setPosition(ofChildAt: 0, in: widget, to: .zero)
            }
            children.attached = children.active
        }
        if children.active {
            if !children.frozen { _ = children.node?.commit() }
            // The device page's content column is centered and capped at 760 points. Move the
            // retained widget by the change in that centering inset while its layout is frozen.
            // The final layout resets the widget to the origin at the actual viewport width.
            let offset: Double
            if children.frozen, let original = children.lastLayout?.size.width {
                offset = (max(0, layout.size.width - 760) - max(0, original - 760)) / 2
            } else {
                offset = 0
            }
            #if canImport(AppKitBackend)
            // Moving the retained page can expose the container behind its old viewport.
            // Cover the inactive track table with the same color as the page background.
            if let view = widget as? NSView {
                view.wantsLayer = true
                view.layer?.backgroundColor = devicePageBackgroundColor.cgColor
            }
            #endif
            backend.setPosition(ofChildAt: 0, in: widget, to: SIMD2(Int(offset.rounded()), 0))
        }
        backend.setSize(of: widget, to: layout.size.vector)
    }
    @MainActor private final class Children<Child: View>: ViewGraphNodeChildren {
        var node: AnyViewGraphNode<Child>?
        var active = false
        var attached = false
        var frozen = false
        var lastLayout: ViewLayoutResult?
        var widgets: [AnyWidget] { active ? [node?.widget].compactMap { $0 } : [] }
        var erasedNodes: [ErasedViewGraphNode] {
            guard active, let node else { return [] }
            return [ErasedViewGraphNode(wrapping: node)]
        }
    }
}
