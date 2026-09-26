import SwiftUI
import UniformTypeIdentifiers
import ParakattCore

struct MediaImportView: View {
    @ObservedObject var service: MediaImportService
    @State private var link = ""
    @State private var mode = "dictation"
    @State private var confirmDiscard: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import video").font(.title2)
            Text("Choose a video file or enter a direct media link or public YouTube link. Speech recognition runs on this Mac.").foregroundStyle(.secondary)
            HStack {
                Button("Choose Videos…", action: chooseFiles)
                Picker("Text processing", selection: $mode) {
                    Text("Dictation (original speech)").tag("dictation")
                    Text("Clean (configured LLM)").tag("clean")
                }.frame(maxWidth: 330)
            }
            HStack {
                TextField("Video link", text: $link).textFieldStyle(.roundedBorder).onSubmit(addLink)
                Button("Import Link", action: addLink).disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Local files stay in place. Downloaded videos use the best available quality and remain until you remove them. Clean mode uses your configured text provider.").font(.caption).foregroundStyle(.secondary)
            Divider()
            if service.jobs.isEmpty { Text("Drop MP4, MOV, MKV, or WebM files here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(service.jobs, id: \.id) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(job.title).font(.headline).lineLimit(1); Spacer(); Text(job.state.capitalized).foregroundStyle(.secondary) }
                        if service.activeID == job.id {
                            if job.state == "transcribing", job.attachment.durationSecs > 0 { ProgressView(value: min(1, job.processedUntil / job.attachment.durationSecs)) }
                            else if let value = service.transferProgress, job.state == "downloading" { ProgressView(value: min(1, value)) }
                            else { ProgressView().controlSize(.small) }
                        }
                        if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(job.state == "failed" ? .red : .secondary) }
                        HStack {
                            if ["queued", "downloading", "preparing", "transcribing"].contains(job.state) { Button("Pause") { service.pause(job.id) } }
                            else if job.state != "completed" { Button("Resume") { service.resume(job.id) }.disabled(service.activeID == job.id || job.checkpointVersion != 1) }
                            Button("Locate File…") { service.locate(job.id) }.disabled(service.activeID == job.id)
                            if job.kind != "file" { Button("Remove Downloaded Media") { service.removeMedia(job.id) }.disabled(service.activeID == job.id) }
                            Spacer()
                            Button("Delete…", role: .destructive) { confirmDiscard = job.id }
                        }.controlSize(.small)
                    }.padding(.vertical, 4)
                }
            }
            Text("Transcripts appear in History while processing. Database backups contain transcript text, not the video files.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 680, minHeight: 430)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            let selectedMode = mode
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in service.addFile(url, mode: selectedMode) } } }
            }
            return !providers.isEmpty
        }
        .sheet(item: $service.trackChoice) { choice in
            VStack(alignment: .leading, spacing: 16) {
                Text("Select the audio track").font(.title2)
                ForEach(choice.tracks) { track in Button(track.label + (track.isDefault ? " (default)" : "")) { service.chooseTrack(track.id) } }
                Button("Cancel") { service.pause(choice.id) }
            }.padding(24).frame(minWidth: 360).interactiveDismissDisabled()
        }
        .alert("Import error", isPresented: Binding(get: { service.error != nil }, set: { if !$0 { service.error = nil } })) {
            Button("OK") { service.error = nil }
        } message: { Text(service.error ?? "") }
        .alert("Delete import and transcript?", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } })) {
            Button("Delete", role: .destructive) { if let id = confirmDiscard { service.discard(id) }; confirmDiscard = nil }
            Button("Cancel", role: .cancel) { confirmDiscard = nil }
        } message: { Text("This removes the transcript and app-owned media. External source files remain unchanged.") }
    }
    private func addLink() { service.addLink(link, mode: mode); if service.error == nil { link = "" } }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mp4", "mov", "mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { for url in panel.urls { service.addFile(url, mode: mode) } }
    }
}
