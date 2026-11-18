# A group's page

## Purpose

The admin sees who is in a group, and changes it. Groups decide who sees whom, so this page is the admin's main tool for visibility. The rules are in the spec: [Groups](../spec.md#groups). The server's rules are in [Groups](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#groups).

## How you get here, and where you go

- **For the admin only.** Pushed from All groups, and from a group's heading on the [People](people.md) page.
- A user's row pushes their [user's page](user.md). A row for a group inside pushes that group's page.
- **Add users**, **Add group**, and **Rename** open sheets.
- After Delete group, the page closes, and the window shows what was under it.

## Content

1. The group's name.
2. **Users**: the users directly in the group, by name, each with Remove. A deactivated member shows "Deactivated" and has no Remove.
3. **Groups inside**, under the line "Everyone in these groups is in {group}": the groups directly inside it, each with Remove.
4. **Add users** and **Add group**.
5. **Delete group**.

**Provisional.** Plain default: a system list with a section for users and one for groups. Rename is in the toolbar's menu, and Remove is a swipe action and a context menu item.

### Add users, and Add group

- **Add users** is a picker of the active users who are not directly in the group, by name. It takes several at once.
- **Add group** is a picker of the other groups.

## States

- **An empty group:** each section says so.
- **A refused loop** (422 `group_loop`): the server's `detail` shows, and nothing is added.
- **Every write here waits for the server.** With no connection, the page says "Can't reach {address}", and nothing changes.
- **Gone:** a group deleted from another device shows the [not-found](not-found.md) page.

## Windows

One column of readable width. The page has no Open in New Window, and is not a drop target.

## Actions

| Action | Route | What it does |
|---|---|---|
| Add users | A row, from `can_add_user` | Opens the picker. Each user picked is added, with no confirmation |
| Add group | A row, from `can_add_group` | Opens the picker. The group picked goes inside this one, with no confirmation |
| Remove | A swipe action, and a context menu item, on a user or a group | Removes it from the group, with no confirmation |
| Rename | The toolbar's menu, from `can_edit` | Opens a sheet with the name |
| Delete group | A row at the foot, from `can_delete` | Deletes the group, after a confirmation |
| Open a user, or a group | A tap on the row | Pushes that page |

## Words

Decided in the spec, marked as drafts there: "Everyone in these groups is in {group}", and the Delete confirmation "Its users and the groups inside it stay. People who see each other only through {group} will stop seeing each other's lists."

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Sections | "Users", "Groups inside" |
| No users | "No users are directly in {group}." |
| No groups inside | "No groups are inside {group}." |
| Delete, title and button | "Delete {group}?", "Delete {group}" |
| Rename, title | "Rename group" |
| Add users, nobody left | "Every active user is already in {group}." |
| Add group, none left | "There are no other groups." |

## Accessibility

- A member's row is one element, with the actions Open and Remove.
- Remove is never only a swipe: it is in the context menu and in the row's actions.
- The pickers read each name with "selected" or "not selected".

## Secrecy

None. The page shows users and groups only. Its effect on secrecy is indirect: a group decides who sees whose lists, and the Delete confirmation says so.
