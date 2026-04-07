cask "anplezy" do
  version "1.31.3"
  sha256 "d57abe37df0f821bad3d9688f20ad858d01a5d23a582b4244fa9541ef49face1"

  url "https://github.com/edde746/plezy/releases/download/#{version}/anplezy-macos.dmg"
  name "Anplezy"
  desc "Modern Plex client built with Flutter"
  homepage "https://github.com/edde746/plezy"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "Anplezy.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Plezy.app"],
                   sudo: false
  end

  uninstall quit: "com.edde746.anplezy"

  zap trash: [
    "~/Library/Application Support/com.edde746.anplezy",
    "~/Library/Caches/com.edde746.anplezy",
    "~/Library/HTTPStorages/com.edde746.anplezy",
    "~/Library/Preferences/com.edde746.anplezy.plist",
    "~/Library/Saved Application State/com.edde746.anplezy.savedState",
    "~/Library/WebKit/com.edde746.anplezy",
  ]
end
