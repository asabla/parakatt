# Parakatt icons

Alt B — refined soft geometry. 44×44 pt (@1x), designed for macOS Retina (renders at 88×88 px).

## Structure

```
dark/          — for dark menu bar / dark mode
  idle.svg
  transcribing.svg
  recording.svg
  processing.svg

light/         — for light menu bar / light mode
  idle.svg
  transcribing.svg
  recording.svg
  processing.svg

template/      — monochrome black, for NSImage template mode
  idle.svg     — macOS handles dark/light inversion automatically
```

## Colors

| State         | Dark          | Light     |
|---------------|---------------|-----------|
| Idle          | white 78%     | black 72% |
| Transcribing  | #ff453a       | #d70015   |
| Recording     | #30d158       | #1a8f38   |
| Processing    | #ff9f0a       | #b25000   |

## Xcode usage

**Idle state** — use `template/idle.svg` as an NSImage template:
```swift
let image = NSImage(named: "idle")!
image.isTemplate = true  // macOS handles dark/light automatically
```

**Active states** — use dark/light variants explicitly, or let the
asset catalog handle it by placing each pair in an imageset with
Appearances → Any, Dark configured.

## Animations (implement in SwiftUI/AppKit)

- **Transcribing**: animate mouth (the filled arc) scaleY 0.1 → 1.0,
  duration 0.9s, ease-in-out, repeating. Drive speed from mic input level.
- **Recording**: pulse the dot opacity 1.0 → 0.2, duration 1.15s, repeating.
- **Processing**: rotate the dashed arc circle 0° → 360°, duration 1.9s,
  linear, repeating.
