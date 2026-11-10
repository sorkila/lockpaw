cask "lockpaw" do
  version "1.7.3"
  sha256 "53e725e2536bd109e8941733ec074d6f4b5489dbefb565311e7a8c18f47dcd76"

  url "https://github.com/sorkila/lockpaw/releases/download/v#{version}/Lockpaw.dmg"
  name "Lockpaw"
  desc "Cover the screen while AI agents keep running"
  homepage "https://getlockpaw.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Lockpaw.app"

  uninstall launchctl: "com.eriknielsen.lockpaw.helper",
            quit:      "com.eriknielsen.lockpaw"

  zap trash: [
    "~/Library/Caches/com.eriknielsen.lockpaw",
    "~/Library/HTTPStorages/com.eriknielsen.lockpaw",
    "~/Library/Preferences/com.eriknielsen.lockpaw.plist",
  ]
end
