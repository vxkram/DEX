import SwiftUI

/// A large, HDR-aware preview of the open image.
struct PreviewPane: View {
    let document: ImageDocument
    let isDropTargeted: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let preview = document.preview {
                Image(decorative: preview.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .allowedDynamicRange(preview.isHDR ? .high : .standard)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    .padding(28)
                    .overlay(alignment: .topLeading) {
                        if preview.isHDR {
                            Label("HDR", systemImage: "sun.max.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassEffect()
                                .padding(36)
                                .help("This photo has an HDR gain map. On HDR displays, its highlights are brighter than white.")
                        }
                    }
            } else if let error = document.loadError {
                ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().controlSize(.large)
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.dexAccent, lineWidth: 3)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }
}
