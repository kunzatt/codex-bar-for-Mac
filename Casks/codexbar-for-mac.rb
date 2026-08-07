cask "codexbar-for-mac" do
  version "0.1.1"
  sha256 "566f27b5f84da8ebd92ced87c03fdec9e43bef0e0ac9d4c09c0d17cd48771768"

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
