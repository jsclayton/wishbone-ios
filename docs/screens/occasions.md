# The Occasions screen

## Purpose

Every occasion the user can see, soonest first. For the admin, it is also where shared occasions are made and changed. This spec also holds a shared occasion's page and its form. The rules are in the spec: [Shared occasions](../spec.md#shared-occasions). The server's rules are in [Occasions](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#occasions).

## How you get here, and where you go

- **Pushed** from the "Coming up" heading on Home.
- A tap on an occasion opens what it names:
  - a person's birthday or custom occasion: that person's [user's page](user.md)
  - the user's own occasion: their primary [list's page](list.md)
  - a shared occasion: the shared occasion's page (below)
- A birthday and a custom occasion have no page of their own.
- A reminder or a widget tap for a shared occasion opens Home, not the shared occasion's page (see [What a tap opens](../spec.md#what-a-tap-opens)).
- For the admin: **New shared occasion**, and Edit, open the form as a sheet.

## Content

1. **Coming up**: every occasion the user can see that has a next date, soonest first, the user's own included. Each row has the person's avatar or the shared occasion's symbol, the occasion's words, the date, and the days left.
2. **Shared occasions**, for the admin only: every shared occasion, soonest first, each saying who it reaches: "Everyone", or the names of its groups.
3. In the toolbar, for the admin: **New shared occasion**.

**Provisional.** The way in, the layout, and what the first part holds. Plain default: a system list with the two sections, and a plus in the toolbar.

### A shared occasion's page

The same for everyone, pushed from the countdown ("See who's on it"), from Coming up, and from this screen.

1. The occasion's name, its date, the days left, and who it reaches.
2. The users it applies to whom the user can see, by name. Each is marked with how many open gifts the user has for them on this occasion, or "Nothing yet". Each row pushes that user's page.
3. For the admin: **Edit** and **Delete**.

**Provisional.** Plain default: a system list. Edit is a toolbar button, and Delete is a row at the foot.

### The shared occasion form

A sheet, for New and for Edit, with three fields:

- **Name**
- **When**: every year on a date, once on a date, the nth weekday of a month, or the last weekday of a month
- **Who**: Everyone, or Groups, with a picker of the groups

The app attaches the groups after the create, and names any group that failed. On Edit, the footer says what a change does.

**Provisional.** Plain default: a system form in a sheet. When is a menu of the four rules, with the fields that the chosen rule needs under it.

## States

- **Nothing coming up:** the first part says so. This is rare, because every user has a birthday.
- **No shared occasions**, for the admin: the part says so, and points to the plus.
- **A shared occasion that reaches nobody the user sees:** its page says so.
- **Every write to a shared occasion waits for the server.** With no connection, the form says "Can't reach {address}", and stays open.
- **A group didn't attach:** the occasion is still made, and its page names the group.
- **Gone:** a shared occasion that was deleted shows the [not-found](not-found.md) page.
- **Can't reach, and the rest:** as every screen.

## Windows

One column of readable width. Nothing here opens in a new window, and nothing is a drop target.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open an occasion | A tap on its row | Opens the user's page, the primary list, or the shared occasion's page |
| New shared occasion | A toolbar button, for the admin | Opens the form |
| Edit | A toolbar button on the shared occasion's page, from `can_edit` | Opens the form, filled in |
| Delete | A row on the shared occasion's page, from `can_delete` | Deletes it, after a confirmation |
| Save | The form's main button | Makes or changes the occasion, then attaches or detaches the groups |
| Open a user | A row on the shared occasion's page | Pushes that user's page |

## Words

Decided in the spec, marked as drafts there: "Shared occasions", "New shared occasion", "Everyone", "See who's on it", and the Delete confirmation "Gifts picked for {name} move to the next occasion of the people they're for, and each giver sees why." Decided, as the web app has them: "{n} from you" and "Nothing yet".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Occasions" |
| A row | "Emma's birthday", "Emma's graduation", "Christmas", "Your birthday" |
| The time left | "in 12 days", "tomorrow", "today" |
| Nothing coming up | "No occasions are coming up." |
| No shared occasions | "No shared occasions yet. Tap the plus to add one, such as Christmas." |
| Reaches nobody you see | "Nobody you can see is on this occasion." |
| Form, When | "Every year", "Once", "A weekday of a month", "The last weekday of a month" |
| Form, Who | "Everyone", "Groups" |
| Form, Edit footer | "If you change this to Everyone, its groups are dropped. Gifts for people it stops reaching move to their next occasion." |
| A group didn't attach | "{group} wasn't added to {name}. Edit the occasion to try again." |
| Delete, title and button | "Delete {name}?", "Delete {name}" |

## Accessibility

- A row is one element: the occasion, the date, the time left.
- On a shared occasion's page, a user's row reads the name, then "{n} from you" or "Nothing yet".
- The When rule uses system pickers for the month, the day, and the weekday.
- A shared occasion's symbol is decoration. The name carries the meaning.

## Secrecy

A shared occasion's page shows the user's own open gifts as counts beside each person. Only the giver sees them, inside the app. A reminder and the widget show the same occasion with no counts. The admin sees no gifts of anyone else here.
