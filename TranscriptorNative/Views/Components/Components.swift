import SwiftUI

// MARK: - Atomic Design Boundaries
// Atoms: componentes indivisibles (iconos, botones, badges)
// Molecules: combinación pequeña de átomos con una tarea concreta
// Organisms: bloques complejos de interfaz (drawers, overlays, paneles)
// Templates: composición de organismos para una escena/pantalla

// MARK: - Organisms (Feedback)
struct ToastOverlay: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    
    var body: some View {
        VStack {
            Spacer()
            
            ForEach(viewModel.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .padding(.bottom, 24)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.toasts.count)
    }
}

// MARK: - Molecules (Feedback)
struct ToastView: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let toast: Toast
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon with background
            ZStack {
                Circle()
                    .fill(toast.type.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Image(systemName: toast.type.icon)
                    .font(.titleDefault)
                    .foregroundColor(toast.type.color)
            }
            
            Text(localizedToastMessage)
                .font(.labelLarge)
                .foregroundColor(.textPrimary)
            
            Spacer(minLength: 0)
            
            // Undo / action button
            if let action = toast.action {
                Button {
                    action.handler()
                } label: {
                    Text(action.label)
                        .font(.labelMedium)
                        .foregroundColor(.accentPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.accentPrimary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.bgSecondary)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(toast.type.color.opacity(0.25), lineWidth: 1)
        )
    }

    private var localizedToastMessage: String {
        let isSpanish = localizationManager.appLanguage == .es
        let message = toast.message

        if isSpanish {
            if message == "Could not open transcription" { return "No se pudo abrir la transcripción" }
            if message == "Job failed" { return "El trabajo falló" }
            if message == "File does not exist" { return "El archivo no existe" }
            if message == "File loaded successfully" { return "Archivo cargado correctamente" }
            if message == "Added to queue" { return "Añadido a la cola" }
            if message == "Transcription completed" { return "Transcripción completada" }
            if message == "Transcription cancelled" { return "Transcripción cancelada" }
            if message == "Text copied to clipboard" { return "Texto copiado al portapapeles" }
            if message == "Text updated" { return "Texto actualizado" }
            if message == "No timed segments to export as SRT" { return "No hay segmentos con tiempo para exportar a SRT" }
            if message == "No timed segments to export as VTT" { return "No hay segmentos con tiempo para exportar a VTT" }
            if message == "File saved" { return "Archivo guardado" }
            if message.hasSuffix("files added to queue"),
               let count = Int(message.split(separator: " ").first ?? "") {
                return "\(count) archivos añadidos a la cola"
            }
            if message.hasPrefix("Error loading file: ") {
                let detail = String(message.dropFirst("Error loading file: ".count))
                return "Error al cargar el archivo: \(detail)"
            }
            if message.hasPrefix("Error saving: ") {
                let detail = String(message.dropFirst("Error saving: ".count))
                return "Error al guardar: \(detail)"
            }
            if message.hasPrefix("Error: ") {
                let detail = String(message.dropFirst("Error: ".count))
                return "Error: \(detail)"
            }
            return message
        }

        if message == "No se pudo abrir la transcripción" { return "Could not open transcription" }
        if message == "El trabajo falló" { return "Job failed" }
        if message == "El archivo no existe" { return "File does not exist" }
        if message == "Archivo cargado correctamente" { return "File loaded successfully" }
        if message == "Añadido a la cola" { return "Added to queue" }
        if message == "Transcripción completada" { return "Transcription completed" }
        if message == "Transcripción cancelada" { return "Transcription cancelled" }
        if message == "Texto copiado al portapapeles" { return "Text copied to clipboard" }
        if message == "Texto actualizado" { return "Text updated" }
        if message == "No hay segmentos con tiempo para exportar a SRT" { return "No timed segments to export as SRT" }
        if message == "No hay segmentos con tiempo para exportar a VTT" { return "No timed segments to export as VTT" }
        if message == "Archivo guardado" { return "File saved" }
        if message.hasSuffix("archivos añadidos a la cola"),
           let count = Int(message.split(separator: " ").first ?? "") {
            return "\(count) files added to queue"
        }
        if message.hasPrefix("Error al cargar el archivo: ") {
            let detail = String(message.dropFirst("Error al cargar el archivo: ".count))
            return "Error loading file: \(detail)"
        }
        if message.hasPrefix("Error al guardar: ") {
            let detail = String(message.dropFirst("Error al guardar: ".count))
            return "Error saving: \(detail)"
        }
        if message.hasPrefix("Error: ") {
            let detail = String(message.dropFirst("Error: ".count))
            return "Error: \(detail)"
        }
        return message
    }
}

// MARK: - Atoms (Reusable Primitive Controls)
private struct DrawerCloseButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.labelBody)
                .foregroundColor(.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.bgHover)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cerrar panel")
    }
}

// MARK: - Organisms (Drawers)
struct LibraryDrawerView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Binding var isPresented: Bool
    @Environment(\.responsiveMetrics) private var metrics
    
    @State private var searchText = ""
    @State private var hoveredId: UUID?
    
    var filteredTranscriptions: [Transcription] {
        if searchText.isEmpty {
            return viewModel.transcriptions
        }
        return viewModel.transcriptions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            drawerHeader
            
            Divider()
                .background(Color.borderSubtle)
            
            // Content
            if viewModel.transcriptions.isEmpty {
                emptyState
            } else {
                transcriptionList
            }
        }
        .frame(width: metrics.drawerWidth)
        .background(
            Color.bgSecondary
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: -10, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
    
    private var drawerHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Historial", systemImage: "clock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                DrawerCloseButton {
                    withAnimation(.snappy(duration: 0.2)) {
                        isPresented = false
                    }
                }
            }
            
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.bodyMedium)
                    .foregroundColor(.textMuted)
                
                TextField("Buscar transcripciones...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.bodyMedium)
                            .foregroundColor(.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.bgTertiary)
            )
        }
        .padding(16)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(.textMuted)
            
            VStack(spacing: 4) {
                Text("Sin transcripciones")
                    .font(.titleMedium)
                    .foregroundColor(.textSecondary)
                
                Text("Las transcripciones aparecerán aquí")
                    .font(.bodyMedium)
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    
    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredTranscriptions) { transcription in
                    transcriptionRow(transcription)
                }
            }
            .padding(12)
        }
    }
    
    private func transcriptionRow(_ transcription: Transcription) -> some View {
        Button {
            viewModel.selectTranscription(transcription)
            withAnimation(.snappy(duration: 0.2)) {
                isPresented = false
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: transcription.isFavorite ? "star.fill" : "doc.text")
                        .font(.bodyDefault)
                        .foregroundColor(transcription.isFavorite ? .yellow : .accentPrimary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcription.title)
                        .font(.labelDefault)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Label(transcription.formattedDuration, systemImage: "clock")
                        Text("•")
                        Text(transcription.formattedDate)
                    }
                    .font(.caption)
                    .foregroundColor(.textMuted)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.labelBody)
                    .foregroundColor(.textMuted)
                    .opacity(hoveredId == transcription.id ? 1 : 0.5)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hoveredId == transcription.id ? Color.bgHover.opacity(0.8) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.toggleFavorite(transcription)
            } label: {
                if transcription.isFavorite {
                    Label(
                        localizationManager.appLanguage == .es ? "Quitar de favoritos" : "Remove favorite",
                        systemImage: "star.slash"
                    )
                } else {
                    Label(
                        localizationManager.appLanguage == .es ? "Añadir a favoritos" : "Add favorite",
                        systemImage: "star"
                    )
                }
            }
            
            Divider()
            
            Button(role: .destructive) {
                viewModel.deleteTranscription(transcription)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredId = isHovered ? transcription.id : nil
            }
        }
    }
}

// MARK: - Organisms (Drawers)
struct FavoritesDrawerView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @Binding var isPresented: Bool
    @Environment(\.responsiveMetrics) private var metrics
    
    @State private var hoveredId: UUID?
    
    var favoriteTranscriptions: [Transcription] {
        viewModel.transcriptions.filter { $0.isFavorite }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Favoritos", systemImage: "star.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                DrawerCloseButton {
                    withAnimation(.snappy(duration: 0.2)) {
                        isPresented = false
                    }
                }
            }
            .padding(16)
            
            Divider()
                .background(Color.borderSubtle)
            
            // Content
            if favoriteTranscriptions.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    
                    Image(systemName: "star")
                        .font(.system(size: 40))
                        .foregroundColor(.textMuted)
                    
                    VStack(spacing: 4) {
                        Text("Sin favoritos")
                            .font(.titleMedium)
                            .foregroundColor(.textSecondary)
                        
                        Text("Marca transcripciones como favoritas para verlas aquí")
                            .font(.bodyMedium)
                            .foregroundColor(.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(favoriteTranscriptions) { transcription in
                            favoriteRow(transcription)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: metrics.drawerWidth)
        .background(
            Color.bgSecondary
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: -10, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
    
    private func favoriteRow(_ transcription: Transcription) -> some View {
        Button {
            viewModel.selectTranscription(transcription)
            withAnimation(.snappy(duration: 0.2)) {
                isPresented = false
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "star.fill")
                        .font(.bodyDefault)
                        .foregroundColor(.yellow)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcription.title)
                        .font(.labelDefault)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Label(transcription.formattedDuration, systemImage: "clock")
                        Text("•")
                        Text(transcription.formattedDate)
                    }
                    .font(.caption)
                    .foregroundColor(.textMuted)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.labelBody)
                    .foregroundColor(.textMuted)
                    .opacity(hoveredId == transcription.id ? 1 : 0.5)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hoveredId == transcription.id ? Color.bgHover.opacity(0.8) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.toggleFavorite(transcription)
            } label: {
                Label("Quitar de favoritos", systemImage: "star.slash")
            }
            
            Divider()
            
            Button(role: .destructive) {
                viewModel.deleteTranscription(transcription)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredId = isHovered ? transcription.id : nil
            }
        }
    }
}

#if DEBUG
struct ToastOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ToastOverlay()
            .environmentObject(TranscriptionViewModel())
            .frame(width: 400, height: 200)
            .background(Color.bgPrimary)
    }
}
#endif
