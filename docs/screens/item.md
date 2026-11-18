# An item's page

## Purpose

One item in full. A giver decides here and claims it. A user who can edit the list changes it here. The server's rules are in [Items](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#items) and [While a gift is open](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#while-a-gift-is-open).

## How you get here, and where you go

- **Pushed** from its row on a list's page or a user's page, and from a gift's page.
- **Pushed** from the "Added" row on the Add screen, and from the duplicate hint in the add form.
- A link from outside can open it on top of Home.
- The list's name pushes the [list's page](list.md). A name pushes that [user's page](user.md).
- "You claimed 1 for Christmas" pushes that [gift's page](gift.md).
- **Edit** and **Move to…** open sheets. A store link opens in the browser.
- The item's address has no list, so the page stays when the item moves. It then shows the new list's name.

## Content

From top to bottom:

1. The images, the primary image first.
2. The title, and the price or the price range.
3. The list's name and its recipients.
4. **For a giver:** how many are still wanted, then **I'll get this**. After a claim, one line for each of the user's own open gifts on the item takes the button's place.
5. The notes.
6. The store links, each with its store, its price, and when the price was read. A giver sees the lowest price first. A user who can edit sees them in the order added.
7. "Added by {name}". It does not show when that user is the list's only recipient, or was deleted.
8. **For a user who can edit:** how many are wanted, or unlimited, then the edit controls.

**Provisional.** Plain default: a system list. The images are a row that pages sideways, the title is large text under it, and each part is a section. An item with no image has a tile in its recipient's person color. Edit is a toolbar button, and Move to…, Copy link, and Delete are in the toolbar's menu.

### Edit item

A sheet with the fields that the add form has, and the ones it leaves out:

1. **Photos**: up to 5, with Take a photo, Choose a photo, Remove, and a choice of the primary image.
2. **Title**, **Price**, and **Up to**. A price can be cleared.
3. **How many**: a number, or **Always wanted** for an unlimited item.
4. **Notes**.
5. **Store links**: each with its price to edit and Remove, and **Add link**, which takes a pasted web address and reads it.

**Provisional.** Plain default: a system form in a sheet, in the order above.

## States

- **Claiming:** I'll get this shows progress, and waits for the server's answer.
- **Claimed:** the line "You claimed 1 for Christmas" shows in place of I'll get this. The button shows only while the giver has no open gift on the item, because the server allows one gift for each item and occasion.
- **Someone else got it** (409 `item_fully_claimed`): the line shows in place. The item leaves the giver's lists at the next sync.
- **Can't reach {address}**, on a claim: the line shows by the button, and nothing is claimed.
- **An unlimited item:** "Always wanted". It never leaves a giver's list.
- **Add link over the hourly limit:** nothing is added, and the words for `rate_limited` show.
- **Add link to a blocked store:** nothing is added, and the words for `store_blocked` show.
- **Gone:** a deleted item, or one that a giver can no longer see, shows the [not-found](not-found.md) page.
- **Can't reach, and the rest:** as every screen. Edits, Move to…, and Delete are unsent changes. Add link and Refresh prices need the instance.

## Windows

- **Narrow and wide:** one column of readable width. In a wide window, the images sit beside the title and the price.
- **Several windows:** a change shows in every window. An item has no Open in New Window: only a list and a person do.
- **Dragging out:** the item can be dragged from its title to another app, with its first store link and its title.
- **A drop target:** none.

**Provisional.** The side-by-side layout in a wide window. Plain default: the one-column layout at every size.

## Actions

| Action | Route | What it does |
|---|---|---|
| I'll get this | A button, from `can_claim`, while `my_claimed_quantity` is 0. Also in the row's context menu on a list | Claims one, for the next occasion, at once. No sheet and no confirmation come first |
| Open my gift | A tap on "You claimed 1 for Christmas" | Pushes the gift's page. The giver raises how many there, changes the occasion, the from label, and the note, and can get another for a different occasion |
| Open a store link | A tap on its row | Opens the store's page in the browser |
| Copy link | The toolbar's menu, and the row's context menu, when the item has a store link | Copies the first store link, as a drag to another app carries it |
| Edit | A toolbar button, from `can_edit` | Opens the Edit item sheet |
| Move to… | The toolbar's menu, from `can_edit`, when another list can take it | Opens a picker of the lists the user can edit, each with its recipients' names. The item goes to the end |
| Refresh prices | The toolbar's menu, from `can_refresh_prices` | Reads each store link again |
| Delete | The toolbar's menu, from `can_delete` | Deletes the item, after a confirmation |
| Add link, Remove, edit a price | In the Edit item sheet | Changes the store links |

- A claim made here takes the server's defaults: a quantity of 1, and the soonest occasion that the giver can pick. The line that follows names the occasion, so a wrong one is seen at once.
- The Delete confirmation is the same whether or not the item is claimed.

## Words

Decided, as the web app has them: "I'll get this", "{n} of {m} still wanted", "Always wanted", "You claimed 1 for Christmas", "Someone else just got this", "Added by Mom", and "Add link".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| A range | "$20 to $35" |
| A store link | "{store} · $24.99 · read Nov 3", "{store} · no price" |
| How many | "Wants {n}", "Always wanted" |
| Claim, can't reach | "Can't reach {address}. Nothing was claimed." |
| A claim with no named occasion | "You claimed 1 · hidden until Mar 4" |
| Edit, title | "Edit item" |
| Edit, how many | "How many", with the switch "Always wanted" |
| Add link, prompt | "Paste a store's web address" |
| Delete, confirmation | "Delete {title}? This can't be undone.", with the button "Delete {title}" |
| Move to…, title | "Move to…" |
| Refresh prices, done | "Prices checked." |

## Accessibility

- The images are one element that reads "Photo {n} of {m}", and is adjustable.
- The claim result is announced: the gift line, or "Someone else just got this".
- A store link reads its store, its price, and "opens in browser".
- I'll get this, when it is disabled while it waits, says "Claiming".
- At the largest text sizes, a store link's price moves under the store's name.

## Secrecy

- **A giver** sees how many are still wanted, and their own gifts on the item. They never see who else claimed.
- **A recipient** sees no claim state, no gift lines, and no I'll get this.
- **A parent who is not a recipient** sees the claim state and the edit controls together.
- The Delete and Move to… routes show no words about gifts, for anyone.
- Copy link and a drag out carry only the first store link and the title.
