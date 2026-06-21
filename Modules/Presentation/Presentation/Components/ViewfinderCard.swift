import SwiftUI

/// The live preview card (legacy chrome). Gestures + device bezel land in a later parity pass.
struct ViewfinderCard: View {
    let preview: PreviewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if preview.image != nil {
                Text("\(preview.fps, format: .number.precision(.fractionLength(0))) fps")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: .capsule)
                    .padding(10)
            }
        }
    }
}
