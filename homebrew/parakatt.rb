cask "parakatt" do
  version "0.7.3"
  sha256 "e12391aeed6493c286812250e7c12305ae3dad5778f60758e102fb55323b3a11"

  url "https://github.com/asabla/parakatt/releases/download/v#{version}/Parakatt-#{version}-arm64.dmg"
  name "Parakatt"
  desc "Voice-to-text transcription for macOS menu bar"
  homepage "https://github.com/asabla/parakatt"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Parakatt.app"

  caveats <<~EOS
    Open Parakatt from Applications. Allow Microphone when recording and enable
    Accessibility in Parakatt Settings if you want automatic paste.
  EOS

  zap trash: [
    "~/Library/Application Support/Parakatt",
    "~/Library/Preferences/com.parakatt.app.plist",
  ]
end
