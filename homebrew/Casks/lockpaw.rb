cask "lockpaw" do
  version "1.2.0"
  sha256 "0d8993fd3b1421aadcfd7299cf9cf33d7f7d8718affe076e83417cbed0d1cf51"

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
