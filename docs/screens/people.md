# The People page

## Purpose

Everyone the user can see, by group. For the admin, it is also where users and groups are managed. The rules are in the spec: [People](../spec.md#people).

## How you get here, and where you go

- **Pushed** from the "People" heading on Home. In a wide window, the sidebar has a People row too.
- A user's row pushes their [user's page](user.md).
- For the admin: a group's heading, and a row in All groups, push the [group's page](group.md). **New user** opens the [New user](new-user.md) form, and **New group** opens a sheet.
- For anyone else, a group's heading is not a link.

## Content

From top to bottom:

1. **Asked to be deleted**, for the admin, when there are requests: each user who asked, with who asked and when.
2. **Your children**, then **Your parents**, then one part for each of the user's groups, with "through {group}" for a group that the user is in by nesting. Each part lists its users by name.
3. **For the admin**, for the admin only:
   - **All users**: every user by name, with a search field, and "Deactivated" beside a deactivated user. This is also the way to reach a user in no group.
   - **All groups**: every group by name.
   - **Deactivated**: the deactivated users.
4. In the toolbar, for the admin: an add menu with **New user** and **New group**.

A user shows once in each part that has them. Each row has the avatar and the name with the last name.

**Provisional.** Plain default: a system list in the order above. All users, All groups, and Deactivated are rows that push a list each. The add menu's symbol is `person.badge.plus`, so that it differs from the tab bar's plus.

### New group

A sheet with one field, **Name**. After Save, the new group's page is pushed.

## States

- **Nobody to see:** the page says so, as Home does.
- **No deletion requests:** the part is hidden.
- **No deactivated users:** the Deactivated row is hidden.
- **A search in All users finds nobody:** the list says so.
- **New group** waits for the server. With no connection, the sheet says "Can't reach {address}", and stays open.
- **Can't reach, and the rest:** as every screen.

## Windows

- **Narrow and wide:** one column of readable width.
- **Several windows:** a user's row has Open in New Window, and can be dragged to the edge of the screen to open a window. A user's row is never a drop target for an item.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open a user | A tap on a row | Pushes the user's page |
| Open a group | A tap on a group's heading, or a row in All groups, for the admin | Pushes the group's page |
| Search all users | The search field in All users | Filters the list by name |
| New user | The toolbar's add menu, for the admin | Opens the New user form |
| New group | The toolbar's add menu, for the admin | Opens the New group sheet |
| Open in New Window | A user's context menu, where several windows are allowed | Opens a window with that user's page on top of Home |

A deletion request has no button here. The admin opens the user, and uses Delete {name} in the For part.

## Words

Decided in the spec: "People", "Your children", "Your parents", "through {group}", "Asked to be deleted", "For the admin", "All users", "All groups", "Deactivated", "New user", "New group".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| A deletion request | "{name} · asked on Nov 12", "{name} · asked by Dad on Nov 12" |
| Nobody to see | "Nobody is here yet. The admin adds people to your groups." |
| Search, prompt | "Search users" |
| Search, nothing | "No user has that name." |
| New group, name is empty | "Give the group a name." |

## Accessibility

- A user's row is one element: the name, and "Deactivated" when it applies.
- A group's heading is a button for the admin, and plain heading text for anyone else. Both are headings for the VoiceOver rotor.
- The add menu reads "Add", and its items read "New user" and "New group".

## Secrecy

None. The page shows users and groups, and no list, item, or gift. A user sees only the groups that they are in. The admin sees every user and every group, which the server allows.
