# Wishbone for iPhone and iPad

The iPhone and iPad app for [Wishbone](https://github.com/jsclayton/wishbone), private self-hosted family wish lists.

**Status:** The app is being built, and it is not on the App Store yet. The [spec](docs/spec.md) says what it does, and the code follows it. One person maintains it, so changes stay small.

- Sign in by scanning a login link's QR code, or by pasting the link. There is nothing to type.
- Share a link, a photo, or text from any app to add it to a list.
- Where your device allows several windows, put two lists side by side, and drag items between them.
- See the next birthdays and occasions in a countdown widget, and get a reminder before each one.
- Add an item from Control Center, the Lock Screen, or the Action button.
- Read your lists, and make most changes, when your server can't be reached. The changes are sent when it is back.
- Every job in Wishbone except the first setup, for everyone in the family: parents and children, and the admin.

Gifts stay a surprise on the device too. The widget, reminders, and every other place outside the app never show what is claimed.

## Requirements

- An iPhone or iPad with iOS or iPadOS 27 or later.
- A Wishbone server at version 2.5.0 or later. The app tells you if yours is older.

## Sign in

You need a login link from your family's Wishbone. Ask whoever runs it, or your parent. If you already use Wishbone in a browser, its sign-in screen shows a QR code for you.

In the app, tap **Scan QR code**, or copy the link and tap **Paste**. The first setup of a Wishbone server happens in a browser, not in the app (see the server's [README](https://github.com/jsclayton/wishbone#readme)).

## Privacy

Your family's lists go only to your family's own Wishbone server. The app's maintainer never sees them.

- If the app crashes, or something in it fails, it sends a report to the maintainer through Sentry, in the EU. Reports never include anything from your lists, anyone's name or birthday, or your server's address.
- Reports are on by default. The app tells you on its first screen, before it sends anything.
- To turn them off, open **Settings**, then **Share diagnostics**.

If you run a Wishbone server, this applies to everyone in your family who uses the app. Each person can turn reports off on their own device. The [privacy policy](PRIVACY.md) has the details.

## Read more

Much of the app is written by AI coding agents that the maintainer directs and reviews. [`AGENTS.md`](AGENTS.md) is their guide, and [`docs/workflow.md`](docs/workflow.md) is the process they follow.

[`AGENTS.md`](AGENTS.md) indexes every doc. Start with the [spec](docs/spec.md) and the [glossary](GLOSSARY.md). To help, read [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Build from source

You need a Mac with Xcode 27.2 and [mise](https://mise.jdx.dev). A simulator build needs no signing. To build for your own device, set your team and your own bundle prefix in `Config/Local.xcconfig`. [`docs/development.md`](docs/development.md) has every step.

## License

The code is under the [MPL-2.0](LICENSE). The name "Wishbone" and the app icon are not: see [`TRADEMARKS.md`](TRADEMARKS.md).

```text
Copyright © 2026 John Clayton and contributors

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
```

The app icon artwork is © John Clayton, all rights reserved. It is not under the MPL-2.0.

The app ships with two packages, each under the MIT License: [GRDB](https://github.com/groue/GRDB.swift) and [sentry-cocoa](https://github.com/getsentry/sentry-cocoa). Their license texts are in the app, in **Settings**, under **Acknowledgements**.

## Support

If Wishbone is useful to you, you can [buy me a coffee](https://buymeacoffee.com/jsclayton).
