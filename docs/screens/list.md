# A list's page

## Purpose

One list and its items. A giver reads it and claims. A recipient, or a recipient's parent, edits it. The server's rules are in [Lists](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#lists) and [Items](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#items). The app's rules are in [Whose list: name the recipient](../spec.md#whose-list-name-the-recipient) and [section 9](../spec.md#9-windows-dragging-and-keeping-in-step) of the spec.

## How you get here, and where you go

- **Pushed** from the Lists tab, a user's Other lists, the sidebar, an invitation, an item's page, and a gift's page.
- A reminder or a widget tap for the user's own occasion opens their primary list's page on top of Home.
- An item's row pushes the [item's page](item.md). A recipient's name pushes their [user's page](user.md).
- **Add item** opens the [Add screen](add.md) in a sheet, fixed to this list.
- **Edit list**, **Invite**, and **Move to…** open sheets.
- After the user leaves or deletes the list, the page closes in the window that did it, and that window shows what was under it.

## Content

From top to bottom:

1. A pending invitation to this list, for the user or for one of their children, with Accept and Decline.
2. The list's name, and the "For {names}" line with its recipients' names and avatars.
3. The description, as markdown, when the list has one.
4. For a viewer who can edit the list and is also a giver, the line "You see what's been claimed here. Fully claimed items don't show."
5. The items, in the order that the Sort menu sets. Each row shows the primary image, the title, and the price. For a giver, it also shows how many are still wanted, and "You claimed {n}".
6. An **Add item** row, from `can_edit`.
7. For a recipient: the list's other pending invitations, each with who invited them and Withdraw, and **Invite**.
8. **Leave**, **Make {child} leave**, and **Delete list**, from their `can_*` fields.

**Provisional.** Plain default: a system list. The name is the navigation title, the recipients and the description are the first section, and the items are rows with the image at the leading edge. An item with no image has a tile in its recipient's person color. Edit list, Sort, and Open in New Window are in the toolbar's menu, and Reorder is the toolbar's Edit button.

### Edit list

A sheet with **Name** and **Description**.

### Invite

A sheet with the users that the user can invite, with names and avatars, by name. A tap invites that user at once, and the sheet stays open for another.

## States

- **No items yet:** the page says so. For a viewer who can edit, it points to Add item.
- **Sorted by price or by newest:** Reorder is not offered, and a drop goes to the end.
- **A deactivated recipient:** "Deactivated" beside their name, for a viewer who gets it. A parent who edits only through that child sees no edit controls.
- **Leaving a list that the leaver can still see:** the confirmation adds a warning. It shows when that user's row in `GET /lists/{id}/recipients` has `sees_list_after_leaving` set to `true`, for Leave and for Make {child} leave.
- **Nobody to invite:** the Invite sheet says so.
- **A claim is refused:** the words for the code show in place (see [item](item.md)).
- **A move is refused:** the item goes back, and an alert says why (see [What the windows show after a drop](../spec.md#what-the-windows-show-after-a-drop)).
- **Gone:** a list that was deleted, or that the viewer left and can no longer see, shows the [not-found](not-found.md) page in every window that shows it.
- **Can't reach, and the rest:** as every screen. Edits to the list and its items, Invite, Withdraw, and Delete list are unsent changes. I'll get this, Leave, and Make {child} leave wait for the server.

## Windows

- **Narrow and wide:** one column of readable width.
- **Several windows:** the list's row and the page have Open in New Window. A drop shows at once in every window that shows either list.
- **A drop target**, when the viewer can edit the list:
  - An item from another list that the viewer can edit lands at the drop point. This is a move.
  - An item from this list is a reorder, in List order only.
  - One link, text, or image from another app opens the add form filled in, with this list set.
  - Anything else is refused, with no highlight. A second item can't join a drag.
- **Dragging out:** any item can be dragged to another app. It carries its first store link and its title, and nothing else (see [Dragging an item out to another app](../spec.md#dragging-an-item-out-to-another-app)).

## Actions

| Action | Route | What it does |
|---|---|---|
| Open an item | A tap on its row | Pushes the item's page |
| I'll get this | An item's context menu, from `can_claim`, while the giver has no open gift on the item. Also on the item's page | Claims one, for the next occasion, at once |
| Move to… | An item's context menu, from the item's `can_edit`, when another list can take it. Also on the item's page | Opens a picker of the lists the viewer can edit. The item goes to the end of the list picked |
| Copy link | An item's context menu, when it has a store link | Copies the first store link |
| Edit, Delete | An item's context menu, from its `can_*` fields. Also on the item's page | As on the item's page |
| Add item | A row under the items | Opens the Add screen in a sheet, fixed to this list |
| Sort | The toolbar's menu | List order, Price, or Newest. The choice belongs to this window and page, and is not saved |
| Reorder | The toolbar's Edit button, in List order, from `can_edit` | The system's edit mode, with handles |
| Edit list | The toolbar's menu, from `can_edit` | Opens the Edit list sheet |
| Invite | A row, from `can_invite` | Opens the Invite sheet |
| Withdraw | A button on a pending invitation, from `can_delete` | Removes it, with no confirmation |
| Accept, Decline | Buttons on the invitation at the top | As on the Lists tab |
| Leave | A row, from `can_leave` | The user leaves, after a confirmation |
| Make {child} leave | A row for each child whose recipient row has `can_delete` | The child leaves, after a confirmation |
| Delete list | A row, from `can_delete` | Deletes the list and its items, after a confirmation |
| Open in New Window | The toolbar's menu, where several windows are allowed | Opens a window with this page on top of Home |

- **Price** sorts lowest first, with items that have no price last. **Newest** sorts by when the item was added.
- No confirmation, and no words about gifts, come before a move or a reorder.
- The words of the Delete and Leave confirmations never depend on the list's gifts.

## Words

Decided, as the web app has them: "For {names}", "{n} of {m} still wanted", "Always wanted", "You claimed {n}", "You see what's been claimed here. Fully claimed items don't show.", "Mom invited you to this list", "Grandpa · invited by Mom", "Leave Our house", "Delete Cousins and its items", and "You'll see what's been claimed on this list, including gifts for you."

In the spec, marked as drafts there: "Make Emma leave Our house", and "Emma will see what's been claimed on this list, including gifts for Emma."

Decided in the spec: "Move to…", "Reorder", "Add item", "Open in New Window".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Sort | "Sort", with "List order", "Price", "Newest" |
| No items, for a giver | "Nothing on this list yet." |
| No items, for someone who can edit | "Nothing here yet. Tap Add item to start the list." |
| Leave, confirmation | "Leave {list}? You can be invited again." |
| Make leave, confirmation | "Make {name} leave {list}? {name} can be invited again." |
| Delete, confirmation | "Delete {list} and its items? This can't be undone." |
| Edit list, title | "Edit list" |
| Invite, title | "Invite to {list}" |
| Nobody to invite | "There's nobody else to invite. You can invite people you can see who aren't on this list." |
| A refused move | "{title} couldn't be moved.", then the words for the code |

## Accessibility

- An item row is one element: the title, the price, then for a giver how many are still wanted and the user's own claim. Its actions are Open, I'll get this, Move to…, Copy link, Edit, and Delete, as allowed.
- Reorder uses the system's move up and move down actions. Move to… is the way to move an item without a drag.
- Each recipient's avatar reads their name. The "For {names}" line is one element.
- A web link in the description reads "opens in browser".
- At the largest text sizes, an item's image sits above its text, and the price moves under the title.

## Secrecy

- **A giver** sees how many of each item are still wanted, and their own claims. A fully claimed item is not there for them at all.
- **A recipient** sees none of it. Their rows have no still-wanted line and no I'll get this.
- **A parent who is not a recipient** sees both, with the line that says why items can be missing.
- The page never says who claimed an item.
- No confirmation mentions gifts, because that shows a recipient that something is claimed.
- A dragged-out item, and Copy link, carry no claim state.
