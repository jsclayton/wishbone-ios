# A gift's page

## Purpose

One gift in full. While a gift is open, its giver marks it bought here, changes how many, picks the occasion, sets the from label, and keeps a private note. The giver also answers a change to the item here. For a given gift, the page shows what was given. Its recipients can say that it didn't arrive, or add it again. The server's rules are in [Gifts](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#gifts).

## How you get here, and where you go

- **Pushed** from a row in Giving, Given, or Received, and from the line "You claimed 1 for Christmas" on an item's page.
- No link from outside opens a gift's page. No system surface names a gift.
- The item's title pushes the [item's page](item.md), when the viewer can still see the item. The list's name pushes the [list's page](list.md). A name pushes that [user's page](user.md).
- **Add again** opens the [add form](add-form.md) in a sheet.
- After "I won't get this" or "I didn't get this", the page closes, and the window shows what was under it.

## Content

### An open gift, for its giver

1. The item's image, title, and price, and who the gift is for.
2. Each change flag, in words, with its answer (see Actions). A changed item lists each change, old to new.
3. **Bought**.
4. **How many**, when the giver can change it.
5. **Occasion**, with the reveal date under it.
6. **From**: the from label, at most 60 characters.
7. **Note**: the giver's private note.
8. **Get another for a different occasion**, when the item can still be claimed and another occasion is free.
9. **I won't get this**.

### A given gift

1. The image, title, and price, as they were at the reveal.
2. Who gave it: "From {label} · claimed by {giver}", or the giver's name.
3. Who it was for, the occasion, how many, and the date it was given.
4. For its giver only: the bought mark and the private note, as they were.
5. For a recipient, or a recipient's parent: **I didn't get this** and **Add again**.

**Provisional.** Plain default: a system form. The image and title are the header, the flags are the first section, and each field is a row. The buttons at the foot are full-width rows.

## States

- **The item was removed from its list:** the page shows the item as it was, with no link to it. The answers are Keep it and I won't get this.
- **The giver can't see the occasion:** the Occasion row shows only the reveal date.
- **The giver can't see the list** (the gift has no `recipients`): the page shows no "For" line, and the list's name is not a link.
- **The giver can see none of the other recipients:** the occasion can't be changed (`occasion_locked`). The row is not a button.
- **The giver is now a recipient of the list:** How many can only go down.
- **Raising how many** waits for the server. With no connection, it says "Can't reach {address}", and the number stays.
- **A change of occasion merges two gifts:** the page then shows the gift that stays.
- **Restored by a recipient:** the gift is back in Giving, with the flag that says who said so.
- **Gone:** a gift that was unclaimed, merged, or restored from another device shows the [not-found](not-found.md) page.
- **I didn't get this** waits for the server. With no connection, it says "Can't reach {address}", and the gift stays in Received.
- **Can't reach, and the rest:** as every screen. Bought, the note, the from label, the occasion, lowering how many, each answer to a flag, I won't get this, and Add again are unsent changes.

## Windows

- **Narrow and wide:** one column of readable width.
- **Several windows:** a change shows in every window.
- A gift is not dragged, and the page is not a drop target.

## Actions

| Action | Route | What it does |
|---|---|---|
| Mark bought | The Bought toggle, from `can_edit`. Also on the row in Giving | Sets or clears the giver's private mark |
| Change how many | A stepper, from `can_edit`. Raising needs `can_raise_quantity` | Lowers at once. Raises after the server answers |
| Pick the occasion | The Occasion row, from `can_edit` | A menu of the occasions that the giver can use, soonest first |
| Set the from label | The From field, from `can_edit` | Saves when the field loses focus |
| Write the note | The Note field, from `can_edit` | Saves when the field loses focus |
| OK | A button on a flag, from `can_acknowledge` | Clears that flag |
| Keep it | A button on the "removed" flag | Clears the flag. The gift is given at its reveal |
| Get another for a different occasion | A row, from the item's `can_claim`, when the giver has no gift on the item for some other occasion they can pick | Claims one for the soonest such occasion, after the server answers. The new gift's page is pushed |
| I won't get this | A row at the foot, from `can_delete` | Unclaims, after a confirmation. The quantity goes back to all givers |
| I didn't get this | A row at the foot, from `can_restore` | Restores, after a confirmation. The gift goes back to its giver |
| Add again | A row at the foot, from `can_add_again` | Opens the add form filled from the gift. Add to starts on the gift's list |
| Open the item | A tap on the title | Pushes the item's page |

- **Add again** starts on the gift's list when the user can still edit it. Otherwise it starts on their own primary list, or on the primary list of the child who received the gift.

## Words

Decided, as the web app has them: "I won't get this", "I didn't get this", "Add again", "Hidden until Dec 26", "From Emma · claimed by Mom", "Mom says they didn't get this", "Marked as not received", "Now for Mom", and "The recipients changed". The flag words in [gifts](gifts.md) are used here too.

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Gift" |
| For | "For Dad", "For Mom and Dad" |
| Fields | "Bought", "How many", "Occasion", "From", "Note", and "Given" on a given gift |
| From, prompt | "Who it's from, if not only you" |
| Note, footer | "Only you see this note." |
| A change | "Title: {old} → {new}", "Price: {old} → {new}", "Price: {old} → none", "The photo changed", "{store}: {old} → {new}", "{store} was removed", "Wants: {old} → {new}", "Now always wanted", "No longer always wanted", "The notes changed" |
| Bought, read | "Yes", "No" |
| Flag: removed | "This was removed from the list. You can still give it." |
| Flag: no longer shared | "This list is no longer shared with you. You can still give this, or not." |
| Flag: the occasion moved | "The occasion changed. It's now for {occasion}.", or "The occasion changed." when the giver can't see it |
| Answers | "OK", "Keep it" |
| A second gift | "Get another for a different occasion" |
| I won't get this, confirmation | "You won't get {title}? Other people can then claim it.", with the button "I won't get this" |
| I didn't get this, confirmation | "You didn't get {title}? It leaves your Received. If the giver still uses Wishbone, they see that, and can give it again.", with the button "I didn't get this" |
| I didn't get this, for a child | "{name} didn't get {title}?", with the button "{name} didn't get this" |
| Raise, can't reach | "Can't reach {address}. The number didn't change." |
| How many, for VoiceOver, when it can't go higher | "{n}, can't go higher" |
| A late refusal, in the alert "Some changes couldn't be saved" | "The from label of {title}: {reason}", "The note on {title}: {reason}", "How many of {title}: {reason}", "I won't get {title}: {reason}", "Keeping {title}: {reason}", "The change to {title}: {reason}" |
| I didn't get this, can't reach | "Can't reach {address}. Nothing changed." |

## Accessibility

- Each flag is one element: what changed, then its answer as an action. The buttons are also on screen.
- The stepper reads "How many, {n}", and says when it can't go higher.
- A destructive row says what it does in its label, not only by color.
- At the largest text sizes, each field's label sits above its value.

## Secrecy

- **An open gift** is seen only by its giver. For everyone else it does not exist, and the page can't be opened.
- **A given gift** is seen by its giver, its recipients, and each recipient's parents. A recipient never sees the private note or the bought mark. The server doesn't send them.
- The page never says who else claimed the same item.
- "I didn't get this" hides the gift from the person who tapped it. That is the server's rule, and the confirmation says that the gift leaves Received.
- The confirmation's words are the same whether the giver is active, deactivated, or deleted. A recipient can't tell these apart, and the words promise nothing about the giver.
- Nothing on this page goes to a system surface or into the shared container.
