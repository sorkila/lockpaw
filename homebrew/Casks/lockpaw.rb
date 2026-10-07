cask "lockpaw" do
  version "1.6.0"
  sha256 "33f16f68e40544e52943c3cd25bed0c17b9871ff303840b53746e1655ee69632"

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
