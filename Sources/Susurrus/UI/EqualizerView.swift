import SwiftUI

struct EqualizerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var eq = model.player.equalizer
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("On", isOn: $eq.isEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Menu(eq.currentPreset?.name ?? "Custom") {
                    ForEach(Equalizer.presets) { preset in
                        Button(preset.name) { eq.apply(preset) }
                    }
                }
                .frame(width: 160)
            }

            HStack(alignment: .bottom, spacing: 6) {
                BandSlider(label: "Preamp", value: $eq.preamp)
                Divider().frame(height: 170)
                ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                    BandSlider(label: Self.label(Equalizer.frequencies[band]), value: $eq.gains[band])
                }
            }
            .disabled(!eq.isEnabled)
            .opacity(eq.isEnabled ? 1 : 0.5)

            HStack {
                Text("+12 dB … −12 dB").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    eq.gains = Array(repeating: 0, count: Equalizer.frequencies.count)
                    eq.preamp = 0
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private static func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// A vertical dB slider. SwiftUI has no vertical Slider on macOS, so a horizontal one is rotated.
private struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(spacing: 6) {
            Text(value == 0 ? "0" : String(format: "%+.0f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: $value, in: Equalizer.gainRange)
                .accessibilityLabel("\(label) hertz")
                .accessibilityValue(String(format: "%+.0f decibels", value))
                .frame(width: 140)
                .rotationEffect(.degrees(-90))
                .frame(width: 34, height: 140)
                .onTapGesture(count: 2) { value = 0 }
            Text(label).font(.caption2)
        }
    }
}
