# The share extension

## Purpose

To add an item from another app: a store's page in Safari, a link in a message, or a photo. It shows the same [add form](add-form.md) as the app. The rules are in the spec: [The share extension](../spec.md#the-share-extension) and [When search can't fill in the form](../spec.md#when-search-cant-fill-in-the-form).

## What it shows

- The add form, filled in from one shared thing, with **Cancel** and **Add**.
- **Add to**, with every list that the session's user can edit, starting on their primary list. A list for someone else carries its recipients' names.
- A progress line while a link or a photo is read, with **Fill it in myself**.
- The duplicate hint, as the app shows it, without a link to the item.

It takes one link, one text, or one image for each share. Wishbone is not offered when several things are shared.

**Provisional.** Plain default: the add form as a system form, in the system's share sheet.

## What it never shows

- Claim state, or anything about a gift.
- The items of a list, apart from the one title in the duplicate hint.
- The support row, or anything about diagnostics. The extension sends no diagnostics.
- Anything from the app's local copy. The extension reads the user and their lists from the API, into memory, and keeps nothing.

## Actions

| Action | Route | What it does |
|---|---|---|
| Add | The main button | Uploads the images, adds the item, tells the app to sync, and closes |
| Cancel | A button | Closes, and keeps nothing |
| Fill it in myself | A button, while a link or a photo is read | Opens the form with what was shared, and nothing else |
| Add it without the link | A button, after a blocked store | Opens a blank form |
| Try again | A button, when the instance can't be reached | Tries the search, or the add, again |
| Copy the link | A button, when the instance can't be reached | Copies the shared link, to add it later from the Add screen |

## States

- **Signed out:** "Sign in to Wishbone first." with Cancel.
- **A blocked store**, **over the hourly limit**, and **nothing found:** as the add form has them.
- **Can't reach {address}:** the line, with Try again and Copy the link. The extension has no queue, so nothing is sent later.
- **The app is too old** (410 `api_version_removed`): "Open Wishbone".
- **The API's own 401:** the extension deletes the Keychain item, and shows the signed-out state. The app clears the rest when it next runs.
- **A fresh install, before the app was opened:** the signed-out state.
- **A shared thing that Wishbone can't use:** a message, with Cancel.

**Provisional.** These words are drafts: "Reading {store}…", "Wishbone can't add this. Share a link or some text.", and the label "Copy the link". The line names one photo too once the extension takes one. "Sign in to Wishbone first." and "Open Wishbone" are decided in the spec.

The extension is held to the same accessibility rules as the app: every control has a label, the text scales, and nothing is only a gesture.
