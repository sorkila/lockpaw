cask "lockpaw" do
  version "1.0.1"
  sha256 "eb51e84f92866be8ac1e212b12807c7205d7869c72a5ffd7c43ac16991f61f55"

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
