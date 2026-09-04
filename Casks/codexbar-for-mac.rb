cask "codexbar-for-mac" do
  version "0.1.4"
  sha256 "b35b0a9f13cd3924cd6482561180c97cbb6911612db82fad59df190472afdf01"

  url "https://github.com/kunzatt/codex-bar-for-Mac/releases/download/v#{version}/CodexBar-#{version}-arm64.zip"
  name "CodexBar"
  desc "Menu bar usage monitor for Codex accounts"
  homepage "https://github.com/kunzatt/codex-bar-for-Mac"

  depends_on macos: :sonoma
  depends_on arch: :arm64
  conflicts_with cask: "codexbar"

  app "CodexBar.app"

  zap trash: "~/Library/Application Support/CodexBar"
end
