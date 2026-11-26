# The Add screen

## Purpose

The start of adding an item: paste a link, type what you want, or use a photo. The server's glossary calls this act **search**. The rules are in the spec: [Adding: the plus at the end of the tab bar](../spec.md#adding-the-plus-at-the-end-of-the-tab-bar), [The empty Add screen](../spec.md#the-empty-add-screen), [When search can't fill in the form](../spec.md#when-search-cant-fill-in-the-form), [When the instance can't be reached](../spec.md#when-the-instance-cant-be-reached), and [After Add](../spec.md#after-add).

## How you get here, and where you go

- **A place:** the plus at the end of the tab bar, and Command-N. The "Add item" control opens it too. It starts on the user's primary list.
- **A sheet:** a list's "Add item" row opens the same screen in a sheet, fixed to that list (see [list](list.md)).
- A search pushes the [add form](add-form.md). Back returns here, with the text still in the field.
- After an add from the place, the screen comes back with the field empty and the "Added" row. After an add from the sheet, the sheet closes.

## Content

1. In the sheet, a line that names the list.
2. The search field.
3. The "Added {title} to {list}" row, after an add, until the user leaves the screen.
4. The three ways in: **Paste**, **Take a photo**, and **Choose a photo**.

**Provisional.** Plain default: the system search field, and the three ways in as rows of a system list under it.

## States

- **Empty:** the field and the three rows.
- **Reading a link or a photo:** a progress line, with **Fill it in myself**, which stops the wait and opens the form with what the user gave.
- **A blocked store:** no form opens. A message, with **Add it without the link**.
- **Can't reach {address}:** the line, with Try again and **Fill it in myself**. The text stays in the field.
- **Camera denied:** Take a photo says why, and offers Open Settings. When a restriction, such as Screen Time, turns the camera off, it says so, with no Open Settings. A device with no camera has no Take a photo row.
- **Over the hourly limit**, and **nothing found:** the form opens with a note. Those states are in [add-form](add-form.md).

## Windows

- **Narrow:** the field takes the tab bar's place, above the keyboard.
- **Wide:** the field is in the toolbar, and the screen is a place in the sidebar.
- **Several windows:** each window has its own Add screen and its own text.
- **The sheet:** a swipe down closes it, but not while the pushed form has typed changes. Then Back asks "Discard this item?", as it does on the place.
- **A drop target:** the screen takes one link, one text, or one image from another app, and opens the form filled in. A drop of several is refused (see [A drop from another app starts an add](../spec.md#a-drop-from-another-app-starts-an-add)). It takes no item from inside the app.

## Actions

| Action | Route | What it does |
|---|---|---|
| Search | The keyboard's Search key, or Return | Reads a link, or takes the words as typed, and pushes the form |
| Paste | The system paste button | Searches the clipboard's content at once |
| Take a photo | A row | Opens the system camera for one photo, then searches it |
| Choose a photo | A row | Opens the system photo picker for one photo, then searches it |
| Fill it in myself | A button, while reading or when unreachable | Opens the form with what the user gave: the link, the words, or the photo |
| Add it without the link | A button, after a blocked store | Opens a blank form |
| Open the added item | The "Added" row | Pushes the item's page |
| Cancel | A button, in the sheet only | Closes the sheet |

## Words

Decided in the spec: the prompt "Paste a link or type what you want", "Paste", "Take a photo", "Choose a photo", "Fill it in myself", "Add it without the link", "Added {title} to {list}", and "Can't reach {address}". The paste button's word, "Paste", is the system's, not the app's.

**Provisional.** These are drafts: "Links from {store} are blocked on this Wishbone." (in the spec, marked), and:

| Where | Words |
|---|---|
| Title | "Add" |
| Reading a link | "Reading {store}…" |
| Reading a photo | "Looking at your photo…" |
| In the sheet | "Adding to {list}" |
| Camera denied | "Wishbone needs the camera to take a photo. You can turn it on in Settings, or choose a photo." |
| Camera turned off by a restriction | "The camera is turned off on this device, so Wishbone can't take a photo. Choose a photo." |

## Accessibility

- In the sheet, the line that names the list is the first element.
- The field's label is its prompt. The system's magnifying glass is decoration.
- The "Added" row is announced when it appears.
- The progress line is announced, and Fill it in myself is the next element.
- Dropping onto the screen has a way without a drag: Paste, and Choose a photo.

## Secrecy

None. The screen shows nothing from a list. In the sheet for a child's list, the line names the list and its recipient, as [Whose list: name the recipient](../spec.md#whose-list-name-the-recipient) says.
