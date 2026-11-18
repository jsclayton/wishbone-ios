# The add form

## Purpose

The user checks what search found, changes it, and adds the item. Nothing is saved until they tap Add. The app and the share extension use this one form. The rules are in the spec: [What the add form holds](../spec.md#what-the-add-form-holds), [Which list](../spec.md#which-list), [When search can't fill in the form](../spec.md#when-search-cant-fill-in-the-form), and [After Add](../spec.md#after-add).

## How you get here, and where you go

- **Pushed** onto the [Add screen](add.md) after a search, in the place or in a list's sheet. Back returns to the field.
- **In the share extension**, as its whole screen, with Cancel and Add (see [share-extension](share-extension.md)).
- **From Add again**, on a given gift: the form opens in a sheet, filled from the gift (see [gift](gift.md)).
- **From a drop** of a link, text, or an image from another app.
- After Add, see [After Add](../spec.md#after-add). On the Add screen, the duplicate hint pushes that item's page. In a sheet, and in the share extension, the hint opens nothing.

## Content

In order:

1. A note, when search did not fill in the form.
2. **Images** that the search found, to tick. The first ticked one is the primary image. A photo that the user took or chose is the item's image.
3. **Title** (required).
4. **Price**, with an optional "up to" price for a range.
5. **Store link**: the store's name, when the search came from a link.
6. **Add to**: the list. Hidden when the user can edit only one list, and when the form is fixed to a list. It starts on the primary list, or on the gift's list for Add again. The lists are in the Lists tab's order, with a child's lists under the child's name.
7. **Options**, when the page lists them: one choice for each, set to what the link selected, or "Not sure".
8. **Notes**, at most 2000 characters.
9. The duplicate hint, when the target list has the same link or the same title.
10. **Add**.

Quantity, more store links, and more photos are on the [item's page](item.md), after the add.

**Provisional.** Plain default: a system form, in the order above. Add is in the toolbar.

## States

- **Filled in** by a search.
- **Over the hourly limit:** the link is kept, the other fields are blank, and the note says why.
- **Nothing found:** the form has what the input gave, and the note says so. A photo gets the title "Photo from {date}".
- **With only what the user gave,** from "Fill it in myself": a link as the store link, typed words as the title, or a photo as the image.
- **Blank,** from "Add it without the link".
- **Adding:** Add shows progress while the images upload and the item is added.
- **The add is refused with `store_blocked`:** the form stays open with that line, and the link is dropped from it.
- **An image can't be saved** (`image_fetch_failed`): the item is added without that image, and a line says so.
- **Can't reach {address}:**
  - In the app, an add filled in by hand is an unsent change. It shows on its list at once.
  - An add that a search filled in stays open with the line, and Add tries again.
  - In the share extension, see [share-extension](share-extension.md).
- **Notes were cut:** a line under Notes says that the text was cut to 2000 characters.

## Windows

- The form keeps a readable width in a wide window and in a sheet.
- A window asks before it closes while the form has typed changes (see [Closing a window](../spec.md#closing-a-window)). Back from a changed form asks the same question.
- The form is not restored when a window is restored.

## Actions

| Action | Route | What it does |
|---|---|---|
| Tick or clear an image | A tap on the image | Chooses which images the item gets. The first ticked is the primary image |
| Pick the list | The Add to row | Pushes a picker of the lists the user can edit |
| Pick an option | The option's row | A menu of the page's values, and "Not sure" |
| Open the duplicate | The hint, on the Add screen only | Pushes that item's page. In a sheet, and in the share extension, the hint is text and not a link |
| Add | The toolbar's main button, and Return | Uploads the images, then adds the item |
| Back, or Cancel | The toolbar | Leaves the form, after the confirmation when it has changes |

## Words

Decided in the spec: "Add to", "Not sure", "Already on this list: {title}", "Photo from {date}", and the saved option line "Size: M".

**Provisional.** These are drafts. The first three are in the spec, marked.

| Where | Words |
|---|---|
| Over the limit | "This link wasn't read: you've read 30 links and photos in the last hour. Fill it in yourself, or try again later." |
| Nothing found, a link | "Nothing could be read from {store}. Fill it in yourself." |
| Blocked on add | "Links from {store} are blocked on this Wishbone." |
| Nothing found, a photo | "Nothing could be read from your photo. Give it a title." |
| Title | "Add item" |
| Fields | "Title", "Price", "Up to", "Store", "Notes" |
| Title is empty | "Give the item a title." |
| Notes were cut | "Your notes were cut to 2000 characters." |
| A list for someone else, in Add to | "Lego · Emma" |
| Leave with changes | "Discard this item?", with "Discard" and "Keep editing" |

## Accessibility

- Each image is a button that reads "Photo {n} of {m}", "selected" or "not selected", and "primary" for the first.
- Add is disabled, and says why, until the form has a title.
- The note at the top is the first element, so VoiceOver reads why the form is blank before the fields.
- The share extension is held to the same rules as the app.
- At the largest text sizes, Price and Up to stack.

## Secrecy

- Add to lists only the lists that the user can edit. A list for someone else carries its recipients' names.
- The duplicate hint checks only what the user sees on the target list. A parent who is a giver on a child's list gets no hint for a fully claimed item, because the server hides it. The hint never says why it is silent.
- The form shows no claim state.
