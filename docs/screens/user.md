# A user's page

## Purpose

Everything about one person that a giver needs: what they want, what is good to know, and their other lists. For a parent and for the admin, it is also where they act for that user. The rules are in the spec: [The For {name} part](../spec.md#the-for-name-part), [A deactivated child](../spec.md#a-deactivated-child), [The admin's For {name} part](../spec.md#the-admins-for-name-part), and [Account deletion](../spec.md#account-deletion).

## How you get here, and where you go

- **Pushed** from Home's people, the People page, the sidebar, and any name that links.
- A reminder or a widget tap for a person's birthday or custom occasion opens it on top of Home.
- An item's row pushes the [item's page](item.md). A row in Other lists pushes that [list's page](list.md).
- The For {name} part pushes the [profile](profile.md) screen, [Sign-in and devices](sign-in-and-devices.md), the Received part of [Gifts](gifts.md), the [Delete account](delete-account.md) screen, and Parents (below).
- **The user's own page is this same page.** It shows their own primary list, with no claim state and no For part. It does not switch to the Lists tab. The user's own profile and devices are in [Settings](settings.md).

## Content

From top to bottom:

1. The avatar, the name with the last name, and the birthday. "Deactivated" beside the name, when it applies.
2. A line for a special case, when one applies (see States).
3. **Good to know**, as markdown, when the user has any.
4. **The items of their primary list**, in the page itself. Each row is as on a [list's page](list.md): the image, the title, the price, and, for a giver, how many are still wanted and "You claimed {n}".
5. An **Add item** row, when the viewer can edit that list.
6. **Other lists**: the extra lists that the user is a recipient of, by name, with the same rows as the Lists tab. Hidden when there are none.
7. **For {name}**, when it has a row. The rows and their order are in the spec.

The birthday shows the month and the day, and the age that the user is turning when the birthday has a year.

**Provisional.** Plain default: a system list. The header is the avatar in the person's color with the name under it, each part is a section, and the items are rows with the image at the leading edge.

### Parents

The admin's **Parents** row pushes a screen with the user's parents, each with Remove. **Add parent** opens a picker of every other user who is not already a parent.

**Provisional.** Plain default: a system list, with Add parent in the toolbar.

## States

- **No items yet:** the items part says so. For a viewer who can edit, it points to Add item.
- **A giver sees fewer items than exist:** nothing says so. A fully claimed item is not in the giver's copy.
- **A parent who is not a recipient:** one line above the items, as on a list's page: "You see what's been claimed here. Fully claimed items don't show."
- **A deactivated child**, for a parent: the line about the admin, the items read-only, and a For part with only What {name} received.
- **A deactivated user**, for the admin: the line about reactivating, and the rows Reactivate, Parents, and Delete.
- **A user seen only through the admin's access:** the line that says so. The page has no items, because the server hides the primary list from that access.
- **A deletion request is open:** a line in the For part says who asked, and when.
- **New user, a group didn't take them:** a line names each group that failed (see [new-user](new-user.md)).
- **Gone:** a user the viewer can no longer see shows the [not-found](not-found.md) page.

## Windows

- **Narrow and wide:** one column of readable width.
- **Several windows:** the page can be opened in a new window from wherever its row is. A change to an item shows in every window.
- **A drop target:** the items part behaves as a list's page does. It takes an item from another list that the viewer can edit, at the drop point, and one link, text, or image from another app. The page as a whole is not a target: a person can have several lists.

## Actions

The item rows have the actions of a [list's page](list.md): I'll get this, Open, Move to…, Copy link, Edit, Delete, Sort, and Reorder.

| Action | Route | What it does |
|---|---|---|
| Open a list | A row in Other lists | Pushes the list's page |
| Add item | A row under the items, from the list's `can_edit` | Opens the Add screen in a sheet, fixed to the primary list |
| Edit {name}'s profile | A For row, from `can_edit` | Pushes the profile screen for that user |
| Sign-in and devices | A For row, from `can_make_login_link` or `can_manage_sessions` | Pushes that screen for the user |
| What {name} received | A For row, for a parent | Pushes Received for the child |
| Ask to delete {name}'s account | A For row, for a parent | Pushes the Delete account screen for the child |
| Parents | A For row, from `can_edit_parents` | Pushes Parents |
| Add parent, Remove | On Parents | Links or unlinks, with no confirmation |
| Deactivate {name} | A For row, from `can_deactivate` | Deactivates, after a confirmation |
| Reactivate {name} | A For row, from `can_reactivate` | Reactivates, with no confirmation |
| Delete {name} | A For row, from the server's `can_*` field | Deletes the user, after a confirmation that says what goes and what stays |
| Open in New Window | The toolbar's menu, where several windows are allowed | Opens a window with this page on top of Home |

## Words

Decided in the spec, some marked as drafts there: the For rows, "Deactivated", the deactivated lines for a parent and for the admin, the admin's-access line, the deletion request lines, and "Delete Emma". Decided, as the web app has them: "Good to know", "Other lists", "For {name}", "{n} of {m} still wanted", "Always wanted", "You claimed {n}".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Birthday | "Birthday: March 4", "Turns 9 on March 4" |
| No items, for a giver | "{name} hasn't added anything yet." |
| No items, for someone who can edit | "Nothing here yet. Tap Add item to start the list." |
| Deactivate, confirmation | "Deactivate {name}? Their devices are signed out and their open gifts are released. Only you and their parents see them until you reactivate them.", with the button "Deactivate {name}" |
| Delete, confirmation | "Delete {name}? Lists that are only theirs, and gifts for them alone, are deleted. Gifts they gave stay with the people who got them. This can't be undone.", then "{child} will have no parent." for each such child, with the button "Delete {name}" |
| Parents, title | "{name}'s parents" |
| Parents, empty | "{name} has no parents in Wishbone." |
| A group didn't take a new user | "{name} wasn't added to {group}. Add them from the group's page." |

## Accessibility

- The header is one element: the name, "Deactivated" when it applies, and the birthday.
- Good to know is read as text, and each web link in it reads "opens in browser".
- An item row is one element, with its actions, as on a list's page.
- Each For row names the user in its label, so the row makes sense out of context.
- At the largest text sizes, an item's image sits above its text.

## Secrecy

- **A giver** sees the claim state of the primary list's items: how many are still wanted, and their own claims.
- **The user themself**, and any recipient, sees none of it.
- **A parent who is not a recipient** sees both the edit controls and the claim state, as the server sends it. There is no switch that hides it (see [Claim state on a child's list](../spec.md#claim-state-on-a-childs-list)).
- **The admin** has no access to gifts, and sees a list only as any other user does.
- The page never says who claimed an item.
