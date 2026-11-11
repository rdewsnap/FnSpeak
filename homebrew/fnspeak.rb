# Template for the future rdewsnap/homebrew-fnspeak tap (Casks/fnspeak.rb).
# After each release, set `version` and `sha256` to the dmg's
# sha256 from the release job summary (or the SHA256SUMS release asset).
cask "fnspeak" do
  version "0.2.0"
  sha256 "e07b4056c7366a0366bc9853b780291339baf691afa1b9a77638aef467f9f52d"

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
