# AirplayAtTheCrib

Your Roku is on the Wi-Fi. Your Mac just needs an introduction.

**A small Mac app that helps your Roku show up in Screen Mirroring.** No Terminal. No building anything. No router settings.

[![Download AirplayAtTheCrib for Mac](assets/download.svg)](https://git.harivan.sh/harivansh-afk/airplay-at-the-crib/releases/download/v0.2.1/AirplayAtTheCrib.zip)

**[Download for Mac →](https://git.harivan.sh/harivansh-afk/airplay-at-the-crib/releases/download/v0.2.1/AirplayAtTheCrib.zip)** · macOS 13 or later · Apple silicon and Intel

## Open it the first time

1. Download the ZIP above. Double-click it to unpack **AirplayAtTheCrib.app**.
2. Drag the app into **Applications**, then double-click it.
3. If your Mac asks whether to open an app downloaded from the internet, click **Open**.
4. If asked to find devices on your local network, choose **Allow**.

**Version 0.2.1 is signed with Developer ID and notarized by Apple.** No “Open Anyway” workaround is required. If you downloaded an older version and see “Apple could not verify,” move that old copy to the Trash and download the current ZIP above. You do **not** need to disable Gatekeeper, your firewall, or any other protection.

## Put your Mac on the TV

1. Turn on the Roku. Connect your Mac to the **same Wi-Fi** as the TV.
2. Open **AirplayAtTheCrib**. TVs appear automatically—there’s no search button and no need to wait for the whole search to finish.
3. Choose **your** TV and click **Use this TV**. Shared Wi-Fi may show your neighbors’ TVs too.
4. Click **Control Center** in the top-right of your Mac’s menu bar → **Screen Mirroring** → choose your TV.
5. If the TV shows a code, type it into the Mac’s prompt.

Keep the app running while you cast. You can close its window; the little AirPlay icon in your menu bar keeps it running. Open that icon’s menu to bring the window back or quit.

Next time, just open the app. It remembers your TV and makes it available automatically when it finds it again. It verifies the TV’s identity, not just its address. It does not add itself to your login items.

## Can’t find your TV?

- **Check permission:** System Settings → Privacy & Security → **Local Network** → turn on **AirplayAtTheCrib**, if it’s listed. Reopen the app or let it retry automatically.
- **Enter its address:** on the Roku, open **Settings → Network → About** and find **IP address**. In the Mac app, click **TV missing?** and type that number.
- **Check AirPlay:** on the Roku, open **Settings → Apple AirPlay and HomeKit** and make sure AirPlay is on. Your Roku must support AirPlay.
- **Still unable to connect?** This app fixes discovery, not blocked connections. If the Wi-Fi prevents your Mac from talking to the TV, this app cannot get around that.

If you change Wi-Fi, the TV restarts, or its address changes, the app searches again automatically. You can close and reopen it to start fresh. The spinner stops after a bounded search, even if nothing responds; retries happen in the background.

## What does it actually do?

Some shared Wi-Fi networks let your Mac reach the TV but fail to deliver the TV’s “I’m available for AirPlay” announcement. This app asks the TV directly for that announcement and supplies a copy **only to your Mac**.

The Mac’s built-in AirPlay handles the picture, sound, and pairing. Nothing streams through a server. The app has no accounts, analytics, or cloud service. It does not record your screen, request Accessibility permission, change your router, or turn on AirPlay for someone else’s computer.

Each friend runs their own copy on their Mac. **This is not an iPhone, iPad, Windows, or Android app.** It does not make the TV discoverable on those devices.

## For people changing the code

Everyone else: use the download button. The ZIP already contains the executable `.app`; there is nothing to build or install with a package manager.

The app is native Swift/AppKit and uses macOS’s included `curl`, `dig`, and `dns-sd`. Source is in `Sources/main.swift`. With Apple’s command-line developer tools installed, run `bash build.sh` to produce a universal Mac app and `build/AirplayAtTheCrib.zip`.

Local builds are ad-hoc signed by default. For distribution, set `SIGNING_IDENTITY` to your Developer ID Application identity before running the build. Create an `.xcarchive` containing the app at `Products/Applications/AirplayAtTheCrib.app` and generate its metadata with `swift Packaging/archive.swift <archive-path>`. Submit with `xcodebuild -exportArchive -archivePath <archive-path> -exportOptionsPlist Packaging/ExportOptions.plist -allowProvisioningUpdates`. This uses the account signed into Xcode. After Apple finishes processing, use `xcodebuild -exportNotarizedApp -archivePath <archive-path> -exportPath <output-directory>`. Validate the exported app with `xcrun stapler validate` and `spctl --assess --type execute --verbose=4`, then ZIP **that exported app** for the release. The packaging configuration names Hari’s team; other maintainers must use their own team and signing identity.

Discovery checks existing neighbors and at most four observed /24 address ranges within the active local IPv4 subnet, with 24 concurrent requests and a 60-second search deadline. Results are selectable immediately; selecting a TV cancels queued probes. Generation IDs discard late results, and rows do not reorder while the user is choosing. Manual entry handles devices outside that search. Only private IPv4 addresses are accepted. The app queries Roku’s read-only device information and the TV’s real unicast mDNS response; it preserves the AirPlay TXT fields and uses `dns-sd -lo -P` for a local-only registration. “Ready” requires successful registration callbacks for both the service and hostname, with an eight-second timeout. It rechecks the selected device identity and announcement every 15 seconds, searches again when the TV disappears, and removes its registration when quit normally. It stores only the selected TV’s ID and last IP in local preferences.

The first release is an early utility, not a guarantee that every shared network or Roku model will work. Making a receiver appear and completing video mirroring are separate steps.
