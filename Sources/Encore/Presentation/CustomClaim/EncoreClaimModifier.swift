// `.encoreClaim(_:)`: binds the app's own SwiftUI view to an ``EncoreClaim`` handle. Measures it with
// the trigger visibility probe (clipping and covers) and, by default, opens the sheet on a tap.

import SwiftUI

extension View {
    /// Counts this view's impressions for `claim` and, with `handlesTap`, opens the sheet when it is
    /// tapped and gives it the button trait. Pass `handlesTap: false` when the view has its own buttons.
    public func encoreClaim(_ claim: EncoreClaim, handlesTap: Bool = true) -> some View {
        modifier(EncoreClaimModifier(claim: claim, handlesTap: handlesTap))
    }
}

private struct EncoreClaimModifier: ViewModifier {
    let claim: EncoreClaim
    let handlesTap: Bool
    @State private var binding = UUID()
    /// The probe outlives a disappearance (a tab switch), so a reappearance binds it again.
    @State private var box = ProbeBox()

    func body(content: Content) -> some View {
        tappable(content)
            .background(
                GeometryReader { proxy in
                    // The frame is only a trigger: a move makes the probe measure again.
                    TriggerVisibilityProbe(
                        frame: proxy.frame(in: .global),
                        report: { [binding] fraction, _ in claim.probeReported(fraction, binding: binding) },
                        attach: { [binding, box] probe in
                            box.probe = probe
                            claim.attach(probe, binding: binding)
                        }
                    )
                }
            )
            .onAppear {
                guard let probe = box.probe else { return }
                claim.attach(probe, binding: binding)
                probe.setNeedsMeasure()
            }
            .onDisappear { claim.detach(binding: binding) }
    }

    @ViewBuilder
    private func tappable(_ content: Content) -> some View {
        if handlesTap {
            content
                .contentShape(Rectangle())
                .onTapGesture { Task { await claim.tap() } }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

@MainActor
private final class ProbeBox {
    weak var probe: TriggerVisibilityProbeView?
}
