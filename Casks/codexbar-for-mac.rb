cask "codexbar-for-mac" do
  version "0.1.2"
  sha256 "e1e8b14f3db8b0cf79d8940f6fc4e60ec14cc55da94405e5db13f6022c011c9c"

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
