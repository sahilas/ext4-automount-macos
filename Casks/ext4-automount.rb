cask "ext4-automount" do
  version "1.2.1"
  sha256 "e5671e3a62e4a6971a0f5cb8c40a62b9ccc65f3a04ce0374b6bac818d9c1aab0"

  url "https://github.com/sahilas/ext4-automount-macos/releases/download/v#{version}/Ext4-Automount-#{version}.pkg"
  name "Ext4 Automount"
  desc "Mount ext4 drives read-write automatically when plugged in"
  homepage "https://github.com/sahilas/ext4-automount-macos"

  depends_on formula: "nohajc/anylinuxfs/anylinuxfs"

  pkg "Ext4-Automount-#{version}.pkg"

  uninstall script: {
    executable: "/Applications/Ext4 Automount.app/Contents/Resources/uninstall.sh",
    sudo:       true,
  }
end
