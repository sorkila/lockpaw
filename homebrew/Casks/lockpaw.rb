cask "lockpaw" do
  version "1.0.6"
  sha256 "c8b073c04fe1c4e0f7b992ea2d50f5b1149d183cd9bdb11fb6ae4d486f9a8068"

  url "https://github.com/sorkila/lockpaw/releases/download/v#{version}/Lockpaw.dmg"
  name "Lockpaw"
  desc "Cover your Mac screen while AI agents keep running"
  homepage "https://getlockpaw.com"

  depends_on macos: ">= :sonoma"

  app "Lockpaw.app"

  zap trash: [
    "~/Library/Preferences/com.eriknielsen.lockpaw.plist",
  ]
end
