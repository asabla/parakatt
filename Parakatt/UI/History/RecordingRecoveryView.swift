import SwiftUI
import ParakattCore

struct RecordingRecoveryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State var drafts: [RecordingDraft]
    @State private var busyID: String?
    @State private var error: String?
    @State private var discardID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording recovery").font(.title2.weight(.semibold))
            Text("Save available text, or transcribe retained audio again. Recovery does not paste into other apps.")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(drafts, id: \.id) { draft in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft.createdAt).font(.headline)
                            Text("\(draft.chunkCount) sections · \(draft.failedChunks) unfinished")
                                .foregroundStyle(.secondary)
                            Text(draft.recognizedText.isEmpty ? "No recognized text is available yet." : draft.recognizedText)
                                .lineLimit(3)
                            HStack {
                                Button("Save recognized text") { run(draft.id) { try $0.recoverRecording(id: draft.id, audio: false) } }
                                    .disabled(draft.recognizedText.isEmpty)
                                Button("Recover from audio") { run(draft.id) { try $0.recoverRecording(id: draft.id, audio: true) } }
                                    .disabled(!draft.audioAvailable || !appState.isModelLoaded)
                                Spacer()
                                Button("Discard", role: .destructive) { discardID = draft.id }
                                if busyID == draft.id { ProgressView().controlSize(.small) }
                            }.disabled(busyID != nil)
                            if !draft.audioAvailable {
                                Text("Audio recovery was disabled or the temporary audio has expired.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                if let busyID { Button("Cancel recovery") { appState.cancelRecordingRecovery(id: busyID) } }
                Spacer()
                Button("Done") { dismiss() }.disabled(busyID != nil)
            }
        }
        .padding(20).frame(width: 680, height: 480)
        .interactiveDismissDisabled(busyID != nil)
        .alert("Discard this recovery record?", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } })) {
            Button("Cancel", role: .cancel) { discardID = nil }
            Button("Discard", role: .destructive) {
                if let id = discardID { run(id) { try $0.discardRecordingDraft(id: id) } }
                discardID = nil
            }
        } message: { Text("The recovery text and retained audio will be removed. Existing history entries remain.") }
    }
    private func run(_ id: String, work: @escaping (CoreBridge) throws -> Void) {
        busyID = id
        error = nil
        appState.changeHistory(work) { failure in
            error = failure
            busyID = nil
            appState.queryRecovery { drafts = $0 }
        }
    }
}
