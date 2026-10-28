// Sources/Encore/Presentation/Offers/Components/VerificationPendingView.swift
//
// Shown during strict-mode verification polling.

import SwiftUI

@available(iOS 17.0, *)
struct VerificationPendingView: View {
    /// The presentation's snapshot. Verbatim, never a `LocalizedStringKey`: a bare
    /// literal is looked up in the HOST app's bundle, where "Retry" means something else.
    let strings: SDKStrings
    let isTimedOut: Bool
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if isTimedOut {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(verbatim: strings[.verificationSlowTitle])
                    .font(.title3.weight(.semibold))

                Text(verbatim: strings[.verificationSlowSubtitle])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        Text(verbatim: strings[.verificationRetry])
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: onCancel) {
                        Text(verbatim: strings[.verificationCancel])
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 8)

                Text(verbatim: strings[.verifyingTitle])
                    .font(.title3.weight(.semibold))

                Text(verbatim: strings[.verifyingSubtitle])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
