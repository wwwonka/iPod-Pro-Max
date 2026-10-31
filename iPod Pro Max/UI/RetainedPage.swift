@_spi(Backends) import SwiftCrossUI

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
        return children.node!.computeLayout(with: view, proposedSize: proposedSize, environment: environment)
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
        if children.active { _ = children.node?.commit() }
        backend.setSize(of: widget, to: layout.size.vector)
    }
    @MainActor private final class Children<Child: View>: ViewGraphNodeChildren {
        var node: AnyViewGraphNode<Child>?
        var active = false
        var attached = false
        var widgets: [AnyWidget] { active ? [node?.widget].compactMap { $0 } : [] }
        var erasedNodes: [ErasedViewGraphNode] {
            guard active, let node else { return [] }
            return [ErasedViewGraphNode(wrapping: node)]
        }
    }
}
