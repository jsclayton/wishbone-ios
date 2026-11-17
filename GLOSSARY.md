# Wishbone for iPhone and iPad

The terms of the app. Use them in code, tests, UI copy, and docs.

The server's [glossary](https://github.com/jsclayton/wishbone/blob/main/GLOSSARY.md) is the vocabulary of Wishbone, and it binds the app. **User**, **list**, **gift**, **claim**, **session**, **search**, and every other server term mean here what they mean there. This file adds only the terms that the app has and the server does not. It grows with the [spec](docs/spec.md).

## Sign-in

**Instance address**:
The address of the instance that the app talks to. The app takes it from a login link: it is all the text before `/login/`, with the scheme, the host, the port, and any path.
_Avoid_: Server URL, base URL, host

## On the device

**System surface**:
A place outside the app's own windows where iOS shows the app's content or controls. In the first release, these are the countdown widget, reminders, the app icon, the share extension, and the Add item control. Spotlight, Siri, and Shortcuts are system surfaces when the app uses them.
_Avoid_: Extension (an extension is a build target, not a place), widget (as a general word)

**Reminder**:
A notification that the app schedules on the device for an upcoming occasion. A reminder is a system surface.
_Avoid_: Push, alert, notification (as the app's term)

**Unsent change**:
A change made in the app that the server has not accepted yet. The app sends it when the instance answers. Signing out loses it.
_Avoid_: Pending change, queued write, offline edit

## Privacy

**Family content**:
Anything that a family member entered, or that describes them: titles, notes, links, images, names, birthdays, the fields of a gift, and claim state.
_Avoid_: User data, personal data (as the app's term)

**Diagnostics**:
The crash and fault reports that the app sends to its maintainer. Diagnostics never carry family content.
_Avoid_: Analytics, telemetry, tracking

## Support

**Tip**:
Money that a person gives the app's maker. It unlocks nothing.
_Avoid_: Gift, donation
