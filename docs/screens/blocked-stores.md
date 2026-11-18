# Blocked stores

## Purpose

The admin keeps some stores out of the instance: nobody can add or search a link from a blocked store. It is the only admin job in Settings. The rules are in the spec: [Blocked stores](../spec.md#blocked-stores).

## How you get here, and where you go

- **Pushed** from **Blocked stores**, in the For the admin section of [Settings](settings.md). For the admin only.
- **Add** pushes a form with one field. It is pushed, not a sheet, because Settings is already a sheet.

## Content

1. The blocked stores, by name.
2. A footer that says what a block does.
3. **Add**, in the toolbar.

**Provisional.** Plain default: a system list, with Add in the toolbar. The Add form is a system form with one text field, Cancel, and Add.

## States

- **None blocked:** the list says so.
- **A store that is already blocked** (409 `already_blocked`): it counts as success, and the list shows it once.
- **Not a host name or a web address:** the field is marked.
- **Add and Unblock wait for the server.** With no connection, the screen says "Can't reach {address}", and nothing changes.
- **Can't reach, and the rest:** as every screen. The list shows from the local copy.

## Windows

One column of readable width.

## Actions

| Action | Route | What it does |
|---|---|---|
| Add | The toolbar | Takes a host name or a pasted web address, and blocks that store |
| Unblock | A swipe action, and a context menu item | Removes the block, with no confirmation |

## Words

Decided in the spec, marked as drafts there: "Blocked stores", "Add", "Unblock", and the footer "Links from these stores and their subdomains can't be added or searched. Items that already have them keep them."

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| None blocked | "No stores are blocked." |
| Add, prompt | "example.com, or paste a link" |
| Not valid | "Enter a store's address, such as example.com." |

## Accessibility

- A store's row reads its name, with the action Unblock.
- Unblock is never only a swipe.
- The Add field's label is "Store to block".

## Secrecy

None. The list shows only the stores, not the items that link to them. The admin has no access to content.
