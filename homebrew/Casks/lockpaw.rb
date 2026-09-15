cask "lockpaw" do
  version "1.5.0"
  sha256 "d882247f985f09f231552056340b15189ce3fccd6f45069e5ea963f2aa365a1f"

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
