cask "codexbar-for-mac" do
  version "0.1.5"
  sha256 "3b791875fae54d34c1df50976ce343e9d30876fd671e6b369b457aa0f4c23162"

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
