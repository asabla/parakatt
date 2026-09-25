import SwiftUI
import ParakattCore

/// Live transcript window shown while a meeting recording is in progress.
/// Binds to AppState for elapsed time, segments, audio health, and paused
/// state. Auto-scrolls to the bottom as new chunks arrive.
@available(macOS 14.2, *)
struct LiveMeetingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View { LiveMeetingContent(appState: appState, meeting: appState.meeting) }
}

@available(macOS 14.2, *)
private struct LiveMeetingContent: View {
    let appState: AppState
    @ObservedObject var meeting: MeetingCoordinator
    @State private var showTimeline = false
    @State private var followsBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            Picker("Text", selection: $showTimeline) {
                Text("Processed text").tag(false)
                Text("Recognized timeline").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
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
                .fill(meeting.isMeetingPaused ? .orange : .red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.isMeetingPaused ? "Paused" : "Recording")
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
        let total = Int(meeting.meetingElapsedTime)
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
        let (label, color, icon) = audioStatusChip(meeting.meetingAudioStatus)
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
            if meeting.meetingSegments.isEmpty && (meeting.meetingTranscription ?? "").isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if showTimeline {
                                    ForEach(meeting.meetingSegments.indices, id: \.self) { index in
                                        segmentRow(meeting.meetingSegments[index], isLatest: isLatestChunk(meeting.meetingSegments[index]))
                                            .id(index)
                                    }
                                } else {
                                    Text(meeting.meetingTranscription ?? "")
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Color.clear.frame(height: 1).id("transcript-end")
                            }
                            .background(GeometryReader { geometry in Color.clear.preference(key: TranscriptBottomKey.self, value: TranscriptScrollPosition(height: geometry.size.height, bottom: geometry.frame(in: .named("transcriptScroll")).maxY)) })
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .coordinateSpace(name: "transcriptScroll")
                        .background(GeometryReader { viewport in
                            Color.clear.onAppear { viewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
                        })
                        .onPreferenceChange(TranscriptBottomKey.self) { position in
                            // Content growth is not a user scroll. Keep the previous follow choice.
                            if abs(position.height - contentHeight) < 0.5 { followsBottom = position.bottom <= viewportHeight + 40 }
                            contentHeight = position.height
                        }
                        .onChange(of: meeting.meetingTranscription) { _, _ in
                            if !showTimeline && followsBottom { proxy.scrollTo("transcript-end", anchor: .bottom) }
                        }
                        .onChange(of: meeting.meetingSegments.count) { _, newCount in
                            if newCount > 0 && followsBottom {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("transcript-end", anchor: .bottom)
                                }
                            }
                        }
                    }
                    nextChunkIndicator
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Small footer strip shown above the action buttons once text is
    /// flowing. Gives the user continuous feedback between chunks so the
    /// UI never sits idle — mic level bars + a progress bar ticking toward
    /// the next batch arrival.
    private var nextChunkIndicator: some View {
        let elapsed = meeting.meetingElapsedTime
        let first = appState.meetingFirstChunkSecs
        let interval = appState.meetingChunkIntervalSecs
        let sinceLast: Double
        if elapsed < first {
            sinceLast = elapsed
        } else {
            sinceLast = fmod(elapsed - first, interval)
        }
        let target = elapsed < first ? first : interval
        let fraction = target > 0 ? min(sinceLast / target, 1) : 0
        let remaining = max(0, Int(target - sinceLast))

        return HStack(spacing: 10) {
            MeetingAudioLevelBars(level: meeting.meetingMicLevel, tint: .accentColor)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text("next in \(remaining)s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func isLatestChunk(_ segment: TimestampedSegment) -> Bool {
        guard let latestStart = meeting.meetingLatestChunkStartSecs else { return false }
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
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Parakeet transcribes in ~30s batches. You'll see text here shortly.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            // Live mic level so the user has immediate feedback that audio
            // is being captured even before the first chunk transcribes.
            MeetingAudioLevelBars(level: meeting.meetingMicLevel, tint: .accentColor)

            // Progress bar ticking toward the first chunk dispatch.
            firstChunkProgressBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var firstChunkProgressBar: some View {
        let target = appState.meetingFirstChunkSecs
        let elapsed = min(meeting.meetingElapsedTime, target)
        let fraction = target > 0 ? elapsed / target : 0
        let remaining = max(0, Int(target - elapsed))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("First batch")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(remaining > 0 ? "\(remaining)s until first text" : "Transcribing now…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
        .frame(maxWidth: 360)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 10) {
            if meeting.isMeetingPaused {
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

/// Five-bar equaliser driven by a 0…1 level. Visually analogous to the
/// RecordingOverlay's bars but tuned for the larger live-meeting window.
@available(macOS 14.2, *)
private struct MeetingAudioLevelBars: View {
    let level: Float
    let tint: Color
    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 4
    private let multipliers: [Float] = [0.4, 0.75, 1.0, 0.75, 0.4]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let barLevel = CGFloat(level * multipliers[i])
                let height = minHeight + (maxHeight - minHeight) * barLevel
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(tint)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight)
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.1),
            value: level
        )
    }
}

private struct TranscriptScrollPosition: Equatable {
    var height: CGFloat = 0
    var bottom: CGFloat = 0
}
private struct TranscriptBottomKey: PreferenceKey {
    static var defaultValue = TranscriptScrollPosition()
    static func reduce(value: inout TranscriptScrollPosition, nextValue: () -> TranscriptScrollPosition) { value = nextValue() }
}
