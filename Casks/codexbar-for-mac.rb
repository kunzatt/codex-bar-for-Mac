cask "codexbar-for-mac" do
  version "0.1.0"
  sha256 "5d2c8540cedf685ec1ce157475f016b7396485d7f5bfecc4d1f43e34d568d122"

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
