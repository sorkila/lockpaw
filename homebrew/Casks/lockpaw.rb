cask "lockpaw" do
  version "1.0.2"
  sha256 "605fb3c1ca35bf791a24ccb32c1ddbe88afebc311c7b64ca5ad959a0ae23d005"

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
