cask "ext4-automount" do
  version "1.2.0"
  sha256 "1edd07dfc1d1cd635fac996483f9d5bd62931ec2e986288f5b5c1b795cc33397"

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
