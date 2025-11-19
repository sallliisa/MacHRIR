//
//  BalanceControlView.swift
//  MacHRIR
//
//  Balance control for fine-tuning stereo output
//

import SwiftUI

struct BalanceControlView: View {
    @ObservedObject var hrirManager: HRIRManager
    @State private var balanceValue: Double = 0.0 // Will be set from auto-compensation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Balance:")
                    .frame(width: 120, alignment: .trailing)

                Text("L")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(value: $balanceValue, in: -1.0...1.0, step: 0.05)
                    .frame(width: 200)
                    .onChange(of: balanceValue) { oldValue, newValue in
                        hrirManager.setBalance(Float(newValue))
                    }

                Text("R")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Reset") {
                    balanceValue = 0.0
                    hrirManager.setBalance(0.0)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            HStack {
                Spacer()
                    .frame(width: 120)
                Text(String(format: "%.2f", balanceValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 200)
            }
        }
    }
}
