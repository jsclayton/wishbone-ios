# Home

## Purpose

Home is about giving. It answers three questions: which occasion is next, who can I give to, and what is coming up. The rules are in the spec: [Home](../spec.md#home), and the server's [Home](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#home) for the rules that the web app shares.

## How you get here, and where you go

- The first tab. A window opens on it.
- A link from outside opens its page on top of Home (see [Links from outside open on top of Home](../spec.md#links-from-outside-open-on-top-of-home)). A reminder or a widget tap for a shared occasion opens Home itself.
- The countdown and a row in Coming up open what their occasion names (see Actions).
- A person opens their [user's page](user.md). The "People" heading opens the [People](people.md) page. The "Coming up" heading opens the [Occasions](occasions.md) screen.
- The avatar opens [Settings](settings.md) as a sheet.

## Content

From top to bottom:

1. **The countdown** to the next occasion in the next 60 days.
   - It names the occasion and the person, and says how many days are left. A birthday with a year also says the age.
   - It skips the user's own birthday and custom occasions, which stay in Coming up. Shared occasions count.
   - When two occasions are on the same day, it shows both.
   - For its occasion only, it says how many gifts the user has for it, and how many are still to buy: "2 from you · 1 still to buy".
   - A shared occasion says who it reaches, and has "See who's on it".
2. **People**: "Your children", then "Your parents", then one group for each of the user's groups, with "through {group}" for a group that the user is in by nesting. Each group lists its users by name. The user is not listed among their own people.
3. **Coming up**: the occasions in the next 60 days for everyone the user can see, soonest first, the user's own included. A shared occasion is one row.

**Provisional.** Plain default: the countdown as a card in the occasion's person color, the people as initials avatars in rows by group under a "People" heading, and Coming up as a system list. Each Coming up row has the person's avatar, the occasion's words, and the days left.

## States

- **No occasion in the next 60 days:** the countdown says so, and Coming up shows its empty line.
- **Nobody to see:** People shows its empty line. A user in no group, with no parents and no children, sees this.
- **The first sync:** Home's data comes first, so Home fills before the other tabs.
- **Can't reach, and the rest:** as every screen (see [What every screen shares](README.md#what-every-screen-shares)).

## Windows

- **Narrow:** one column.
- **Wide:** the sidebar also lists People and each group's users, as shortcuts. Home keeps its three parts.
- **Several windows:** a person's row has Open in New Window, and can be dragged to the edge of the screen to open a window (see [Opening a window](../spec.md#opening-a-window)). A person is never a drop target for an item.

**Provisional.** Plain default: in a wide window, People's avatars flow into as many columns as fit.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open the countdown's occasion | A tap on the card | A person's occasion opens that person's page. A shared occasion opens its page |
| See who's on it | A button on the card, for a shared occasion | Opens the shared occasion's page (see [Occasions](occasions.md)) |
| Open a person | A tap on the avatar or the name | Pushes the user's page |
| Open People | The "People" heading | Pushes the People page |
| Open a Coming up row | A tap | A person's occasion opens that person's page. The user's own occasion opens their primary list. A shared occasion opens its page |
| Open Occasions | The "Coming up" heading | Pushes the Occasions screen |
| Open in New Window | A person's context menu, where several windows are allowed | Opens a window with that user's page on top of Home |
| Settings | The avatar, top trailing | Opens Settings as a sheet |

## Words

Decided: "Your children", "Your parents", "through {group}", "People", "Coming up", "See who's on it", "Everyone", and "2 from you · 1 still to buy" as a pattern.

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Countdown, a birthday | "Emma's birthday", "Emma turns 9", "in 12 days", "tomorrow", "today" |
| Countdown, gifts | "{n} from you · {m} still to buy", "{n} from you", "Nothing from you yet" |
| No occasion in 60 days | "Nothing in the next 60 days." |
| Nobody to see | "Nobody is here yet. The admin adds people to your groups." |
| Coming up, the user's own | "Your birthday" |

## Accessibility

- The countdown is one element: the occasion, the time left, then the gift counts. "See who's on it" is its own button.
- An avatar reads the person's name, and "Deactivated" when it applies.
- A Coming up row is one element: the occasion, the person, the time left.
- At the largest text sizes, the avatars become a list of rows with the name beside each avatar, and the countdown's lines stack.
- A person's color never carries meaning. The name is always there.

## Secrecy

The countdown shows the user's own open gifts as counts. Only the giver sees them, inside the app. The widget shows the same occasion with no counts (see [countdown-widget](countdown-widget.md)). The Gifts tab's badge is inside the app, and the app icon has none.
