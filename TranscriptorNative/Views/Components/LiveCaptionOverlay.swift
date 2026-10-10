import SwiftUI

/// #11 — Cápsula del overlay de subtítulos.
/// Muestra el texto en streaming con retardo (whisper.cpp no tiene
/// streaming de baja latencia) y un punto rojo pulsante mientras
/// la transcripción está activa. Sin botón de cierre en v1.
struct LiveCaptionView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel

    var body: some View {
        VStack {
            Spacer()
            if viewModel.liveCaptionVisible, !viewModel.liveCaptionText.isEmpty {
                HStack(spacing: 10) {
                    if viewModel.isTranscribing {
                        LiveCaptionDot()
                            .accessibilityHidden(true)
                    }

                    Text(viewModel.liveCaptionText)
                        .font(.title3.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: 680)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.08).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(viewModel.liveCaptionText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.25), value: viewModel.liveCaptionVisible)
        .animation(.snappy(duration: 0.25), value: viewModel.liveCaptionText)
        .environment(\.colorScheme, .dark)
    }
}

/// Punto rojo pulsante (patrón del panel de grabación, versión local
/// para no depender del modificador privado de RecordingFloatingPanel).
private struct LiveCaptionDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
