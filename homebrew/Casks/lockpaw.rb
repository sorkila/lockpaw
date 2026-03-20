cask "lockpaw" do
  version "1.0.2"
  sha256 "d573e8a32af561119bb16c8b1787cc6a49d46d0956920874db3490499bc91ce9"

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
