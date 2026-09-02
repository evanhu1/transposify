import AppKit

/// AppKit-level onboarding audit. This complements the pure state matrix by
/// checking the actual views, constraints, accessibility labels and Done
/// action in both system appearances.
enum OnboardingUITest {
    static func run(spotify: SpotifyState) -> Never {
        var passed = 0
        var failed = 0

        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                print("PASS  \(name)")
                passed += 1
            } else {
                print("FAIL  \(name)")
                failed += 1
            }
        }

        func descendants(of root: NSView) -> [NSView] {
            root.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        func isActuallyVisible(_ view: NSView, upTo root: NSView) -> Bool {
            var candidate: NSView? = view
            while let current = candidate {
                if current.isHidden { return false }
                if current === root { return true }
                candidate = current.superview
            }
            return false
        }

        print("\n===== Transposify onboarding UI test =====")
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua), ("dark", .darkAqua),
        ]

        for (appearanceName, appearance) in appearances {
            for scenario in SetupScenario.allCases {
                var completion: Bool?
                let controller = SetupWindowController(
                    spotify: spotify, fixedState: scenario.input
                ) { completion = $0 }
                guard let window = controller.window,
                      let content = window.contentView else {
                    check(false, "\(appearanceName) \(scenario.rawValue) creates a window")
                    continue
                }
                window.appearance = NSAppearance(named: appearance)
                controller.present()
                content.layoutSubtreeIfNeeded()

                let views = [content] + descendants(of: content)
                let visible = views.filter { isActuallyVisible($0, upTo: content) }
                let buttons = visible.compactMap { $0 as? NSButton }
                let output = SetupFlow.render(scenario.input)
                let expectedTitles = [
                    output.spotify.button,
                    output.audio.button,
                    output.control.button,
                    output.primaryButton,
                ].compactMap { $0 }.sorted()
                let actualTitles = buttons.map(\.title).filter { !$0.isEmpty }.sorted()

                let tag = "\(appearanceName) \(scenario.rawValue)"
                check(actualTitles == expectedTitles, "\(tag) exposes the expected actions")
                check(buttons.allSatisfy {
                    guard !$0.title.isEmpty else { return true }
                    return !($0.accessibilityLabel() ?? "").isEmpty
                }, "\(tag) labels every action for accessibility")
                check(visible.allSatisfy { view in
                    guard view !== content else { return true }
                    let frame = view.superview?.convert(view.frame, to: content) ?? .zero
                    return frame.width >= 0 && frame.height >= 0
                        && frame.minX >= -0.5 && frame.maxX <= content.bounds.maxX + 0.5
                        && frame.minY >= -0.5 && frame.maxY <= content.bounds.maxY + 0.5
                }, "\(tag) keeps visible content inside the window")
                let ambiguous = views.filter(\.hasAmbiguousLayout)
                if !ambiguous.isEmpty {
                    let kinds = ambiguous.map { view -> String in
                        if let button = view as? NSButton { return "NSButton[\(button.title)]" }
                        if let label = view as? NSTextField {
                            return "NSTextField[\(label.stringValue)]"
                        }
                        return String(describing: type(of: view))
                    }
                    print("      ambiguous: \(kinds.joined(separator: ", "))")
                }
                check(ambiguous.isEmpty, "\(tag) has unambiguous constraints")

                let primary = buttons.first { $0.title == output.primaryButton }
                check(primary?.isEnabled == output.primaryEnabled,
                      "\(tag) has the correct completion affordance")
                if output.primaryEnabled {
                    primary?.performClick(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    check(completion == true, "\(tag) Done completes and closes setup")
                } else {
                    primary?.performClick(nil)
                    check(completion == nil, "\(tag) cannot complete while disabled")
                    window.close()
                    check(completion == false, "\(tag) close preserves incomplete setup")
                }
            }
        }

        print("============================================")
        print("\(passed)/\(passed + failed) passed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
