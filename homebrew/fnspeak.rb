# Template for the future rdewsnap/homebrew-fnspeak tap (Casks/fnspeak.rb).
# After each release, set `version` and replace :no_check with the dmg's
# sha256 from the release job summary (or the SHA256SUMS release asset).
cask "fnspeak" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/rdewsnap/FnSpeak/releases/download/v#{version}/FnSpeak-#{version}.dmg"
  name "FnSpeak"
  desc "Local-first voice dictation that cleans up what you said"
  homepage "https://github.com/rdewsnap/FnSpeak"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "FnSpeak.app"

  zap trash: [
    "~/Library/Application Support/FnSpeak",
  ]
end
