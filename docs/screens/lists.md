# The Lists tab

## Purpose

Everything the user can edit, in one place: their own lists, a part for each child, and the invitations that wait. The rules are in the spec: [Tabs that become a sidebar](../spec.md#tabs-that-become-a-sidebar), [A new list for a child](../spec.md#a-new-list-for-a-child), and [A deactivated child](../spec.md#a-deactivated-child). The server's rules are in [Lists](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#lists).

## How you get here, and where you go

- The second tab.
- A list's row pushes the [list's page](list.md). An invitation's text pushes the list's page too, when the user can see the list.
- **New list** opens the New list form as a sheet. After Save, the new list's page is pushed.
- The avatar opens [Settings](settings.md).
- No link from outside opens this tab. A link to a list opens on top of Home.

## Content

From top to bottom:

1. **Invitations**, only while one is pending: the invitations for the user and for their children. Each has Accept and Decline, from its `can_*` fields.
2. **The user's own lists**: the primary list first, then the extra lists that they are a recipient of, by name.
3. **One part for each child**, under the child's name: the child's primary list first, then the child's extra lists, by name. A list that has both the user and the child as recipients shows once, under the user's own lists.
4. **New list**.

Each list's row shows its name, its recipients' avatars, and how many items it has.

**Provisional.** Plain default: a system list with a section for each part. New list is a toolbar button with a plus.

### The New list form

- **Name** (required) and **Description** (optional, markdown).
- **For**, only when the user has a child whose `can_create_list` is `true`: the user (the default), or one of those children.
- For a child, the form says that the child is the recipient and the user is not.

**Provisional.** Plain default: a system form in a sheet.

## States

- **Always at least one row:** every user has a primary list, so the tab is never empty after the first sync.
- **A deactivated child:** the child's part stays, with "Deactivated" beside the name. Its lists are read-only, and its invitations show without Accept.
- **After an accept:** the list moves into the user's own lists, or into the child's part.
- **Can't reach, and the rest:** as every screen. Accept, Decline, and New list are unsent changes, so they work offline.

## Windows

- **Narrow:** one column.
- **Wide:** the sidebar also lists the user's lists, as shortcuts.
- **Several windows:** a list's row has Open in New Window, and can be dragged to the edge of the screen to open a window.
- **A drop target:** a list's row takes an item dragged from a list that the user can edit. The item goes to the end of that list (see [Where an item can land](../spec.md#where-an-item-can-land)). A row doesn't take a drop from another app.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open a list | A tap on its row | Pushes the list's page |
| Accept | A button on the invitation, from `can_accept` | The user, or the child, becomes a recipient. No confirmation |
| Decline | A button on the invitation, from `can_delete` | Removes the invitation. No confirmation |
| New list | A toolbar button | Opens the form |
| Save | The form's main button | Makes the list, then pushes its page |
| Open in New Window | A list's context menu, where several windows are allowed | Opens a window with that list's page on top of Home |

Moving an item onto a row is a drag. Its way without a drag is Move to… on the item (see [item](item.md)).

## Words

Decided: "New list", "Accept", "Decline", "Deactivated", and the invitation line "Mom invited you to Our house". In the spec, marked as a draft there: "Mom invited Emma to Cousins".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Section headings | "Invitations", "Your lists", and the child's name |
| A row's count | "{n} items", "No items yet" |
| An invitation whose inviter was deleted | "You're invited to {list}", "Emma is invited to {list}" |
| Form title | "New list" |
| Form, For | "For", with "You" and each child's name |
| Form, for a child | "Emma's list. You can edit it, but it isn't yours." |
| Form, name is empty | "Give the list a name." |

## Accessibility

- A list's row is one element: the name, the recipients' names, the item count. Its actions are Open and, where allowed, Open in New Window.
- An invitation is one element with the actions Accept and Decline. The buttons are also on screen.
- At the largest text sizes, the avatars move under the list's name.

## Secrecy

None. The rows show no claim state. A giver's `item_count` on a child's list can be lower than the child's own count, because a giver doesn't see a fully claimed item. The row shows the count as the server sends it, with no comment.
