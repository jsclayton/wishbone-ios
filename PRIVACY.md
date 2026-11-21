# Wishbone Privacy Policy

Effective date: November 21, 2026

Wishbone for iPhone and iPad is an app for Wishbone, a private wish list server that a family runs for itself. The app is developed by Code Monkey Labs, LLC ("we", "us").

## The short version

Your family's wish lists go only to your family's own Wishbone server. We never see them. The app sends crash and fault reports, called diagnostics, so that we can find and fix problems. Diagnostics never include anything from your family's lists, anyone's name or birthday, or your server's address. You can turn them off at any time in Settings, under Share diagnostics. The app has no advertising and no tracking of any kind.

## Your family's Wishbone server

Someone in your family, or someone your family trusts, runs a Wishbone server. We call that person the operator. Everything you and your family enter in the app goes only to that server: lists, items, notes, images, names, birthdays, occasions, and gifts.

The app also tells that server your device's time zone, so that gifts are revealed at your own midnight, and the dates of your occasions follow your own day. It sends the time zone when you sign in, and again when it changes.

That server is not ours, and we have no way to see what it holds. The operator controls that data, and this policy does not cover it. To have your account deleted, ask your family's admin. The operator deletes it on the server.

## Data stored on your device

To work, the app keeps these on your device:

- Your server's address, your sign-in token, and your user ID, in the iOS Keychain, for this device only
- A copy of what you can see on your server: people, lists, items, gifts, occasions, groups, and invitations, so that the app works when the server can't be reached
- The changes you make while the server can't be reached, until the server has received them
- Images from your server and from stores, in a cache
- A small file of upcoming occasions (names and dates only) for the app's widget
- Your settings for reminders, and the reminders that the app schedules on your device
- Whether diagnostics are on, and while they are on, a random diagnostics ID and any reports not yet sent

Apart from the diagnostics described below, this data stays on your device and goes only to your own server. It is never sent to us.

When you sign out, or your server signs you out, the app deletes your sign-in, its copy of your server's data, the changes not yet sent, the image cache, the widget's file, and your reminders. Deleting the app deletes the same data, except the sign-in, which iOS keeps in the Keychain. If you reinstall the app, it finds that old sign-in, signs it out on your server if it can, and deletes it. The app then starts signed out.

## Diagnostics

Diagnostics are on unless you turn them off. The app tells you about them on its first screen, and sends nothing before that screen has shown. The switch is in Settings, under Share diagnostics, and applies to the whole device, for everyone who uses the app on it.

When diagnostics are on, the app sends:

- Crash reports, including when the system stops the app for using too much memory or not answering
- Reports of the app freezing while it is on screen
- Reports of faults in the app itself, by an error code: for example, when it can't read an answer from your server, or when your server refuses a change the app sent
- The app's version, the version of Wishbone that your server runs, your device's model, and its iOS version
- For requests to your server: the kind of request and which part of Wishbone's interface it used, with every ID removed, and whether it succeeded
- When the app starts, goes to the background, or comes back, and the kind of screen you opened (such as "list page"), never what the screen showed
- A random diagnostics ID that the app makes on your device. It is not your Apple Account, your Wishbone user, or anything your server knows.

Diagnostics never include:

- anything from your family's lists: titles, notes, links, prices, or images
- anyone's name, birthday, or profile
- gifts, or which items are claimed
- your server's address, your sign-in token, or a login link

Diagnostics go to Sentry, which processes them for us and stores them in the European Union (Frankfurt, Germany). As with any internet connection, Sentry sees your device's IP address when a report arrives. We have set Sentry not to store it. We use diagnostics only to find and fix problems in the app. We do not sell them, use them for advertising, or combine them with data from other companies, and we do not use them to track you.

When you turn diagnostics off, the app deletes anything it has recorded but not yet sent, and sends nothing more. It also deletes the diagnostics ID. If you turn diagnostics on again, the app makes a new one.

The app's share extension and widget send no diagnostics. Test builds, offered through Apple's TestFlight, send the same diagnostics as the App Store build.

If you have chosen in your device's settings to share analytics with app developers, Apple can also give us its own crash and performance reports for the app. We use these only to fix problems.

## Network connections

The app connects to:

- your family's Wishbone server
- Sentry, for diagnostics, while they are on
- a store's website, to load a product image that your server found there, with nothing from you but the request itself

To decide whether to show the Support Wishbone row in Settings, the app reads which App Store country your device uses. That stays on your device. The row opens a web page in your browser. The app sends nothing about you to that page, and the page's own privacy policy applies to what you do there.

We run no server, proxy, or relay for the app. Your lists and gifts never pass through us.

## Advertising and third parties

The app has no advertising, analytics, or tracking software. The only third party that receives anything from the app is Sentry, for the diagnostics described above.

## Children's privacy

The app is not made for children, but a family's server can hold a child's lists. A child's data goes only to their family's own server, as everyone's does, and never reaches us. Diagnostics carry no personal information about anyone, children included.

## Changes to this policy

If this policy changes, the new version is posted at this address, with a new effective date.

## Contact

Questions about this policy: [privacy@getwishbone.app](mailto:privacy@getwishbone.app)
