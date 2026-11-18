# Wishbone for iPhone and iPad: Specification

This spec says what the iPhone and iPad app does, and it is the source of truth for the app. Terms in **bold** are defined in the server's [glossary](https://github.com/jsclayton/wishbone/blob/main/GLOSSARY.md) or in the app's [glossary](../GLOSSARY.md). Decisions that are hard to reverse are in [`docs/adr/`](adr/README.md). Each screen and each system surface has a spec of its own in [`docs/screens/`](screens/README.md), and each section below names its screens.

## How to read this spec

### The server's rules bind the app

- The server's [spec](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md) and [glossary](https://github.com/jsclayton/wishbone/blob/main/GLOSSARY.md) bind the app. Every server rule in them holds here: who sees what, who can do what, what changes state, and which input is valid.
- This spec holds only what the app adds: its places, its words, its defaults, and how it uses the device. Each section names the server spec sections that it relies on, and never copies them.
- The server spec's **Screens** subsections describe the web app. They are background for the app, never a design to copy.
- If this spec and the server's spec seem to disagree, stop and ask the maintainer.

### The minimum server version

- The app works with a Wishbone server at its minimum version, or a newer one. The app reads the server's version before it signs in, and blocks with a message when the server is older (see [Version checks](#version-checks)).
- The minimum version, the pinned server that the tests run against, and the app's copy of the server's OpenAPI document change together, in one commit (see [ADR 0004](adr/0004-the-api-client-is-written-by-hand-and-checked-against-a-pinned-copy-of-the-servers-openapi-document.md) and [ADR 0007](adr/0007-the-tests-run-against-a-real-wishbone-server-built-from-a-pinned-commit.md)). To use a newer server feature, raise the minimum on purpose.

### Placement is decided, presentation is provisional

The maintainer decides how a screen looks by using it. So this spec decides placement, and marks presentation as provisional until the maintainer has used the screen.

- **Decided, and not marked:** which places exist (a tab, a sheet, or a pushed screen), where a link opens, what each action does, and the words, unless they are marked.
- **Provisional, and marked:** layout, look, order, symbols, and draft words. Each provisional part has a plain default.
- **The mark** is "**Provisional.** Plain default: ...", written where the part is described.
- **Built plain** means system lists, forms, and controls, the system font with Dynamic Type, SF Symbols, and the one accent color. Nothing is invented.
- An implementer builds the plain default without asking. Nobody asks the maintainer to approve a look from a description or a picture.
- A mark comes off in a pull request, after the maintainer has used the screen and settled it. The pull request says so.

### Windows, not devices

Rules go by what the window and the system allow: a narrow window or a wide one, one window or several. They never go by the device. For example, iPad and the iPhone Duo both allow several windows of the app.

## 1. Goals and non-goals

Relies on the server spec's [Goals](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#goals), [Non-goals](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#non-goals), and [Server and clients](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#server-and-clients).

### Goals

- The app is the best way to use Wishbone. It is designed from the API and from iOS, follows Apple's Human Interface Guidelines, and uses the system's own features. It does not copy the web app, which exists to give the family every function quickly.
- One universal app for iPhone and iPad, on iOS and iPadOS 27 or later. Its only other targets are its share extension and its widget extension.
- It serves everyone: the everyday user, the parent, and the admin. Only the first setup of an instance stays on the web, because setup gives no bearer token.
- A user signs in with a login link, by scanning its QR code or by pasting it.
- The app is free and open source. A tip unlocks nothing (see [Support Wishbone](#support-wishbone)).

### The system features in the first release

A system feature is in the first release only when it passes three tests:

1. It needs no change to the server beyond the minimum version.
2. It works without Apple Intelligence, so every device behaves the same.
3. It makes a job that every family member does better: signing in, adding an item, or knowing that an occasion is coming.

The first release has six system features. If the release must lose one, it loses the last one first.

1. Sign-in by scanning a QR code or pasting a link (section 2).
2. The share extension (section 4).
3. Several windows side by side, with drag and drop between them, where the system allows several windows (section 9).
4. One countdown widget, for occasions only (section 7).
5. Reminders of upcoming occasions (section 8).
6. The "Add item" control, for Control Center, the Lock Screen, and the Action button (section 4).

Any other system feature waits for a decision against the three tests. The first release writes nothing to the device's search index, and donates no intents.

### Non-goals

- A native Mac, Apple Watch, or Apple Vision Pro app.
- The first setup of an instance in the app.
- Matching the web app's screens.
- A demo mode, or any code only for App Review. A reviewer signs in by Scan or Paste, as anyone does.
- An in-app web browser or web view (see [Web links](#web-links)).
- Push notifications. Push is a non-goal of the server, and a self-hosted server can reach Apple's push service only through a relay that someone must run and pay for. Reminders are local (section 8).
- Live Activities. They last 8 hours at most, and a countdown in days belongs to the widget.
- Private Cloud Compute. It needs a managed entitlement and a daily quota, and it sends wish list text off the device.

## 2. Sign-in, instances and the session

Relies on the server spec's [Login links](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#login-links), [Sessions and passkeys](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#sessions-and-passkeys), [Sign-in](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#sign-in), and [Versions of the API](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#versions-of-the-api). The device holds a **session**: one user on one instance. The documents say "session", never "account".

Screens: [signed-out](screens/signed-out.md), [version-block](screens/version-block.md), [profile-gate](screens/profile-gate.md), [sign-in-and-devices](screens/sign-in-and-devices.md), [settings](screens/settings.md).

### One session per device

- A device holds one session at most: one instance and one user. There is no switcher. See [ADR 0010](adr/0010-one-session-per-device.md).
- Storage and identifiers are keyed by instance and user from the start: the Keychain item, the local database, the image cache, the widget's file, and each reminder's identifier. A second session later is then an addition, not a migration.
- Signing out is the only way to change the user or the instance.

### The signed-out screen

Two ways in, one way to get help, and nothing to type.

- **Scan QR code** is the main button. It opens the app's own scanner, because the system Camera opens a login link in Safari, and the web page has no "Open in app" button.
- **Paste link** is the second button. It is the system paste button, so iOS shows no "allow paste" alert.
- **I don't have a link** opens a short help sheet:
  - Someone in your family runs Wishbone: ask them, or your parent, for a login link.
  - You already use Wishbone in a browser: open your sign-in screen there, which shows a QR code for you.
  - You are signed in to the app on another device: open Wishbone there, and use "Sign in on another device".
  - You have no instance: a link to the server project's page on running one.
- There is no address field, no name field, and no demo button.
- If the camera is denied or not available, the scan button says why and points to Settings. Paste still works.
- The foot of the screen has the diagnostics notice (see [The notice and the switch](#the-notice-and-the-switch)).

**Provisional.** Plain default: the two buttons stacked, the help link under them, and the notice line at the foot. The help sheet is a system list.

### Scan or paste signs in at once

- There is no confirm screen. The scan or the paste is the deliberate act, and nothing in the app opens a link by itself.
- The app takes the **instance address** from the link: all the text before `/login/`.
- The app first reads `GET /health` on that instance (see [Version checks](#version-checks)). Then it redeems the link. It does not call `POST /login-links/check`: with no button to show an expiry above, redeem alone gives the same answer.
- The app never sends a redeem with an `Authorization` header, because only the signed-out screen takes a link. So the server never revokes a session that the app holds.
- The scanner reacts only to a login link: an `http` or `https` URL with `/login/` and a token after it. It ignores any other QR code. A paste of anything else says "That isn't a Wishbone login link".
- On success the app says "Signed in as {name}", from the redeem response. Then it shows Home, or the profile gate first.
- On 401 `login_link_invalid`, the app says that the link was already used or has expired, and to ask for a new one. The server gives one answer for an unknown, a used, and an expired link.
- Accepted cost: the user does not see the instance address before the app talks to it. A hostile QR code can sign someone in to a fake instance, which learns nothing about the real one.

### Instance addresses

- The app accepts any `http` or `https` address, on any port, with any path. A self-hosted instance on a private network, such as a tailnet, is safe over plain HTTP on an IP address and a port. See [ADR 0011](adr/0011-plain-http-instances-are-accepted.md).
- The app shows no warning for an `http` instance. It can't tell a tailnet from the open internet, and the person who scans can't act on a warning. Settings shows the full address with its scheme.
- The server's cookies are always `Secure`, so the web app can't sign in over plain HTTP, except on `localhost`. A plain-HTTP instance is app-only, except on the server's own machine.

### Where the session lives

- One Keychain item holds the instance address, the token, and the user's ID. It is in a Keychain access group that the app, the share extension, and the widget extension share. One item keeps the address and the token in step.
- The item never leaves the device: no iCloud Keychain sync, and it is not restored onto another device from a backup. The server spec asks a native app to keep its token out of backups. iOS has no Keychain setting that keeps an item out of an encrypted backup, but a "this device only" item restores only onto the same device, which meets the rule's intent.
- The item is readable after the first unlock, because the widget and background refresh run while the device is locked.
- The redeem response has no user ID. The app saves the address and the token at once, because the link is now used. Then it reads `GET /users/me` and adds the ID.
- Nothing about the session is kept anywhere else. An extension that finds no item shows its signed-out state.

### The API's own 401 signs the device out

- Only the API's own answer counts: `application/problem+json` with the code `unauthorized`. A 401 from a reverse proxy, an access gateway, or a captive portal is "unreachable". The test is strict because a wrong sign-out costs the user a new login link from someone else.
- The device then forgets everything: the Keychain item, the local database with its unsent changes, the image cache, the widget's file, and the scheduled reminders. The session can be revoked because the device was lost.
- Every window shows the signed-out screen with one message: "You were signed out of {address}. Ask for a new login link to sign in again." The server does not say why (revoked, a year unused, or a deactivated user), so the app can't.
- If this device had asked for the user's account to be deleted, the message is "Your account has been deleted." (see [Account deletion](#account-deletion)).
- An extension that gets the 401 deletes the Keychain item and shows its signed-out state. The app clears the rest the next time it runs and finds no item.

### Unreachable never ends the session

- Unreachable is: no network, a timeout, a DNS or TLS failure, a 5xx, and any answer that is not the API's own. An instance on a tailnet is unreachable whenever the VPN is off, so this is common for some families.
- When signed in, the app keeps the session and shows the line "Can't reach {address}", which blocks nothing. What screens show meanwhile is in section 10.
- During sign-in, the app keeps the link and offers Try again. If the answer was lost on the way back, the retry reports a used link, and the user needs a new one.
- A certificate that the device does not trust gets its own message, with no bypass and no "trust anyway" button. An admin with a private certificate authority installs it on the device, or serves plain HTTP inside the tailnet.
- The extensions keep the session too. The widget keeps its last file.

### Version checks

- **The app is too old.** A 410 with the code `api_version_removed` shows "This version of Wishbone is too old for {address}. Update the app.", with a button to the app's App Store page. The extensions show "Open Wishbone".
- **The instance is too old.** The app reads `GET /health`, which needs no token, and compares the server's version with its minimum. If the server is older: "{address} runs Wishbone {version}. The app needs {minimum} or later. Ask whoever runs it to update."
- The check runs before redeem, so a link is never used up on an instance that the app can't work with. It also gives "No Wishbone found at {address}" for a link that points somewhere else.
- When signed in, the check runs again each time the app comes to the foreground. The block lifts by itself after the instance is updated.
- A version that the app can't read passes, so a development build of the server doesn't block contributors.
- Each block keeps the session.

### What sits in front of the tabs

- The signed-out screen, the two version blocks, and the profile gate each replace the whole window. None is a tab, or a sheet over the tabs.
- The order is: signed out, then a version block, then the profile gate, then the tabs.
- A link from outside that arrives while one of them shows is dropped, not kept for later. The "Add item" control opens the signed-out screen when signed out.

### The profile gate

- After sign-in, and at each launch, a user with no `profile_confirmed_at` gets the finish-your-profile steps before anything else, until `POST /users/me/confirm-profile`. The server does not enforce this. The gate is the app's.
- Sign out is reachable from the first step.
- The extensions don't check.

**Provisional.** Plain default: one system form with the profile's fields and a Continue button.

### Sign-in and devices

This screen is in Settings (section 3). Settings itself has the **Signed in** block: the user's name, the instance address with its scheme, and **Sign out**. The screen has:

- A **Devices** list from `GET /users/me/sessions`, newest use first. Each row has a readable name made from the user agent ("Wishbone on iPad", "Safari on Mac") and when it was last used. The current one is marked "This device". The term stays **session** in code and docs. "Devices" is UI copy only.
- **Revoke** shows on a row when its `can_delete` is true, with a confirmation. Revoking "This device" is Sign out.
- The app and both extensions send the user agent `Wishbone iOS/{version} ({iPhone or iPad})`. iOS no longer gives apps the device's own name.
- A **Passkeys** list under Devices: name, when added, and when last used. Rename and delete follow `can_edit` and `can_delete`. The list is hidden when it is empty.
- There is no Add button for passkeys. A passkey is tied to the instance's domain, and one App Store build can't name every instance. A line says: "Passkeys sign you in to Wishbone in a browser. Add one there."

**Provisional.** Plain default: a system list with a section for each part.

### Sign out

- Sign out warns: "You need a new login link to sign in again." If unsent changes remain, the warning adds "{n} changes haven't been sent and will be lost."
- The app first tries to send the unsent changes. Then it calls `DELETE /users/me/sessions/current`, and clears the device as the API's own 401 does.
- Sign out with no connection still clears the device. The app tries the server call once. It keeps no token to try again with. If the call failed: "Signed out on this device. {address} could not be reached, so this device still shows in your Devices list until you remove it there."

### Sign in on another device

- A button with the Devices list, shown when `can_make_login_link` is true on the user's own record.
- A tap first asks for the device owner check (see [Making a login link](#making-a-login-link)). Then the app makes one link with `POST /users/me/login-links`.
- The login link screen shows the QR code first, then Copy and Share, and when the link expires. It is a sheet over a user's page. Inside Settings, which is already a sheet, it is pushed, because a sheet never opens a second sheet.
- The link is made on the tap, and kept while that screen is open. The server can't list or revoke links, and an unused link lives 7 days, so the app never makes one each time the screen draws.

**Provisional.** Plain default: the QR code at the top, with Copy and Share buttons under it and the expiry as a footer.

### Time zone

- After sign-in, and each time the app comes to the foreground, the app compares the device's time zone with `timezone` on the user's record. If they differ, it sends `PATCH /users/me` with the IANA name.
- It shows nothing and doesn't wait. A failure changes nothing, and the next foreground tries again.
- It reports only the signed-in user's own zone, never a child's. Only the app reports, never an extension. The last report wins, and there is no setting.

### A fresh install starts signed out

iOS keeps Keychain items after an app is deleted, and gives an app no signal when it is deleted.

- At sign-in, the app writes a marker to its shared container. Deleting the app deletes the container, not the Keychain item.
- A session with no marker is left over. The app revokes it on the server if it can, deletes it, and shows the signed-out screen.
- The extensions check the marker too, because the share extension can run after a reinstall before the app has been opened.
- An offloaded app, and a backup restored onto the same device, keep the marker, so they stay signed in. A backup restored onto a new device has the marker but no Keychain item. It starts signed out, and the app clears the stale data.
- After the app is deleted, its session stays in the user's Devices list until someone revokes it, the app is installed again on the same device, or it goes 365 days unused.

### The extensions and the control

Each acts for the one session, with no setting.

| | Signed in | Signed out |
|---|---|---|
| Share extension | Adds for the session's user | "Sign in to Wishbone first." |
| Countdown widget | Shows that user's occasions | "Open Wishbone to sign in." |
| Reminders | Scheduled for that user's occasions | None. Signing out removes them |
| Add item control | Opens the app on the Add screen | Opens the app on the signed-out screen |

- The app tells the widget to reload at sign-in and at sign-out.
- A reminder tapped after the user changed opens Home, because the app first compares the reminder's identifier with the current session.

## 3. Navigation and Home

Relies on the server spec's [Home](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#home) and [Navigation](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#navigation) for the rules the web app shares, and on the API's `can_*` fields. See [ADR 0001](adr/0001-tabs-that-become-a-sidebar-and-one-kind-of-window.md).

Screens: [tabs-and-sidebar](screens/tabs-and-sidebar.md), [home](screens/home.md), [lists](screens/lists.md), [gifts](screens/gifts.md), [add](screens/add.md), [user](screens/user.md), [list](screens/list.md), [item](screens/item.md), [gift](screens/gift.md), [people](screens/people.md), [settings](screens/settings.md), [acknowledgements](screens/acknowledgements.md), [not-found](screens/not-found.md).

### Tabs that become a sidebar

- The app has a few fixed tabs. In a narrow window they are a tab bar at the bottom. In a wide window they become a sidebar.
- The set of places never changes with the window's size. A resize changes where a place shows, never whether it exists.
- The tabs are **Home**, **Lists**, and **Gifts**.
  - **Home** is about giving: the countdown to the next occasion, your people, and Coming up.
  - **Lists** has everything the user can edit: their own lists, a part for each child, and the invitations that wait.
  - **Gifts** has Giving, Given, and Received, as three parts of one screen. One part shows at a time, and to change the part is not a push.
- There is no tab for people, Settings, or the admin.
- The sidebar has more rows: your lists, People, and each group's users. They are shortcuts to pages that exist anyway.
- A shortcut selects the tab that owns the page, and pushes the page there: one of your lists in Lists, and People or a user on Home. The page replaces whatever was pushed on that tab, as a link from outside does on Home.

**Provisional.** Plain default for the sidebar's extra rows: your lists, then People, then one section for each group.

### Home

- From top to bottom: the countdown, your people, and Coming up.
- The countdown says, for its occasion only, how many gifts the user has for it and how many are still to buy, for example "2 from you · 1 still to buy".
- Your people are grouped: "Your children" first, then "Your parents", then the user's groups.
- Coming up has the occasions in the next 60 days for everyone the user can see. It leads to the Occasions screen (see [Shared occasions](#shared-occasions)).
- Home has no "Not bought yet" list. The **Gifts tab carries a badge** with the server's count of gifts that need attention: `GET /gifts?giver_id=me&state=open&needs_attention=true`. Giving already sorts those gifts to the top.

**Provisional.** Plain default: the countdown as a card in the occasion's person color, the people as initials avatars in rows by group under a "People" heading, and Coming up as a system list.

### Adding: the plus at the end of the tab bar

- Adding is the round button that the system sets apart at the end of the tab bar (the search role of a tab), with a plus symbol. It opens the **Add screen**, which is a place, not a sheet.
- The Add screen's field is the system search field. On a narrow window it takes the tab bar's place, above the keyboard. The server's glossary calls this act **search**.
- The "Add item" control opens the same Add screen.
- A list's own page has an "Add item" row that adds to that list.
- The plus is filled with the accent color.

**Provisional.** Plain default: if the system's search tab doesn't take the accent color, the plus keeps the system look.

### Settings: a sheet from the avatar

- The user's avatar sits at the top trailing corner of Home, Lists, and Gifts. It opens Settings as a sheet.
- Settings holds what is about the user and this device:
  - The **Signed in** block (section 2).
  - **Your profile**.
  - **Sign-in and devices**, with Devices, Passkeys, and "Sign in on another device" (section 2).
  - **Reminders** (section 8).
  - **Share diagnostics** (section 11).
  - **Delete account** (section 6).
  - **For the admin**: Blocked stores, for the admin only (section 6).
  - **Support Wishbone** (see below).
  - **About**: **Source code**, **Acknowledgements**, and the app's version.
- Settings has one line of help on keeping gifts private on a shared device (section 7).

**Provisional.** The order and the sections. Plain default: a system list in the order above, with the help line as the footer of the section that holds Sign-in and devices.

#### Source code and Acknowledgements

- **Source code** opens the app's repository in the default browser. Its address is `WISHBONE_SOURCE_URL` in `Config/Shared.xcconfig`, so a fork's row leads to the fork's source.
- **Acknowledgements** pushes a screen with the app's MPL-2.0 notice, then the full license text of each package the app ships (GRDB and sentry-cocoa, both MIT). The build makes these texts from the pinned packages, so they never go out of date.

**Provisional.** Plain default: two rows in the last Settings section, and a plain scrolling text screen.

#### Support Wishbone

The app's one way to ask for support. Each rule has its reason beside it.

- **The United States storefront only.** The row shows only when StoreKit's `Storefront.current` is the USA. It is hidden on every other storefront and whenever the storefront is unknown, and it follows `Storefront.updates`. App Review guidelines 3.1.1(a) and 3.1.3 allow a link to an outside payment only on the US storefront.
- **Only here.** The Settings row is the only place where the app asks for support. There is no card, no prompt after some number of uses, and nothing on Home, Lists, or Gifts. Neither extension shows it (guideline 4.4).
- **A link, at once.** The row opens `https://buymeacoffee.com/jsclayton` in the default browser, with no screen in between, as every web link does.
- **Never for a child.** The row shows only when the signed-in user has no parents: the `parents` field of `GET /users/me` is empty, which is the server's meaning of a child. This holds on every storefront, and nothing in a child's For {name} part shows it. The app does not use Apple's Declared Age Range API: it adds a system prompt and an entitlement for one row, and it describes the Apple Account, not the Wishbone user.
- **The address is a build setting.** `WISHBONE_SUPPORT_URL` in `Config/Shared.xcconfig` holds it. An empty value means no row, anywhere and for anyone.
- Diagnostics never record anything about support (section 11).

**Provisional.** Plain default: a section headed "Support Wishbone", with one row, "Buy John a coffee", and the link-out arrow. VoiceOver reads "Buy John a coffee, opens in browser". The section's footer says "Wishbone is free and open source. A coffee unlocks nothing in the app." The section's place in Settings, the symbol, and the words are provisional.

### How each thing is reached

| Thing | From inside the app |
|---|---|
| A user | Home's people, the People page, the sidebar, or any name that links. The user's own page is the same page as anyone's |
| A list | Your own and your children's: the Lists tab. Anyone else's: their user's page |
| An item | Its list |
| A gift | The Gifts tab, and the item's page ("You claimed 1 for…"). Each pushes the gift's page |
| An occasion | The countdown and Coming up on Home. A person's occasion opens that person's page, the user's own opens their primary list, and a shared occasion opens its page. A birthday and a custom occasion have no page of their own |
| Add | The plus at the end of the tab bar, and "Add item" on a list's page |
| Settings | The avatar |

### Links from outside open on top of Home

- A link from outside (a widget tap or a reminder tap) opens the page that it names.
- That page is always **on top of Home**: the Home tab is selected, the page replaces whatever was pushed on Home, and Back goes to Home.
- Lists and Gifts keep whatever they showed.
- The "Add item" control opens the Add screen.
- A page that is missing or hidden shows the one "not found" page, on top of Home. As in the web app, a missing page and a hidden page look the same.
- Any list, item, user, or occasion can be opened from a link. Widget taps, reminder taps, and the control use this. A gift has a page, but no link from outside opens it, because no system surface names a gift.
- Which window the link opens in is in section 9.

## 4. Adding an item

Relies on the server spec's [Search](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#search-1), [Images from a search](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#images-from-a-search), [On the device](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#on-the-device), [Store links](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#store-links), and [Blocked stores](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#server-wide-settings). The server spec calls the form "the add form", and so does this spec.

Screens: [add](screens/add.md), [add-form](screens/add-form.md), [share-extension](screens/share-extension.md), [add-item-control](screens/add-item-control.md).

### The add form is pushed onto the Add screen

- After a search, the add form is pushed onto the Add screen. Back goes to the field, with the text still in it.
- A list's own "Add item" row opens the same Add screen in a sheet, fixed to that list. The form is pushed inside that sheet, so there is never a sheet on a sheet.

### Which list

- The Add screen, the "Add item" control, and the share extension always start on the user's **primary list**.
- **Add to** in the add form offers every list the user can edit: their own, their extra lists, and their children's lists, in the Lists tab's order. It is hidden when the user can edit only one list.
- No earlier choice is remembered. A parent who added once to a child's list must not later send a shared link there without noticing.
- A list's own "Add item" row is fixed to that list, with no choice. It is the way to add several items to one list.

### The empty Add screen

- The field's prompt is "Paste a link or type what you want".
- **Paste** is the system paste button, so iOS shows no "allow paste" alert. A tap searches at once: a link as a link, and anything else as typed words. The app never reads the clipboard by itself.
- **Take a photo** opens the system camera for one photo. If camera access is denied, it says why and points to Settings.
- **Choose a photo** opens the system photo picker for one photo. It needs no photo library permission.
- Typing, then pressing Search, does the rest.

**Provisional.** Plain default: the system search field, and the three ways in as rows of a system list under it.

### What the add form holds

- **Images** that the search found, to tick. The first one is the **primary image**. A photo that the user took or chose is the item's image.
- **Title** (required) and **Price**, with an optional "up to" price for a range.
- **Store link**: the store's name, when the search came from a link.
- **Add to** (see [Which list](#which-list)).
- **Options**, such as size or color: one choice for each, preset to what the link selected, or "Not sure". A chosen value is saved into the notes, as "Size: M". Wishbone never guesses an option.
- **Notes**, at most 2000 characters. The form says when it cut longer text.
- **The duplicate hint**: "Already on this list: {title}". On the Add screen it opens that item. Where the form is in a sheet, and in the share extension, it is not a link, because a sheet never opens a second sheet. It shows when the target list has an item with the same link, or the same title (case and extra spaces ignored). It never blocks the add. The server doesn't find duplicates, so the hint is the app's own.
- The item's page holds the rest: quantity (it starts at 1), more store links, and more photos of the user's own.
- On Add, the app uploads each image with `POST /images`, then adds the item with `image_ids` and `primary_image_id`.

**Provisional.** Plain default: a system form, in the order above.

### When search can't fill in the form

The same in the app and the share extension.

- **A blocked store** (422 `store_blocked`, before or after redirects): no form opens. The app says "Links from {store} are blocked on this Wishbone.", with "Add it without the link", which opens a blank form. If the add itself is refused with `store_blocked`, the form stays open with that line, and the link is dropped from it.
- **Over the hourly limit** (429 `rate_limited`): the form opens with the link kept and the other fields blank, and the note "This link wasn't read: you've read 30 links and photos in the last hour. Fill it in yourself, or try again later." The 429 from search has no `Retry-After`, so the note names no time. A photo works the same way, with the title "Photo from {date}".
- **Nothing found** (`found: false`, which includes a photo when the instance has no model): the form opens with what the input gave, and "Nothing could be read from {store}. Fill it in yourself." For a photo, it asks for a title.
- **"Fill it in myself"** always opens the form with what the user gave, and nothing else: a link as the store link, typed words as the title, or a photo as the item's image. While a link or a photo is read, it stops the wait.

**Provisional.** The words above are drafts. Plain default: each line as a footer in the form, or an inline message on the Add screen.

### When the instance can't be reached

- Search needs the instance. With no answer, the Add screen says "Can't reach {address}", with Try again, and the text stays in the field.
- "Fill it in myself" then opens the form with what the user gave. An add filled in by hand is an **unsent change** (section 10), and it shows on its list at once.
- The share extension keeps nothing to send later (see below).

### After Add

- **From the Add screen** (the plus, or the control): the form closes, and the Add screen comes back with the field empty. A row at the top, "Added {title} to {list}", opens the item. The row goes when the user leaves the Add screen.
- **From a list's "Add item" row:** the sheet closes, and the item is at the end of the list.
- **From the share extension:** it closes.

### The share extension

- It shows the same add form as the Add screen, with Cancel and Add, and the Add to choice. One form for both means it is built once.
- It takes one thing for each share. Wishbone is not offered when several things are shared.
  - **A link**, from Safari or any app.
  - **Text.** If it holds a link, the first link is used and the rest is ignored, because store apps share "Check out this toy! https://…". Otherwise the words go to search as typed words.
  - **One image**, a photo or a screenshot. It goes to search as a photo, counts against the hourly limit, and is titled "Photo from {date}" when no guess comes back.
- It sends only the link. It has no JavaScript file to read Safari's page, because the server spec says that a URL is always read on the server.
- When the instance can't be reached, it says "Can't reach {address}", with Try again and Copy the link (to add it later from the Add screen). Cancel keeps nothing. The extension has no queue, because a queue there needs the shared container.
- After an add, it tells the app, so the app syncs at once (section 10).

### The "Add item" control

- One control, for Control Center, the Lock Screen's buttons, and the Action button. It shows no data.
- It opens the app on the Add screen, on the user's primary list, as every add starts.
- It runs one App Intent with no parameters, so it fixes no IDs.

### No guess on the device yet

In the first release, every device sends typed words and photos to `POST /search`. A guess made on the device (which the server spec allows) needs Apple Intelligence, so it fails test 2 in section 1. The add form is built so that a guess can fill these same fields later, with no change to the flow.

## 5. Parents and children

Relies on the server spec's [Parents and children](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#parents-and-children), [Who acts while a user is deactivated](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#who-acts-while-a-user-is-deactivated), and [Received](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#restore).

Screens: [user](screens/user.md), [lists](screens/lists.md), [list](screens/list.md), [profile](screens/profile.md), [sign-in-and-devices](screens/sign-in-and-devices.md), [gifts](screens/gifts.md).

There is no parent mode. A parent acts for a child through their own session, with the child's ID on the ordinary routes. Every button shows from its `can_*` field.

### Whose list: name the recipient

- There is no banner, tint, or color for acting for a child.
- A list's page always shows a "For {names}" line with its recipients.
- Wherever a list is offered as a target (Add to, Move to…, a drop target), a list that the user is not a recipient of carries its recipients' names, for example "Lego · Emma". The Add screen groups a child's lists under the child's name, as the Lists tab does.
- Every button that acts for a child names the child: "Make Emma leave Lego", "Sign Emma in".

### Claim state on a child's list

A parent who is not a recipient sees the claim state on a child's list beside the edit controls, as the server sends it. There is no "hide what's claimed" switch.

### The For {name} part

A child's page has a "For {name}" part, with these rows from their `can_*` fields:

- **Edit {name}'s profile** pushes the same profile screen as "Your profile": name, last name, avatar, birthday, good to know, and the child's occasions, with Add, Edit, and Delete for custom occasions (`POST /occasions` with `kind: custom` and `user_id`). It has no time zone field. A parent's edit never confirms the profile, so the child still meets the profile gate at their first sign-in.
- **Sign-in and devices** pushes the same screen as the user's own, built for the child:
  - **Sign {name} in on a device**: the device owner check (section 7), then the same sheet as "Sign in on another device", with a link made by `POST /users/{child}/login-links`.
  - The child's devices (`GET /users/{child}/sessions`), each with Revoke.
  - The child's passkeys, each with Delete only (a parent never renames them), hidden when there are none.
- **What {name} received** pushes the same Received screen, built for the child (`recipient_id={child}`). Restore ("{name} didn't get this") and Add again show from `can_*`. Add again starts on the gift's list, or else the child's primary list, as the server spec says.
- **Ask to delete {name}'s account** (see [Account deletion](#account-deletion)).

The time zone is never shown or sent for a child. The Gifts tab's Received is the user's own only (`recipient_id=me`), although `GET /gifts` also returns the children's.

**Provisional.** Plain default: the For {name} part as a section of the child's page, with each row pushing its screen.

### A new list for a child

- The Lists tab has one **New list** button. When the user has children, the form asks **For**: the user by default, or each child whose `can_create_list` is true.
- For a child, the form says that the child is the recipient and the parent is not. The new list's page opens after Save.

**Provisional.** Plain default: a system form in a sheet. The draft line is "Emma's list. You can edit it, but it isn't yours."

### A deactivated child

- "Deactivated" shows beside the child's name everywhere.
- The child's page says: "Only the admin can reactivate {name}. Until then, you can't change anything for {name}."
- The child's part of the Lists tab stays, filled from `GET /lists?recipient_id={child}`. Its lists are read-only, and its invitations show without Accept.
- The For part keeps **What {name} received**, with no Restore and no Add again. Edit profile and Sign-in and devices are hidden. This differs from the web app, which hides Received too.
- A 403 `user_deactivated` from a stale screen shows the same line about the admin.

### A child's own app

- A child gets the same app as everyone. There is no child mode, no age or role setting, no limits of the app's own, and no mark that the user is a child.
- Home shows "Your parents". The rest follows `can_*`.
- The profile gate runs as for anyone, so the child confirms what their parent filled in.
- A child who can't read yet is served by their parent, on the parent's own device.

### The rest, as the server has it

- **Invitations for a child** show in the child's part of the Lists tab and on the list's page ("Mom invited Emma to Cousins"). Accept and Decline show from `can_*`, with no confirmation.
- **Make {name} leave** asks for confirmation. Its button repeats the action ("Make Emma leave Cousins"). When the child's row has `sees_list_after_leaving`, it warns: "Emma will see what's been claimed on this list, including gifts for Emma."
- **Delete a child's extra list** shows from `can_delete`, when the child is its only recipient.
- **Giving a child a device the parent uses:** the parent signs out there first (one session per device). Then the child's device scans the QR code from "Sign {name} in".

**Provisional.** The words in this section are drafts.

## 6. The admin

Relies on the server spec's [Admin and setup](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#admin-and-setup), [Shared occasions](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#shared-occasions), [Deactivation and deletion](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#deactivation-and-deletion), and [Groups](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#groups).

Screens: [people](screens/people.md), [group](screens/group.md), [new-user](screens/new-user.md), [user](screens/user.md), [occasions](screens/occasions.md), [blocked-stores](screens/blocked-stores.md), [delete-account](screens/delete-account.md).

### Scope

- The app does every admin job that the API offers: New user, linking and unlinking parents, deactivate and reactivate, groups (create, rename, delete, add and remove users, nest groups), shared occasions (create, edit, delete, attach groups, or mark Everyone), blocked stores, Sign-in and devices for any active user, and completing a deletion request.
- There is no Admin tab. Each admin part shows from `is_admin` or a `can_*` field, so an everyday user never meets one.
- The app never names a CLI command or an environment variable. The UI says "the person who runs Wishbone". Code and docs say **operator**.

### The admin's For {name} part

The rows show from their `can_*` fields, in this order.

- **An active user:**
  - Edit {name}'s profile
  - Sign-in and devices
  - **Parents**, which pushes the user's parents, each with Remove, and Add parent. Neither asks for confirmation. A refused loop shows the server's `detail`.
  - **Deactivate {name}**
  - **Delete {name}** (see [Account deletion](#account-deletion))
- Deactivate asks for confirmation: the user's devices are signed out, their open gifts are released, and only you and their parents see them until you reactivate them.
- **A deactivated user:** "Deactivated" beside the name, the line "{name} can't sign in. Reactivate to bring them back as they were.", and the rows **Reactivate {name}** (no confirmation), Parents, and Delete {name}. Profile and Sign-in and devices are hidden.
- **A user seen only through the admin's access:** the page says "You see {name} because you're the admin. Their lists show only to people who share a group with them."
- What {name} received stays a parent's row only. The admin has no access to gifts.
- An admin who is also a user's parent gets both sets of rows.
- Every login link that the admin makes, for any user, first asks for the device owner check, once for each tap.

**Provisional.** The words in this section are drafts. Plain default: rows in the For {name} section, in the order above.

### People

The People page is reached from the "People" heading on Home, and from a sidebar row in a wide window. Everyone sees the people they can see, by group. For the admin, from top to bottom:

1. **Asked to be deleted**, when there are requests.
2. Everyone's parts: Your children, Your parents, and your groups.
3. **For the admin**: **All users** (every user by name, searchable, with "Deactivated" beside a deactivated user, which is also how to reach a user in no group), **All groups**, and **Deactivated**.
4. **New user** and **New group**, in the toolbar's add menu.

**Provisional.** Plain default: a system list in the order above. The add menu's symbol is `person.badge.plus`, so that it differs from the tab bar's plus.

### New user

- A sheet: Name, Last name, Birthday (the year is optional), Parents (any number, optional), and Groups (any number, optional).
- Groups is the app's convenience: after `POST /users`, the app adds the user to each group with `POST /groups/{id}/users`. If one fails, the user is still made, and their page says which group didn't take them.
- The app sends no time zone. The user's own device reports it.
- After Save, the new user's page opens. Sign-in and devices, in the For part, is the next step, because it has Sign {name} in on a device. The sheet does not go to a login link, because many new users never sign in.

**Provisional.** Plain default: a system form in a sheet.

### Groups

- **A group's page is for the admin only.** It opens from All groups, and from a group's heading on People. For anyone else, a group's heading is not a link.
- It lists the users directly in the group, each with Remove, and the groups inside it, each with Remove, under "Everyone in these groups is in {group}".
- **Add users** picks from active users who are not directly in it. **Add group** picks from the other groups. A refused loop shows the server's `detail`. Add and Remove ask for no confirmation.
- A deactivated member shows "Deactivated" and has no Remove.
- Rename is a simple edit.
- **Delete group** asks for confirmation: "Its users and the groups inside it stay. People who see each other only through {group} will stop seeing each other's lists."

**Provisional.** The words are drafts. Plain default: a system list with a section for users and one for groups.

### Shared occasions

- Coming up on Home leads to the **Occasions** screen. Everyone sees the occasions there.
- The admin also gets a **Shared occasions** part: every shared occasion, soonest first, each saying who it reaches ("Everyone" or the group names), and **New shared occasion** in the toolbar.
- The form has three fields:
  - **Name**
  - **When**: every year on a date, once on a date, the nth weekday of a month, or the last weekday of a month
  - **Who**: Everyone, or Groups
- The app attaches the groups after the create, and names any attach that failed.
- Edit is the same form. Its footer says that a switch to Everyone drops the groups, and that the gifts of people it stops reaching move to their next occasion.
- **Delete** asks for confirmation: "Gifts picked for {name} move to the next occasion of the people they're for, and each giver sees why."
- A shared occasion's page ("See who's on it") is the same for everyone. The admin also gets Edit and Delete there.

**Provisional.** The way in, the layout, and the words. Plain default: the Occasions screen pushed from Coming up, as a system list, with the form in a sheet.

### Blocked stores

- Settings has a **For the admin** section with one row, **Blocked stores**. It is the only admin thing in Settings.
- Blocked stores lists the blocked stores by name. **Add** takes a host name or a pasted web address. A store that is already blocked counts as success. **Unblock** is a swipe action and a context menu item, with no confirmation.
- The footer says: "Links from these stores and their subdomains can't be added or searched. Items that already have them keep them."
- The For the admin section's footer says: "Moving the admin role, backups and server settings are done by the person who runs Wishbone, on the server." It links to the server's docs on running an instance. Nothing else in the app mentions these jobs.

**Provisional.** The words are drafts. Plain default: a system list, with Add in the toolbar.

### Account deletion

Apple requires an app to let a person start the deletion of their own account in the app (guideline 5.1.1(v)). Wishbone does this as a request that the admin completes, not as an instant self-deletion. A child can't then wipe their lists and gifts by accident, and deletion stays the admin's decision. This needs a server at the minimum version, which takes deletion requests.

- **The user:** Settings has **Delete account** for every user except the admin. It pushes a screen that says what goes (lists where you are the only recipient, and gifts for you alone) and what stays (gifts you gave stay with their recipients). It also says: "The admin will delete your account. Until then you can keep using Wishbone or cancel the request." It promises no time.
- **Ask to delete my account** is a destructive button, with one confirmation. While the request is open, the row reads "Deletion asked for on {date}", with **Cancel request**.
- **The admin's own row** says: "You're the admin, so your account can't be deleted. The person who runs Wishbone can make someone else the admin first."
- **A parent for a child:** the For {name} part has **Ask to delete {name}'s account**, with the same screen and confirmation. Any of the child's parents, or the child, can cancel it.
- **The admin completes it.** The request shows on the user's page in the For part ("Asked on 12 Nov to have their account deleted", or "Asked by Dad on 12 Nov"), and at the top of People. **Delete {name}** shows from the server's `can_*` field. Its confirmation says what goes and what stays, and names any child left with no parent. Its button repeats the action ("Delete Emma"). There is no Decline and no badge.
- **When it is done**, the device is signed out (section 2).

**Provisional.** The words in this section are drafts. Plain default: a pushed screen with the text and one destructive button.

## 7. Secrecy on the device

Relies on the server spec's [Who sees a gift](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#who-sees-a-gift).

Screens: [countdown-widget](screens/countdown-widget.md), [reminder](screens/reminder.md), [share-extension](screens/share-extension.md), [add-item-control](screens/add-item-control.md), [app-icon](screens/app-icon.md), [sign-in-and-devices](screens/sign-in-and-devices.md).

### What is at risk

The server already keeps claim state from a recipient's own session. So the only leak left on a device is the **giver's own data, seen by someone else**: the recipient who looks at the giver's Lock Screen or widget, picks up the giver's unlocked phone, or uses a shared iPad signed in as the giver.

What must stay hidden is what the server hides from a recipient: **claim state** (which items are claimed, how many are still wanted, "You claimed 1") and every open gift with its fields (bought, private note, from label, occasion). A given gift is not secret in this sense, because its recipients see it in Received.

### The rule for system surfaces

**A system surface never shows claim state or an open gift, not even as a count.** Whoever is near the device sees a system surface, and that is often the recipient. Even "1 gift for Dad's birthday" tells Dad something.

| System surface | What it may show |
|---|---|
| Countdown widget | Occasions and their countdown only. Nothing about gifts |
| Reminders | The occasion and the person only (section 8) |
| App icon | No badge. The Gifts tab's badge is inside the app |
| Share extension | The user's own add form, and the lists they can edit |
| Add item control | No data |

- When the app later uses Spotlight, Siri, or Shortcuts, the same rule holds.
- Until then, the app's windows and user activities are not eligible for Spotlight search or Siri prediction, and the app donates no intents.
- An item dragged out of the app carries no claim state (section 9).

### No Face ID lock of the app's own

- The app has no Face ID lock on any screen. Claim state shows on every other person's list page, not only on Giving, so a lock on Giving alone guards almost nothing.
- iOS already has a lock for the whole app: touch and hold the icon, then choose **Require Face ID**. It needs Face ID or the passcode to open the app, keeps the app's content out of notification previews and search, and works in every window.
- So the guard is the device's lock, plus Require Face ID.
- The app does not cover its snapshot in the app switcher: whoever can open the switcher can open the app.

**Provisional.** Plain default for Settings' one help line: "To keep your gifts private on a shared device, touch and hold Wishbone on the Home Screen and choose Require Face ID." Where it sits is provisional.

### Making a login link

A glance leaks once, while the giver is near. A login link gives a session as the user for up to a year, on someone else's device, seen only as a row in Devices.

- Before the app makes any login link (the user's own, a child's, or the admin's for any user), it asks for the device owner check: Face ID, Touch ID, or the passcode.
- If the check is cancelled or fails, no link is made and the sheet doesn't open.
- A device with no passcode can't do the check, so the link is made without it.
- One check for each tap. The open sheet's QR code, Copy, and Share need no second check.
- **Copy** puts the link on this device's clipboard only (no Universal Clipboard), and the clipboard drops it after 10 minutes. **Share** lets the user pick where the link goes, AirDrop included.

### Data at rest

- The Keychain item stays as section 2 sets it: readable after the first unlock, this device only, with no biometric access control. The share extension and the widget can't show a Face ID prompt.
- Files use iOS's default protection (until the first unlock), so background refresh can sync while the device is locked.
- The stricter options guard against forensic extraction from a locked device. That is not the family's threat. The family's threat is the screen.
- **Nothing that holds claim state goes into the app group's shared container.** Only the widget's occasions-only file and the sign-in marker live there. The share extension reads lists from the API, not from a shared cache.

### A mirrored, shared, or recorded screen

The app shows the same whether its window is mirrored, shared, or recorded, and screenshots are not blocked. Showing the screen is the user's choice, like turning it toward someone.

### Accepted costs

- A shared iPad signed in as one person shows that person's secrets to anyone who opens the app, unless they turn on Require Face ID. That then keeps the others out of Wishbone completely. This follows from one session per device.
- Anyone who holds an unlocked device with no app lock sees what the giver sees, for as long as they hold it.
- A mirrored or recorded screen shows what is on it.

## 8. Reminders

Relies on the server spec's [Occasions of a user](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#occasions-of-a-user) and [Shared occasions](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#shared-occasions).

Screens: [reminder](screens/reminder.md), [reminders-settings](screens/reminders-settings.md).

### One kind of reminder

- The first release has one kind of **reminder**: an occasion is coming up. It is the same for every user, whatever they have claimed or bought.
- There is no "not bought yet" reminder. It shows claim state, which section 7 forbids on a system surface. A neutral reminder that fires only when gifts are not bought leaks the same thing.
- There is no reveal reminder. The app learns about given gifts only by syncing after midnight, and background refresh can't promise that.
- The Gifts tab's badge is the nudge for gifts not bought, inside the app.

### Which occasions

- Every occasion that the user can see: exactly what the server returns for them. That is the birthdays and custom occasions of everyone they can see, the shared occasions, and their own occasions.
- Every reminder names only the occasion and the person. There is no app icon badge.

**Provisional.** The words are drafts:

- someone else's birthday: "Emma's birthday is in 2 weeks"
- a custom occasion: "Emma's graduation is in 2 weeks"
- a shared occasion, by its name: "Christmas is in 2 weeks"
- the user's own: "Your birthday is in 2 weeks", a nudge to get their list ready
- on the day: "It's Emma's birthday today"

### One switch, and the timing

- Reminders are on or off for all occasions together. There is no muting of one person or one occasion.
- Two reminders for each occasion, both at 9:00 in the device's time zone:
  - **The early one:** 2 weeks before by default. The user picks 1 week, 2 weeks, or 4 weeks. Two weeks matches the server's 14-day window for a gift that needs attention, and leaves time to order and ship.
  - **On the day:** on by default, with its own switch.
- The time of day is fixed in the first release.
- `next_date` is a date in the occasion's own zone. The reminder fires at 9:00 on that date, in the device's zone.
- The Settings row **Reminders** opens a screen with the switch and the timing choices.

**Provisional.** Plain default: a system form.

### Turning them on

- Reminders are on by default. There is no prompt at sign-in.
- After sign-in and the profile gate, the app asks for **provisional** authorization. iOS shows no alert, delivers quietly to Notification Center, and offers Keep or Turn Off on the first reminder.
- The Reminders screen has **Show on Lock Screen**. Only a tap on it asks for full authorization, with the system alert.
- If notifications are off for the app in iOS, the screen says so, and links to the app's page in iOS Settings. The app never asks twice.

### Staying correct

- The app **rebuilds the whole set** from the local database's occasions in the next 60 days. It removes every pending reminder of the session, then schedules the new set.
- It rebuilds after every successful sync (section 10), which includes the sync at sign-in, at each foreground, after the user changes an occasion or a birthday, and in background app refresh. It also rebuilds when the user changes the reminder settings.
- A failed sync leaves the set as it is.
- Each reminder is a single date trigger, with no yearly repeat, so no reminder outlives the data it came from.
- Only occasions in the next 60 days, and at most the 60 soonest reminders. iOS has long kept 64 pending local notifications for each app, so the cap stays below that.
- Each reminder's identifier carries the instance, the user, the occasion, and which reminder it is (early or on the day). Sign-out, the API's own 401, and a fresh install remove every reminder.
- **Accepted cost:** if neither the app nor background refresh has run for weeks, a reminder can fire for an occasion that moved or went away. The 60-day window limits how stale it can be.

### What a tap opens

By the rule in section 3, the page opens on top of Home.

- Someone else's birthday or custom occasion: **that person's page**.
- The user's own occasion: **their primary list**.
- A shared occasion: **Home** itself, where the countdown and Coming up show it.
- A person that the user can no longer see gives the one "not found" page. A reminder from another session opens Home.
- A reminder has no action buttons.
- A tap on the countdown widget follows the same three rules.

### Why there is no push

- The app does not ask the server for push. Push is a non-goal of the server. So to ask for it changes a goal, and does not only add a feature.
- A self-hosted server reaches Apple's push service only through a relay that holds the app's push key. Someone must run it and pay for it, which clashes with a free app.
- With one kind of reminder and the 60-day rebuild, push mostly fixes only the stale-weeks cost above.

## 9. Windows, dragging and keeping in step

Relies on the server spec's [Moving an item](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#moving-an-item) and [Writes](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#writes). Every rule here goes by what the window and the system allow (one window or several), never by device.

Screens: [list](screens/list.md), [item](screens/item.md), [lists](screens/lists.md), [add](screens/add.md), [not-found](screens/not-found.md), and the [keyboard shortcuts](screens/README.md#keyboard-shortcuts).

### A drag between lists is a move

- Always a move, never a copy: one `PATCH /items/{id}` with `list_id` and `position`. The server puts the item at that place on the new list, in one transaction.
- Only an item on a list that the user can edit can be dragged within the app, and only onto another list that they can edit. `GET /lists?can_edit=true` gives the lists that qualify.

### Where an item can land

In any window, on any device:

- **A list's page:** at the drop point (`list_id` and `position`).
- **A list's row** in the Lists tab or the sidebar: at the end (`list_id` only).
- **Its own list:** a reorder (`position` only).
- A person is never a target, because a person can have several lists.
- A target that the user can't edit refuses the drop and shows no highlight.
- A list shown in another order than its own (for example, by price) takes no reorder, and a drop on it goes to the end.

### Every drag has a way without dragging

- **Move to…** on an item, in its context menu and its page's edit controls, when `can_edit` is true and another list passes `can_edit`. It opens a picker of those lists. The item goes to the end of the list picked.
- **Reorder** on a list's page, when `can_edit` is true: the system edit mode, with handles and the accessibility move up and move down actions.

**Provisional.** Plain default: Move to… as a context menu item, its picker as a system list in a sheet, and Reorder as the standard Edit button.

### What the windows show after a drop

- The item shows in its new place at once, in every window that shows either list. Every window reads the one local database (section 10). The change is an unsent change, sent behind it.
- When the server accepts it, the app takes the returned item, and applies the server's shift rule to the others: the gap closes on the old list, and the others shift on the new one. The next sync corrects any drift.
- Only a refusal from the server (403 `cannot_edit_target_list`, or 404) rolls the item back, in every window. With no connection, the move waits as an unsent change.
- There is no confirmation and no gift warning before a move. The server spec forbids the warning, because it shows a recipient that the item is claimed.
- A move or a reorder sends no `If-Match`. Someone else's edit to the item must not block a move.

**Provisional.** Plain default: a refusal shows as a system alert in the window of the drop, with the app's words for the error code. A refusal that comes later shows as described in [Late refusals](#late-refusals).

### One item for each drag

- Adding a second item to a drag is refused. The server has no batch move, and a partial failure with shifting positions is hard to get right.

### A drop from another app starts an add

- The targets are the Add screen, and the page of a list that the user can edit. A list's row does not take it, because a drop on a row is a move, with no form.
- On the Add screen, the add form opens filled in, on the user's primary list, as every add starts. On a list's page, it does what that page's "Add item" row does, filled in, with that list set.
- A link or text goes to `POST /search`, as a share does. An image goes to `POST /search` as an image, as Choose a photo does.
- One link, image, or text for each drop. A drop of several is refused.
- Nothing is made until the user taps Add.

### Dragging an item out to another app

- Allowed from any list that the user can see.
- It carries the item's first store link (in the order this viewer sees them) as a URL, and its title as text. With no store link, it carries the title only.
- It never carries claim state, notes, price, gifts, or an address on the instance.
- A move between the app's windows uses an in-app reference (the item's ID within this session) that no other app reads. A drop from another session is refused.
- An item on a list that the user can't edit can be dragged out, but every in-app target refuses it, with no highlight.

### Opening a window

These show only where the window and the system allow several windows.

- **Open in New Window**, a context menu command on a list or a person.
- **A list row or a person row dragged to the edge of the screen** (from the Lists tab, the sidebar, Home's people, or the People page).
- Both open a whole-app window with that page on top of Home, as a link from outside does.
- An item drag never opens a window.
- The system's own new window opens the whole app at Home.

### A link from outside opens in the window used last

- A reminder tap, a widget tap, or the "Add item" control opens in the window that the user used last, which iOS brings forward. The app does not pick another.
- In it, the rule of section 3 applies: the page on top of Home, or the Add screen for the control. The other tabs keep their place.
- Never a new window. The Human Interface Guidelines say to avoid opening new windows by default.
- With no window open, the app opens one, and the rule applies there.
- If iOS hands the tap to another window, the app goes with it.

### Closing a window

- A window asks before it closes only when it holds an add or edit form with typed changes that are not saved. Every other window closes at once.

**Provisional.** Plain default: the system's confirmation, such as "Discard this item?".

### A page that goes away under a window

- When a change in one window takes away a page that another window shows (a list deleted or left), that window shows the one "not found" page in its place. Back works as usual. Nothing goes away behind the user's back.
- A moved item keeps its page, because its address has no list. The page shows the new list's name.
- Signing out, or the API's own 401, replaces every window with the signed-out screen.

### What a window remembers

- Each window restores its tab and the pages pushed on each tab, by ID only.
- A page that no longer exists, or that is hidden, is dropped quietly on restore. The window shows what was under it.
- An add or edit form is not restored. The closing confirmation guards unsaved work.
- If the session changed while the app was closed, every window starts at Home.

### No live updates from the server

- The first release needs no event stream from the server.
- Windows on one device stay in step through the one local database, for every write, not only drags.
- Other people's changes, and changes from other devices, arrive when the app syncs (section 10).

## 10. Offline and keeping in step

Relies on the server spec's [Collections](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#collections), [Writes](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#writes), [Images](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#images), and [Versions of the API](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#versions-of-the-api). The server at the minimum version gives a client a cheap way to keep a local copy current (conditional `GET`, and the changes since a point for each caller), and an optional `Idempotency-Key` on writes. See [ADR 0005](adr/0005-grdb-is-the-local-database-and-screens-read-only-it.md) and [ADR 0006](adr/0006-writes-are-a-journal-of-unsent-changes-the-server-decides-and-claims-are-online-only.md).

Screens: the states in [What every screen shares](screens/README.md#what-every-screen-shares), and [add-form](screens/add-form.md), [gift](screens/gift.md), [item](screens/item.md).

### Screens read a local copy

- The app keeps a local copy of everything the user can see, in one database. Screens read only that copy. The API only feeds it.
- At launch, screens show what is saved at once, and a sync updates it under them, with no spinner over saved data.
- **When the instance can't be reached**, every screen shows what is saved, under the line "Can't reach {address}", which blocks nothing. A page with no rows yet shows the unreachable state with Try again, never an empty state.
- The app never says how old the data is. A row that went away on the server stays until the next successful sync removes it. A tap on it meanwhile gives the one "not found" page.
- The copy can be dropped and rebuilt at any time, an app update included. The unsent changes cannot.

### What the copy holds

- Everything a `GET` shows this user: people (summaries, and full records where allowed), lists and their recipients, items and store links, their gifts (Giving, Given, Received, and a parent's Received for a child), occasions, groups, invitations, and the blocked stores for the admin.
- The first sync after sign-in fetches all of it: Home's data first, then the user's own lists, then everyone else's. Screens fill as rows arrive.
- It never holds sessions or passkeys. The Sign-in and devices screen fetches them each time it opens, because an old answer there is a risk: a person who checks whether a lost device is still signed in must see the truth. With no connection, that screen shows no list.
- It is family-sized, a few megabytes, with no limit and no pruning. Given and Received keep their whole history. Images are not in it.

### Unsent changes

- Most writes are **unsent changes**. Each one is saved with an ID, applied to the copy at once (so every window shows it), and sent in order when the instance answers. It stays over the pulled rows until the server accepts it.
- These writes are unsent changes:
  - mark bought
  - edits to items, lists, profiles, and gifts (note, from label, occasion)
  - deletes, and unclaim
  - lowering a gift's quantity
  - move and reorder
  - acknowledge, and accept or decline an invitation
  - creates: an item filled in by hand, a list, an occasion, an invitation, an image upload, and Add again
- Each create carries its own `Idempotency-Key`, so a resend after a lost answer can't make it twice.
- A create that later changes refer to gets a local stand-in ID. When the create's answer comes, the app puts the server's ID in its place.
- A late refusal rolls the change back in the copy, and shows once (see [Late refusals](#late-refusals)).
- Sign-out and the API's own 401 discard every unsent change. A write in flight is abandoned, and its answer is never written into a cleared database.
- An answer in flight wins over a pull for the same thing. After it, the server is the authority again.

### Claims are online only

- **A claim, and raising a gift's quantity, are never unsent changes.** Raising the quantity is a claim too: it can fail with 409 `item_fully_claimed`.
- The button waits for the server's answer. With no connection, it says "Can't reach {address}".
- A giver must never act on a claim that the server has not granted. A claim made offline and refused later is a double gift. No idempotency key changes this.
- Search needs the instance by nature (section 4).

### Other writes that wait for the server

These writes are never unsent changes either. Each one changes what other people see or can do, or can't be undone on the device. The button waits for the server's answer. With no connection, it says "Can't reach {address}", and nothing changes.

- restore ("I didn't get this"): it hides the gift from the person who tapped it, so a later refusal has nothing to roll back to
- the admin's writes: New user, parent links, deactivate and reactivate, delete a user, groups, shared occasions, and blocked stores
- making a login link, revoking a session, and deleting or renaming a passkey: a revoke that waits offline gives a false sense that a lost device is locked out
- confirming the profile at the profile gate
- asking to delete an account, and cancelling that request
- adding a store link to an item, and Refresh prices: the server reads the store's page during the request, and can refuse it
- leaving a list, and making a child leave: the device can't know what the list then shows until it syncs

### No If-Match

- No write sends `If-Match`. Each change is a merge patch of only the fields changed. The server applies it to its current state, and the last writer wins for each field.
- The server's `ETag` covers what each caller sees, so it changes for reasons that have nothing to do with the edit. For example, a claim changes a parent's `ETag` on a child's item. `If-Match` then fails for no real conflict, more so for a change that waited offline.
- Each row keeps its version, to skip writes that change nothing, and to send as `If-None-Match` when it fetches.

### When the app syncs

A sync sends the unsent changes, then pulls. It runs:

- each time the app comes to the foreground, and on each network change
- on pull to refresh, on any screen (it syncs everything)
- every 60 seconds while any window is in the foreground and the instance answers (the timer stops while the instance is unreachable)
- once when the last unsent change is sent
- at once when the share extension says that it added an item
- in background app refresh: the unsent changes, a pull, then the reminders (section 8) and the widget's file are made again from the copy

Opening a page fetches nothing of its own, except Sign-in and devices (see [What the copy holds](#what-the-copy-holds)). The app never shows "Syncing".

### Images

- Images stay out of the database. The instance's images load with the bearer token, through an image cache of the session's own (about 32 MB in memory and 512 MB on disk), in a folder for this instance and user.
- The token goes only to the instance address. A store's `image_url` loads with no token, through the system's default cache.
- After a sync, the app fetches each item's primary image and each avatar not yet in the cache, but only on a network that is neither expensive nor constrained. Other images load when they show.
- An image that the user just uploaded goes into the cache under its new address.
- With no connection and no cached image, the screen shows the item's person-color tile (section 12), with no broken-image mark.
- Sign-out, the API's own 401, and a fresh install delete the folder.

**Provisional.** The cache sizes.

### The widget's file

- The app is the only writer. After every successful sync, it replaces a small JSON file in the shared container, in one atomic write. The file is named for the instance and the user.
- It holds the occasions in the next 60 days: the ID, kind, name, the person's name and user ID (for their color), and `next_date`. It holds nothing about lists, items, or gifts.
- The widget never calls the API. It makes one timeline entry for each local midnight. The app reloads the widget's timelines only when the file's content changed, and at sign-in and sign-out.
- The widget shows no photos in the first release.
- When signed out, or after the API's own 401, the app deletes the file.

**Provisional.** Plain default: the next occasions with their countdown, and initials in the person's color, in the small and medium Home Screen sizes and the Lock Screen sizes.

### Where the database lives

- One database file for each instance and user, in the app's own Application Support folder (not Caches, because the unsent changes must survive). It is left out of backups, and uses iOS's default file protection, so background refresh can sync while the device is locked.
- The copy's tables can be dropped. The unsent changes carry through every migration. An unsent change refers to things by server ID or stand-in ID, never by a local row ID.
- The share extension uses a database in memory, fed from the API (`GET /users/me`, and the lists the user can edit). Nothing is on disk or shared.

### Unsent changes, sign-out, and late refusals

- Rows show no mark for an unsent change.
- While unsent changes wait and the instance is unreachable, the "Can't reach" line adds "{n} changes will be sent when it's back."
- Unsent changes never expire.
- Sign out first tries to send them (section 2).

#### Late refusals

A late refusal shows once, the next time a window comes to the foreground.

**Provisional.** Plain default: one system alert, "Some changes couldn't be saved", that lists "{what}: {reason}", with the reason in the app's words for the error code.

## 11. Diagnostics

Relies on nothing on the server: the server never sees diagnostics. See [ADR 0008](adr/0008-diagnostics-go-to-sentry-on-by-default-with-notice-and-send-only-what-the-app-names.md) and the [privacy policy](../PRIVACY.md).

Screens: [share-diagnostics](screens/share-diagnostics.md), [signed-out](screens/signed-out.md).

### What may be sent

- Diagnostics go to Sentry, in its EU region. Everything sent is a case of one event type, built from a closed vocabulary. There are no free-form strings. An error goes as its domain and code, never as its message.
- **No family content, ever:** no titles, notes, links, images, names, birthdays, gift fields, or claim state, in events, breadcrumbs, or attachments.
- Every feature of the Sentry SDK is off unless it is turned on on purpose. There is no session replay, no screenshots, no view hierarchy, no user, no IP address, no console logs, and no automatic network or UI breadcrumbs.
- The diagnostics ID is the app's own random ID, one for each device. It is never the user ID, the server's session ID, or anything the instance knows.
- A request is reported only by its method and path template, from an allow list, such as `PATCH /items/{id}`. Never the host, the instance address, the query, the headers, or a body.
- A scrubber is the second net. It strips tokens, login links, hosts, and anything shaped like an address, from every event and breadcrumb.

### What the SDK reports

- **On:** crashes, which include the out-of-memory and watchdog terminations that the SDK finds. App hangs are reported only while the app is in the foreground.
- **Off in the first release:** performance tracing, profiling, metrics, and logs.
- TestFlight and App Store builds send the same set. An environment tag tells them apart.

### The app's own events

Every new error type picks its side: captured, a breadcrumb, or never.

- **Captured** (the app's own faults, by code only):
  - the local database will not open
  - a migration drops the copy
  - a response that the client can't decode (the path template and the key path that failed, never a value)
  - an unsent change refused late, or any 400 or 422 refusal of a write that the app sent (the method, the path template, and the server's error code, never the body)
  - an error code that is not in the app's list (the code only)
- **Never captured:** unreachable, offline, timed out, cancelled, the API's own 401, a 404 or 410 for something deleted elsewhere, a version block, and a server 5xx. A 5xx is the operator's server, not the app's fault.
- **Breadcrumbs, typed and made by the app only:**
  - one for each request (the method, the path template, and the status class)
  - the start and outcome of each sync
  - each change of the scene's phase
  - the place opened, named by its kind ("list page", "add form"), never by what it shows
- **A tag on every event:** the instance's Wishbone version, from `GET /health`.
- Diagnostics never record support: no event or breadcrumb for a tap on the support row or for opening the link.

### On by default, for each device, after a notice

- Diagnostics are on by default, for each device. The choice is not for each user, so it survives sign-out and a change of user.
- The SDK stays off until the notice has been shown.
- Turning diagnostics off deletes anything not yet sent, and the diagnostics ID, and sends nothing more, not even a "turned off" event. Turning them on again makes a new ID.
- The basis is notice plus an easy way to withdraw. Opt-in means far fewer reports, and one more step before a family member reaches their list.

### The notice and the switch

- **The notice** is one line at the foot of the signed-out screen, the first screen of a fresh install. The SDK starts only after that screen has shown. The line opens the Share diagnostics screen as a sheet, so a person can turn diagnostics off before anything is sent.
- **The Settings row "Share diagnostics"** pushes the same screen. It holds:
  - the switch
  - a short paragraph on what is sent (crash and fault reports, the app and Wishbone versions, the device model, and the iOS version), and what never is (anything from the family's lists, names, birthdays, and the instance's address)
  - a link to the privacy policy (`WISHBONE_PRIVACY_URL`)
- The operator gets no switch for the whole instance. Each person's own switch is the control. The operator learns about diagnostics from the README and the privacy policy.

**Provisional.** Plain default: a system form with a toggle, a footer paragraph, and a link. The draft notice is "If Wishbone crashes, it sends a report to its developer, never anything from your family's lists. Diagnostics settings".

### The extensions send nothing

- Neither the share extension nor the widget extension links the diagnostics module. The share extension is short-lived, with a memory limit of about 120 MB, and starting the SDK costs every share.
- Their crashes come from Apple's reports, in the Xcode Organizer.

### Builds that send nothing

- The repo's `Config/Shared.xcconfig` holds an empty DSN. With an empty DSN, diagnostics never start, in any build. So CI and forks send nothing.
- The real DSN is only in the maintainer's own `Config/Local.xcconfig`, which git ignores.
- A Debug build sends only when it is launched with an explicit argument, so the maintainer's own runs and tests send nothing.

## 12. Look, words, accessibility and languages

Relies on the server spec's [Design](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#design) as background only: the app and the web share a principle, not a look.

Screens: every spec in [`docs/screens/`](screens/README.md), and the [words for error codes](screens/README.md#words-for-error-codes).

### The look

- Native iOS: the system font with Dynamic Type, SF Symbols, and system lists and controls.
- Liquid Glass only where the system puts it (the tab bar, toolbars, and sheets). The app adds no glass to content.
- No decoration. Product images, names, and dates are what is worth looking at.
- Delight comes from native behavior: drag and drop, widgets, haptics, and the system's transitions.
- The app does not use the web app's typeface or palette.
- The app follows the system's light or dark mode, with no switch of its own.
- Haptics: system feedback only, on success (an item added, a claim made) and on a drop. None on plain taps.

**Provisional.** Every look in the app. Plain default: as built plain (see [How to read this spec](#placement-is-decided-presentation-is-provisional)).

### One accent color

- One accent color for the whole app (the asset catalog's `AccentColor`): buttons, links, the selected tab, toggles, the widget's accent, and the tab bar's plus.
- There is no second brand color. Person colors are not an accent.

**Provisional.** Plain default: Steel `#2b3a47` in light mode, and lime `#ddeb5a` in dark mode, with `#16202a` for text on a lime fill.

### A color for each person

- Each person gets a color that the app makes from the user's ID, from a fixed palette of system colors. It is the same on every device, with no server change. The web app shows no person color, and a client owns its layout.
- The color is used for:
  - the person's initials avatar, when they have no photo
  - the tile behind an item with no image, on a list they are a recipient of (a list with several recipients takes its first recipient's color)
  - the countdown card, when the occasion is theirs
- Item images and avatar photos show as they are, with no tint and no overlay.
- Color never carries meaning alone. A name always sits beside the avatar or the tile.
- The palette leaves out colors on which white initials fail the contrast rule, such as yellow.

**Provisional.** The palette, the gradients, the tile style, and the card. Plain default: soft gradient initials avatars, soft tinted item tiles with a colored symbol, and a gradient countdown card.

### The app icon

The plain wishbone shape, made in Icon Composer as a layered icon with light, dark, tinted, and clear appearances. The icon is not under the MPL-2.0 (see [TRADEMARKS.md](../TRADEMARKS.md)).

**Provisional.** Plain default: a white wishbone on a colorful background.

### Words

- Plain words, while the look is colorful: short sentences, no exclamation marks, no emoji, and no "Oops".
- Every error and every empty state says what happened and what to do next.
- The app uses the web app's words for the same actions ("I'll get this", "I won't get this", "I didn't get this", "Good to know"), so a family that uses both sees one vocabulary. The app has words of its own only where it does something the web app doesn't.
- Errors map from the API's error codes to the app's own words, never to the server's `detail` text. For a code that the app doesn't know, it shows `detail`, as the server spec requires.
- The UI calls the operator "the person who runs Wishbone".
- The app calls support a coffee or a tip, never a gift (a Wishbone term) and never a donation (a charity word). It always says that a tip unlocks nothing.

### Web links

- Every web link opens in the default browser: store links, links in markdown, the support row, Source code, the privacy policy, and the link on running an instance.
- The app has no in-app browser and no web view. This keeps the App Store age rating at 4+, because unrestricted web access raises it.

### Accessibility

The first release claims all seven of the App Store's accessibility labels, on iPhone and iPad: VoiceOver, Voice Control, Larger Text, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast, and Reduced Motion. The share extension is a common task, and it is held to them too. A label is claimed only after its common tasks pass.

- **Larger Text:** every string uses a text style, and scales to the largest accessibility size. At accessibility sizes, rows that sit side by side stack. Names, prices, and dates are never cut short.
- **VoiceOver:** every control has a label. An item row is one element, with its actions (claim, move, open) as accessibility actions. Avatars read by name. Reorder uses the system's move up and move down actions.
- **Voice Control:** a control's accessibility label matches its visible words.
- **Nothing by gesture alone:** every swipe action and every drag also has a button or a menu item (Move to…, Reorder).
- **Contrast:** 4.5:1 for text, and 3:1 for large text and controls, in light, dark, and Increase Contrast. This covers the accent and the person palette.
- **Reduced Motion and Reduce Transparency:** only the system's motion and glass, which follow both settings. No custom motion.
- **Tap targets** are at least 44 points.

### Languages

- The app is in US English only, as the server's spec writes it ("favorite"). Its App Store listing is in English only.
- Every string is in a String Catalog from the first commit, ready to translate. Code uses `LocalizedStringResource` or `String(localized:)`, and assembles no text.
- A name inside a sentence is an argument to a whole string: "Edit %@'s profile" is one entry. Code never adds "'s".
- Counts use the catalog's plural variants. Dates, prices, and numbers use formatters in the device's locale. A price keeps the server's currency.
- Layout uses leading and trailing, never left and right, so that a right-to-left language can work later.
