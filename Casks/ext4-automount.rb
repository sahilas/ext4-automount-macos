cask "ext4-automount" do
  version "1.3.0"
  sha256 "793aa9d1a543b3a8ee2c6ab791689b74be302373127707ef370eac889b680b50"

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
