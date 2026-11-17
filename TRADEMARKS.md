# Trademarks

The code in this repo is under the [MPL-2.0](LICENSE). The MPL-2.0 covers the code only. It does not give you any right to the name "Wishbone" or to the app icon.

"Wishbone" and the app icon are not registered trademarks. This file states how the maintainer asks them to be used, so that other builds of the app are not mistaken for this project.

## What this covers

- The name "Wishbone", as the name under the icon on the Home Screen, and as the start of the App Store name, "Wishbone: Family Wish Lists".
- The app icon: the artwork in the app's icon file, and every image made from it, in each appearance (light, dark, tinted, and clear).

The app icon artwork is © John Clayton, all rights reserved. It is not under the MPL-2.0. Pull requests that change the app icon are not taken.

## Builds you give to other people

These rules apply to any build of the app that you give to other people: through TestFlight, through the App Store, or shared with anyone in another way. If you do that with a fork:

- Don't use the name "Wishbone" or the app icon as your own name or branding.
- Don't suggest that your build is the official Wishbone app, or that the maintainer made, approved, or supports it.
- Keep all copyright and license notices, as the MPL-2.0 requires. This includes the Acknowledgements screen in Settings.

Change these in the fork:

- The name under the icon on the Home Screen, and the name in your App Store listing.
- The app icon.
- `DEVELOPMENT_TEAM` and `WISHBONE_BUNDLE_PREFIX`, to your own team and prefix. The maintainer's team has registered every identifier under `com.codemonkeylabs.wishbone`, so another team can't sign with them.
- `WISHBONE_SOURCE_URL`, to your own repository, so that the "Source code" row in Settings leads to the source your build runs.
- `WISHBONE_PRIVACY_URL`, to your own privacy policy, if your build sends diagnostics of its own. The diagnostics DSN in the repo is empty, so a fork sends nothing until it sets one.
- `WISHBONE_SUPPORT_URL`: empty it, which removes the support row from Settings. Or point it at your own page, and change the row's words, which name the maintainer.

The settings are in `Config/Shared.xcconfig`. [`docs/development.md`](docs/development.md) says how to override them.

## Builds for your own devices

A build that you install only on your own devices needs only two settings: your `DEVELOPMENT_TEAM` and your own `WISHBONE_BUNDLE_PREFIX`, in `Config/Local.xcconfig`. See [`docs/development.md`](docs/development.md). The rules above don't apply to it.

## What you may say

You may say that your project is "based on Wishbone", refer to this project by name, and link to this repo.

## Questions

Open an issue if you are not sure whether a use is fine.
