cask "raccoon" do
  version "0.1.0"
  sha256 "65cc7264d463f17a5e7faa40bc8f4dd94593107021579fedbab876166bd75982"

  url "https://github.com/asyncwhale/raccoon/releases/download/v#{version}/Raccoon-#{version}.dmg"

  name "Raccoon"
  desc "Local memory layer for terminal AI users (archive/clean/search/feed) — zero-network"
  homepage "https://github.com/asyncwhale/raccoon"

  depends_on macos: ">= :sonoma"

  app "Raccoon.app"

  zap trash: [
    "~/Library/Application Support/Raccoon",
    "~/Library/Preferences/dev.raccoon.Raccoon.plist",
  ]
end
