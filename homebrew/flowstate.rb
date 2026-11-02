# Template for the future rdewsnap/homebrew-flowstate tap (Casks/flowstate.rb).
# After each release, set `version` and replace :no_check with the dmg's
# sha256 from the release job summary (or the SHA256SUMS release asset).
cask "flowstate" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/rdewsnap/Flowstate/releases/download/v#{version}/Flowstate-#{version}.dmg"
  name "Flowstate"
  desc "Local-first voice dictation that cleans up what you said"
  homepage "https://github.com/rdewsnap/Flowstate"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Flowstate.app"

  zap trash: [
    "~/Library/Application Support/Flowstate",
  ]
end
