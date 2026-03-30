cask "lockpaw" do
  version "1.0.4"
  sha256 "ebea07575cc561d2d057624bd2d2694053d2375d67f649d84634bc1a96b3a5f5"

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
