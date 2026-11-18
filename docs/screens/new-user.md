# The New user form

## Purpose

The admin adds a person to the instance. Only the admin makes users: Wishbone has no sign-up. The rules are in the spec: [New user](../spec.md#new-user).

## How you get here, and where you go

- **A sheet**, from New user in the add menu of the [People](people.md) page. For the admin only.
- After Save, the sheet closes, and the new [user's page](user.md) is pushed. Sign {name} in, in the For part, is the next step there. The form does not go to a login link, because many new users never sign in.

## Content

1. **Name** (required) and **Last name** (optional).
2. **Birthday**: month and day (required), and an optional year.
3. **Parents**: any number, optional.
4. **Groups**: any number, optional.

The form sends no time zone. The user's own device reports it.

**Provisional.** Plain default: a system form in a sheet. Parents and Groups are rows that push a picker each, inside the sheet.

## States

- **Saving:** Save shows progress, and waits for the server.
- **A group didn't take the user:** the user is still made. The sheet closes, and the user's page names each group that failed.
- **A refused parent** (422 `parent_loop`, or `admin_has_no_parents`): the form stays open with the words for the code.
- **Can't reach {address}:** the form stays open as typed, with the line. Save tries again.
- **A field is not valid:** the field is marked.

## Windows

The sheet keeps a readable width. A window asks before it closes while the form has typed changes.

## Actions

| Action | Route | What it does |
|---|---|---|
| Pick parents | The Parents row | Pushes a picker of every user, by name |
| Pick groups | The Groups row | Pushes a picker of every group, by name |
| Save | The form's main button | `POST /users`, then adds the user to each group |
| Cancel | The toolbar | Closes the sheet, after the confirmation when it has changes |

## Words

Decided in the spec: "New user", and the fields "Name", "Last name", "Birthday", "Parents", "Groups".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| The year | "Year (optional)" |
| Groups, footer | "Groups decide who sees {name}'s lists. A user in no group is seen only by their parents and by you." |
| Name is empty | "Enter a name." |
| Leave with changes | "Discard this user?", with "Discard" and "Keep editing" |

## Accessibility

- Parents and Groups read how many are picked: "Parents, 2 selected".
- The birthday uses system pickers.
- At the largest text sizes, each label sits above its field.

## Secrecy

None.
