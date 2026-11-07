#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import SwiftCrossUI

    /// The search of a page. The field itself is the toolbar's `NSSearchToolbarItem` (see MacChrome);
    /// this marker sits in the page's header, keeps the room the field takes there, and asks the
    /// chrome to show the field while the page is on screen.
    struct SearchAnchor: NSViewRepresentable {
        var prompt: String
        @Binding var text: String

        func makeNSView(context: Context) -> AnchorView { AnchorView() }

        func updateNSView(_ view: AnchorView, context: Context) {
            view.prompt = prompt
            view.text = text
            view.onChange = { text = $0 }
            view.sync()
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnchorView, context: Context) -> ViewSize {
            ViewSize(240, 1)
        }

        final class AnchorView: NSView {
            var prompt = ""
            var text = ""
            var onChange: (String) -> Void = { _ in }

            override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }
            override func viewDidHide() { super.viewDidHide(); sync() }
            override func viewDidUnhide() { super.viewDidUnhide(); sync() }

            func sync() {
                // Not in the middle of a layout pass: the toolbar changes after it.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        let visible = self.window != nil && !self.isHiddenOrHasHiddenAncestor
                        MacChrome.shared.setSearch(owner: self, visible: visible, prompt: self.prompt, text: self.text, onChange: self.onChange)
                    }
                }
            }
        }
    }
#endif
