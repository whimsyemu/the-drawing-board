# The Drawing Board

A gentle, private thinking space for people who overthink. Dump the swirl, get lightly prompted, and let it quietly organise itself. Everything stays on your device.

Live at **https://whimsyemu.com**

This site is a single self-contained page (`index.html`) plus a small offline shell (`sw.js`, `manifest.webmanifest`, icons) so it can be installed to a phone's home screen. Nothing you write is ever sent anywhere.

## iOS app

`ios/` holds a small native wrapper (a full-screen web view around the same `index.html`). The **TestFlight** GitHub Action archives it on a macOS runner and uploads it to App Store Connect whenever `index.html` or `ios/` changes on `main`, or when run by hand from the Actions tab.
