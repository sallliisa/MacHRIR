//
//  LevelMeterView.swift
//  MacHRIR
//
//  Visual level meter for audio monitoring
//

import SwiftUI

struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .cornerRadius(4)

                // Level indicator
                Rectangle()
                    .fill(levelColor)
                    .frame(width: CGFloat(level) * geometry.size.width)
                    .cornerRadius(4)
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.9 {
            return .red
        } else if level > 0.7 {
            return .yellow
        } else {
            return .green
        }
    }
}
