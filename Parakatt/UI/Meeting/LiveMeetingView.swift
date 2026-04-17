import SwiftUI
import ParakattCore

/// Live transcript window shown while a meeting recording is in progress.
/// Binds to AppState for elapsed time, segments, audio health, and paused
/// state. Auto-scrolls to the bottom as new chunks arrive.
@available(macOS 14.2, *)
struct LiveMeetingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            timelineSection
            Divider()
            footerSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Recording dot — reuses the pulsing style from RecordingOverlay.
            Circle()
                .fill(appState.isMeetingPaused ? .orange : .red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isMeetingPaused ? "Paused" : "Recording")
                    .font(.system(.title3, weight: .semibold))
                Text("\(elapsedText) · \(appState.activeMode) mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            audioStatusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var elapsedText: String {
        let total = Int(appState.meetingElapsedTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var audioStatusBadge: some View {
        let (label, color, icon) = audioStatusChip(appState.meetingAudioStatus)
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func audioStatusChip(_ status: MeetingAudioStatus) -> (String, Color, String) {
        switch status {
        case .unknown:
            return ("Listening…", .secondary, "waveform")
        case .healthy:
            return ("Mic + system OK", .green, "waveform.badge.mic")
        case .systemSilent:
            return ("Mic only", .orange, "person.wave.2")
        case .bothSilent:
            return ("No audio detected", .orange, "mic.slash")
        case .systemEmpty:
            return ("System audio empty", .red, "exclamationmark.triangle")
        case .permissionDenied:
            return ("Permission needed", .red, "lock.fill")
        case .error:
            return ("Capture error", .red, "exclamationmark.octagon")
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        Group {
            if appState.meetingSegments.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(appState.meetingSegments.enumerated()), id: \.offset) { idx, segment in
                                segmentRow(segment, isLatest: isLatestChunk(segment))
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: appState.meetingSegments.count) { _, newCount in
                        if newCount > 0 {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isLatestChunk(_ segment: TimestampedSegment) -> Bool {
        guard let latestStart = appState.meetingLatestChunkStartSecs else { return false }
        return segment.startSecs >= latestStart
    }

    private func segmentRow(_ segment: TimestampedSegment, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatTimestamp(segment.startSecs))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(segment.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(isLatest ? Color.primary : Color.primary.opacity(0.8))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isLatest ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func formatTimestamp(_ secs: Double) -> String {
        let total = Int(secs)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Listening…")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("The first batch of transcribed text arrives after about 30 seconds of audio. Later chunks land every 28s.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 10) {
            if appState.isMeetingPaused {
                Button {
                    appState.resumeMeeting()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    appState.pauseMeeting()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }

            Button {
                appState.stopMeeting()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Spacer()

            Button(role: .destructive) {
                appState.cancelMeeting()
            } label: {
                Label("Discard", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
