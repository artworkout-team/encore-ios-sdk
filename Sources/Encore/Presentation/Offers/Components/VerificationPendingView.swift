// Sources/Encore/Presentation/Offers/Components/VerificationPendingView.swift
//
// Shown during strict-mode verification polling.

import SwiftUI

@available(iOS 17.0, *)
struct VerificationPendingView: View {
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

                Text("Still verifying...")
                    .font(.title3.weight(.semibold))

                Text("Your completion is taking longer than expected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 8)

                Text("Verifying your completion...")
                    .font(.title3.weight(.semibold))

                Text("This usually takes a few seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
