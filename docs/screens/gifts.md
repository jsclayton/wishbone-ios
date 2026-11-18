# The Gifts tab

## Purpose

The user's gifts, in three parts. **Giving** has the open gifts: what the user said they will get. **Given** has what they gave. **Received** has what was given to them. The server's rules are in [Gifts](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#gifts).

## How you get here, and where you go

- The third tab. It is one screen with three parts, and one part shows at a time. Giving shows first.
- To change the part is not a push, so Back never goes through the parts. Each window remembers its part.
- The tab carries a badge: the number of open gifts that need attention (see [Home](../spec.md#home)).
- A gift's row pushes the [gift's page](gift.md).
- **What {name} received**, in a child's For {name} part, pushes a screen with only the Received part, built for the child (see [The For {name} part](../spec.md#the-for-name-part)).
- The avatar opens [Settings](settings.md).
- No link from outside opens this tab or a gift.

## Content

A control that picks the part, then the part.

**Provisional.** Plain default: a segmented control at the top, and each part as a system list with a section for each group.

### Giving

- The user's open gifts, in groups by list and occasion. A group's heading names the recipients and the occasion.
- A group with a gift that needs attention goes to the top. Then the groups are in order of reveal, soonest first.
- Each row shows the item's image and title, and the reveal date.
- A row also shows how many, when it is more than one, the from label, when the gift has one, and each change flag in words.
- Each row has the **bought** toggle.
- When the giver can't see the gift's occasion, the heading has only the reveal date.

### Given

- The gifts the user gave, newest first, in groups by occasion.
- Each row shows the image and title as they were at the reveal, who it went to, and the date.

### Received

- The gifts given to the user, newest first, in groups by occasion. For a child, the gifts given to the child.
- Each row shows the image and title, and who gave it: "From {label} · claimed by {giver}", or the giver's name alone.

## States

- **Giving is empty:** it says so, and points to Home's people.
- **Given is empty**, and **Received is empty:** each says so.
- **A gift is taken into another** (the server merges two gifts for one occasion): its row goes at the next sync.
- **A gift is restored by its recipient:** it leaves Given, and shows in Giving with its flag.
- **Can't reach, and the rest:** as every screen. The bought toggle is an unsent change, so it works offline.

## Windows

- **Narrow and wide:** one column of readable width.
- **Several windows:** each window has its own part. A change to a gift shows in every window at once.
- A gift is not dragged, and no part is a drop target.

## Actions

| Action | Route | What it does |
|---|---|---|
| Change the part | The control at the top | Shows Giving, Given, or Received |
| Open a gift | A tap on its row | Pushes the gift's page |
| Mark bought | The toggle on a Giving row. Also on the gift's page | Sets or clears the giver's private mark |
| I won't get this | A Giving row's context menu and swipe action. Also on the gift's page | Unclaims, after a confirmation |
| I didn't get this | A Received row's context menu, from `can_restore`. Also on the gift's page | Restores the gift, after a confirmation |
| Add again | A Received row's context menu, from `can_add_again`. Also on the gift's page | Opens the add form, filled from the gift |

The confirmations and their words are in [gift](gift.md).

## Words

Decided, as the web app has them: "Giving", "Given", "Received", "Hidden until Dec 26", "I won't get this", "I didn't get this", "Add again", "From Emma · claimed by Mom", "Mom says they didn't get this", "Marked as not received", "Now for Mom", "The recipients changed".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| A Giving heading | "For Dad · Christmas", "For Mom and Dad · Hidden until Mar 4" |
| Bought | "Bought" |
| How many | "{n} of these" |
| Flag: changed | "The item changed" |
| Flag: removed | "Removed from the list" |
| Flag: moved | "Moved to {list}", or "Moved to another list" |
| Flag: the occasion moved | "Now for {occasion}" |
| Flag: no longer shared | "No longer shared with you" |
| Giving is empty | "You aren't getting anything yet. Open someone on Home and tap I'll get this." |
| Given is empty | "Nothing given yet. A gift moves here the day after its occasion." |
| Received is empty | "Nothing received yet. Gifts show here the day after an occasion." |
| A child's Received, title | "What {name} received" |
| A child's Received is empty | "{name} hasn't received anything yet." |

## Accessibility

- A Giving row is one element: the title, how many, the reveal date, bought or not bought, then each flag. Its actions are Open, Mark bought or Mark not bought, and I won't get this.
- A Received row's actions are Open, I didn't get this, and Add again, as allowed.
- The control's three parts are labeled by their names. The badge reads "{n} gifts need attention".
- "Needs attention" is said in words on the row, and never by color alone.
- At the largest text sizes, the image moves above the text, and the bought toggle gets its own line.

## Secrecy

Giving shows the user's own open gifts. Nobody else is allowed to see them. The guard is the device's lock, and iOS's Require Face ID for the app (see [No Face ID lock of the app's own](../spec.md#no-face-id-lock-of-the-apps-own)).

- The badge is inside the app. The app icon has none.
- Received never shows a giver's private note or bought mark. The server doesn't send them.
- A child's Received shows only given gifts. A parent never sees a child's Giving or Given.
- Nothing from this tab goes to a system surface or into the shared container.
