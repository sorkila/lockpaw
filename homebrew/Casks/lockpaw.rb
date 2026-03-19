cask "lockpaw" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/sorkila/lockpaw/releases/download/v#{version}/Lockpaw.dmg"
  name "Lockpaw"
  desc "Menu bar screen guard for macOS"
  homepage "https://getlockpaw.com"

  depends_on macos: ">= :sonoma"

  app "Lockpaw.app"

  zap trash: [
    "~/Library/Preferences/com.eriknielsen.lockpaw.plist",
  ]
end
