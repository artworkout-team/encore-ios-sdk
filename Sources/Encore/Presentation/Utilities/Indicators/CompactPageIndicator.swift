//
//  CompactPageIndicator.swift
//  Encore
//
//  A compact page indicator that shows a fixed number of dots.
//  Edge dots appear smaller to hint at additional pages beyond the visible window.
//

import SwiftUI

@available(iOS 17.0, *)
struct CompactPageIndicator: View {
    let totalPages: Int
    let currentPage: Int
    var maxVisible: Int = 5
    var dotSize: CGFloat = 8 
    var diminishedScale: CGFloat = 0.5
    var spacing: CGFloat = 8 
    var activeColor: Color = Color(hex: "#5671FF")
    var inactiveColor: Color = Color(UIColor.tertiaryLabel)
    
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(visibleIndices, id: \.self) { index in
                let isActive = index == currentPage
                let size = isEdgeDot(index) ? dotSize * diminishedScale : dotSize
                Capsule()
                    .fill(isActive ? activeColor : inactiveColor)
                    .frame(width: isActive ? dotSize * 2.2 : size, height: size)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
    }
    
    // MARK: - Sliding Window
    
    /// Computes the visible range of indices, centered on `currentPage`.
    private var visibleIndices: Range<Int> {
        guard totalPages > maxVisible else { return 0..<totalPages }
        
        let half = maxVisible / 2
        let start = min(max(currentPage - half, 0), totalPages - maxVisible)
        let end = start + maxVisible
        return start..<end
    }
    
    // MARK: - Edge Detection
    
    /// Returns `true` when the dot sits at the edge of the window
    /// and there are more pages beyond it in that direction.
    private func isEdgeDot(_ index: Int) -> Bool {
        let range = visibleIndices
        let isLeading = index == range.lowerBound && range.lowerBound > 0
        let isTrailing = index == range.upperBound - 1 && range.upperBound < totalPages
        return isLeading || isTrailing
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, *)
#Preview("Compact Page Indicator") {
    VStack(spacing: 30) {
        // Few pages — all full size
        CompactPageIndicator(totalPages: 3, currentPage: 1)
        
        // Many pages — edge dots diminished
        CompactPageIndicator(totalPages: 10, currentPage: 0)
        CompactPageIndicator(totalPages: 10, currentPage: 4)
        CompactPageIndicator(totalPages: 10, currentPage: 9)
    }
    .padding()
}
#endif
