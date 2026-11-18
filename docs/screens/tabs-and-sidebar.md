# The tabs and the sidebar

## Purpose

The frame around every screen behind the sign-in: three tabs and the plus. In a narrow window it is a tab bar. In a wide window it is a sidebar, with more rows as shortcuts. The rules are in the spec: [Tabs that become a sidebar](../spec.md#tabs-that-become-a-sidebar), [Adding: the plus at the end of the tab bar](../spec.md#adding-the-plus-at-the-end-of-the-tab-bar), and [ADR 0001](../adr/0001-tabs-that-become-a-sidebar-and-one-kind-of-window.md).

## How you get here, and where you go

- It shows in every window, after the [signed-out](signed-out.md) screen, a [version block](version-block.md), and the [profile gate](profile-gate.md).
- A window opens on Home. A restored window opens on the tab it had.
- Each tab keeps its own pushed pages. To change the tab keeps them.
- A link from outside selects Home, and opens its page on top of Home. The "Add item" control selects the Add screen.
- A sidebar shortcut selects the tab that owns the page, and pushes the page there: a list in Lists, and People or a user on Home.

## Content

**The tabs**, in this order:

1. **Home** (see [home](home.md))
2. **Lists** (see [lists](lists.md))
3. **Gifts**, with the badge (see [gifts](gifts.md))
4. **The plus**, set apart at the end, which opens the [Add screen](add.md)

**The sidebar**, in a wide window, has the same four, then the shortcuts:

1. **Your lists**: the user's own lists, the primary list first.
2. **People**: one row that opens the [People](people.md) page.
3. One section for each of the user's groups, with its users.

The avatar that opens [Settings](settings.md) is not in the frame. It is at the top trailing corner of Home, Lists, and Gifts.

**Provisional.** Which shortcut rows the sidebar has, and their order. Plain default: your lists, then People, then one section for each group. The plus is filled with the accent color. If the system's search tab doesn't take the accent, the plus keeps the system look.

## States

- **The badge** is the server's count of the user's open gifts that need attention. It is absent at zero.
- **The first sync:** the tabs show at once. The sidebar's shortcuts fill as rows arrive.
- **No lists but the primary list:** Your lists has one row.
- **No groups:** the sidebar has no group sections.
- **A deactivated user** in a group's section shows "Deactivated", for a viewer who gets it.
- **Can't reach {address}:** the frame is the same. The line shows in each screen, not in the frame.

## Windows

- **Narrow:** a tab bar at the bottom, with the plus at its end. The shortcuts don't show, and the tab bar never grows a "More" tab.
- **Wide:** a sidebar. The person can collapse it to a tab bar at the top, as the system allows.
- **A resize** changes where a place shows, never whether it exists. The window keeps its tab and its pushed pages.
- **Several windows:** every window has the whole frame, and its own selected tab.
- **A drop target:** a list's row in the sidebar takes an item dragged from a list that the user can edit. The item goes to the end of that list. A person's row, and a tab, take nothing.
- **Opening a window:** a list's row or a person's row can be dragged to the edge of the screen. Each also has Open in New Window in its context menu.

## Actions

| Action | Route | What it does |
|---|---|---|
| Change the tab | A tap on a tab or a sidebar row. Command-1, Command-2, Command-3 | Shows that tab, at its place |
| Go to the top of a tab | A tap on the selected tab | Pops to the tab's first screen |
| Add item | The plus. Command-N | Opens the Add screen, with its field ready |
| Open a shortcut | A tap on a sidebar row | Opens that list, People, or that user |
| Open in New Window | A list's or a person's context menu in the sidebar, where several windows are allowed | Opens a window with that page on top of Home |
| Move an item to a list | A drop on a list's row. Without a drag: Move to… on the item | Moves the item to the end of that list |

## Words

Decided in the spec: "Home", "Lists", "Gifts", "People", and "through {group}".

**Provisional.** These are drafts: the plus's label "Add", the heading "Your lists", and the badge's spoken words.

## Accessibility

- Each tab reads its name. Gifts reads "Gifts, {n} need attention" when it has a badge.
- The plus reads "Add". It is a button with a name, not only a symbol.
- A sidebar row for a list reads the list's name. A row for a user reads their name, and "Deactivated" when it applies.
- Moving an item never needs the sidebar: Move to… does the same.
- At the largest text sizes, the tab bar uses the system's large-content viewer.

## Secrecy

The Gifts badge is a count of the user's own open gifts, so it is claim state. It shows only inside the app's windows. The app icon has no badge, and no system surface repeats the count (see [The rule for system surfaces](../spec.md#the-rule-for-system-surfaces)). The sidebar's rows show names only.
