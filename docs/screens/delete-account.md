# The Delete account screen

## Purpose

A person asks for their account to be deleted, or a parent asks for a child. The admin completes the request. The screen says what goes and what stays before anyone asks. The rules are in the spec: [Account deletion](../spec.md#account-deletion).

## How you get here, and where you go

- **Pushed** from **Delete account** in [Settings](settings.md), for every user except the admin.
- **Pushed** from **Ask to delete {name}'s account** in the For {name} part of a child's [user's page](user.md), for a parent.
- The admin does not use this screen to complete a request. The admin uses **Delete {name}** on the user's page.
- When the admin completes the request, the device is signed out, and the [signed-out](signed-out.md) screen says "Your account has been deleted."

## Content

1. What goes: the lists where the user is the only recipient, and the gifts for them alone.
2. What stays: the gifts that they gave stay with their recipients.
3. Who does it, and that the user can keep using Wishbone until then. The screen promises no time.
4. **Ask to delete my account**, or for a child **Ask to delete {name}'s account**.
5. While a request is open: when it was asked, and by whom for a child, with **Cancel request** in place of the button.

**Provisional.** Plain default: a pushed screen with the text and one destructive button.

## States

- **No request.**
- **A request is open.** For a child, any of the child's parents, or the child, can cancel it.
- **The admin's own account:** Settings shows a line in place of the row, and this screen is not reached.
- **Asking, and cancelling, wait for the server.** With no connection, the screen says "Can't reach {address}", and nothing changes.
- **A deactivated child:** the row shows only when the server's `can_*` field allows it.

## Windows

One column of readable width.

## Actions

| Action | Route | What it does |
|---|---|---|
| Ask to delete my account | A destructive button | Sends the request, after one confirmation |
| Cancel request | A button, while a request is open | Withdraws the request |

## Words

Decided in the spec, marked as drafts there: "Delete account", "Ask to delete my account", "Ask to delete {name}'s account", "The admin will delete your account. Until then you can keep using Wishbone or cancel the request.", "Deletion asked for on {date}", "Cancel request", and the admin's own line.

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| What goes | "These are deleted: lists that are only yours, with their items, and gifts that were given to you alone." |
| What stays | "These stay: lists you share with someone, and gifts you gave, with your name on them." |
| For a child | "The admin will delete {name}'s account. Until then {name} can keep using Wishbone, and you or {name} can cancel the request." |
| Confirmation | "Ask the admin to delete your account? This can't be undone after the admin does it.", with the button "Ask to delete my account" |
| Asked by a parent | "Asked by {parent} on {date}" |
| Cancelled | "The request was cancelled." |

## Accessibility

- The text is read in order: what goes, what stays, who does it.
- The button's label says what it does, and it is not marked by color alone.
- The result is announced: the request line, or "The request was cancelled."

## Secrecy

None. The text describes what goes in general words, the same for every user. It never lists the user's gifts, and never says whether anything is claimed for them.
