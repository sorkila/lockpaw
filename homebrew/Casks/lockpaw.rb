cask "lockpaw" do
  version "1.3.1"
  sha256 "c30f15bacff6e117e01dcdd866fa97e8b08f68cbaf3122cc0ee274cbf64e0d53"

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
