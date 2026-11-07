cask "lockpaw" do
  version "1.7.2"
  sha256 "53dadab7b3eee4fa30f63733675552c708be45ab29d5339d1b5073663bd5fd5a"

  url "https://github.com/sorkila/lockpaw/releases/download/v#{version}/Lockpaw.dmg"
  name "Lockpaw"
  desc "Cover your Mac screen while AI agents keep running"
  homepage "https://getlockpaw.com"

  depends_on macos: :sonoma

  app "Lockpaw.app"

  uninstall launchctl: "com.eriknielsen.lockpaw.helper"

  zap trash: [
    "~/Library/Preferences/com.eriknielsen.lockpaw.plist",
  ]
end
