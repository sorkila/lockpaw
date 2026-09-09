cask "lockpaw" do
  version "1.4.0"
  sha256 "d9fb0a599b8be9cfab8ab5d9c9be6f23aac6bcc205fa2dcac5c0f5e2a38d109a"

  url "https://github.com/sorkila/lockpaw/releases/download/v#{version}/Lockpaw.dmg"
  name "Lockpaw"
  desc "Cover your Mac screen while AI agents keep running"
  homepage "https://getlockpaw.com"

  depends_on macos: :sonoma

  app "Lockpaw.app"

  zap trash: [
    "~/Library/Preferences/com.eriknielsen.lockpaw.plist",
  ]
end
