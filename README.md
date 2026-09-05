# AirplayAtTheCrib

Your Roku is on the Wi-Fi. Your Mac just needs an introduction.

**A small Mac app that helps your Roku show up in Screen Mirroring.** No Terminal. No building anything. No router settings.

[![Download AirplayAtTheCrib for Mac](assets/download.svg)](https://git.harivan.sh/harivansh-afk/airplay-at-the-crib/releases/download/v0.1.0/AirplayAtTheCrib.zip)

**[Download for Mac →](https://git.harivan.sh/harivansh-afk/airplay-at-the-crib/releases/download/v0.1.0/AirplayAtTheCrib.zip)** · macOS 13 or later · Apple silicon and Intel

## Open it the first time

1. Download the ZIP above. Double-click it to unpack **AirplayAtTheCrib.app**.
2. Drag the app into **Applications**, then double-click it.
3. If your Mac blocks it, click **Done** or **OK**. Open **System Settings → Privacy & Security**, scroll to the security message about **AirplayAtTheCrib**, and click **Open Anyway**. Confirm **Open**. Your Mac may ask for your password or Touch ID.
4. If asked to find devices on your local network, choose **Allow**.

This first release is not notarized by Apple, so the one-time warning is expected. Only approve the copy you downloaded from this repository. You do **not** need to disable Gatekeeper, your firewall, or any other protection. [Apple’s instructions for opening an app](https://support.apple.com/en-us/102445).

## Put your Mac on the TV

1. Turn on the Roku. Connect your Mac to the **same Wi-Fi** as the TV.
2. Open **AirplayAtTheCrib** and click **Find TVs**. Give it a moment to search.
3. Choose **your** TV and click **Show in AirPlay**. Shared Wi-Fi may show your neighbors’ TVs too.
4. Click **Control Center** in the top-right of your Mac’s menu bar → **Screen Mirroring** → choose your TV.
5. If the TV shows a code, type it into the Mac’s prompt.

Keep the app running while you cast. You can close its window; the little AirPlay icon in your menu bar keeps it running. Open that icon’s menu to bring the window back or quit.

Next time, just open the app and choose your TV again. It does not add itself to your login items.

## Can’t find your TV?

- **Check permission:** System Settings → Privacy & Security → **Local Network** → turn on **AirplayAtTheCrib**, if it’s listed. Then click **Find TVs** again.
- **Enter its address:** on the Roku, open **Settings → Network → About** and find **IP address**. In the Mac app, click **Enter TV address…** and type that number.
- **Check AirPlay:** on the Roku, open **Settings → Apple AirPlay and HomeKit** and make sure AirPlay is on. Your Roku must support AirPlay.
- **Still unable to connect?** This app fixes discovery, not blocked connections. If the Wi-Fi prevents your Mac from talking to the TV, this app cannot get around that.

If you change Wi-Fi, the TV restarts, or its address changes, click **Find TVs** again. An address that worked yesterday may have changed.

## What does it actually do?

Some shared Wi-Fi networks let your Mac reach the TV but fail to deliver the TV’s “I’m available for AirPlay” announcement. This app asks the TV directly for that announcement and supplies a copy **only to your Mac**.

The Mac’s built-in AirPlay handles the picture, sound, and pairing. Nothing streams through a server. The app has no accounts, analytics, or cloud service. It does not record your screen, request Accessibility permission, change your router, or turn on AirPlay for someone else’s computer.

Each friend runs their own copy on their Mac. **This is not an iPhone, iPad, Windows, or Android app.** It does not make the TV discoverable on those devices.

## For people changing the code

Everyone else: use the download button. The ZIP already contains the executable `.app`; there is nothing to build or install with a package manager.

The app is native Swift/AppKit and uses macOS’s included `curl`, `dig`, and `dns-sd`. Source is in `Sources/main.swift`. With Apple’s command-line developer tools installed, run `bash build.sh` to produce a universal Mac app and `build/AirplayAtTheCrib.zip`.

Discovery checks existing neighbors and at most four observed /24 address ranges within the active local IPv4 subnet, with 24 concurrent requests and bounded timeouts. Manual entry handles devices outside that search. Only private IPv4 addresses are accepted. The app queries Roku’s read-only device information and the TV’s real unicast mDNS response; it preserves the AirPlay TXT fields and uses `dns-sd -lo -P` for a local-only registration. It rechecks the selected device identity and announcement every minute, stops advertising unreachable devices, and removes its registration when quit normally.

The first release is an early utility, not a guarantee that every shared network or Roku model will work. Making a receiver appear and completing video mirroring are separate steps.
