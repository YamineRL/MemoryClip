cask "memoryclip" do
  version "0.2.5642"
  sha256 "4f1a251bb4050e03ce0997024bcefd0961e6c833511c32a2071052ff2ff37157"

  url "https://github.com/YamineRL/MemoryClip/releases/download/v#{version}/MemoryClip-#{version}.zip"
  name "MemoryClip"
  desc "Local-first menu-bar clipboard manager that reads your screenshots"
  homepage "https://github.com/YamineRL/MemoryClip"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app is built for macOS 26 (Tahoe) on Apple silicon, and uses on-device
  # models that exist nowhere else — so refuse the install rather than land a
  # bundle that cannot launch.
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "MemoryClip.app"

  # MemoryClip is ad-hoc signed: no Developer ID, no notarisation. Homebrew
  # quarantines every download, and Gatekeeper refuses to open a quarantined
  # bundle it cannot attribute to a developer — on macOS 15 and later not even
  # right-click → Open gets past it. Stripping the flag here is what makes
  # `brew install` actually install something you can run; it is the same
  # `xattr -dr` the release notes ask you to type by hand.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MemoryClip.app"]
  end

  uninstall quit: "app.memoryclip"

  # The clip history, the preferences, and the caches macOS keeps for a
  # menu-bar agent. Nothing else is ever written outside the notes folder you
  # chose yourself, which is yours and is left alone.
  zap trash: [
    "~/Library/Application Support/app.memoryclip",
    "~/Library/Caches/app.memoryclip",
    "~/Library/Preferences/app.memoryclip.plist",
    "~/Library/Saved Application State/app.memoryclip.savedState",
  ]

  caveats do
    <<~EOS
      MemoryClip is a menu-bar agent with no Dock icon: look for the clipboard
      glyph in the menu bar, or press ⇧⌘V.

      It is ad-hoc signed rather than notarised, so this cask removes the
      quarantine flag after installing. If macOS still refuses the first
      launch, run:

        xattr -dr com.apple.quarantine #{appdir}/MemoryClip.app
    EOS
  end
end
