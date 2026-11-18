# The "not found" page

## Purpose

One page for everything that can't be shown: a thing that was deleted, and a thing that is not shared with the user. The two look the same, so the page never shows that a hidden thing exists. The rules are in the spec: [Links from outside open on top of Home](../spec.md#links-from-outside-open-on-top-of-home) and [A page that goes away under a window](../spec.md#a-page-that-goes-away-under-a-window).

## How you get here, and where you go

- It takes the place of a pushed page. It is never a sheet, and never an alert.
- It shows when:
  - a link from outside names a list, an item, a user, or an occasion that is missing or hidden
  - a row is tapped whose thing is gone on the server, before a sync removed the row
  - a change takes away a page that a window shows: a list deleted or left, an item deleted, a gift unclaimed
- Back works as usual, and goes to what was under the page.
- On restore, a window does not show this page for a page that no longer exists. It drops that page quietly, and shows what was under it (see [What a window remembers](../spec.md#what-a-window-remembers)).

## Content

A symbol, a title, and one line. The words are the same for every kind of thing.

**Provisional.** Plain default: the system's unavailable-content view.

## States

One state. The page does not say what kind of thing was asked for, or why it is not there.

## Windows

Each window shows it only where that window's own page went away. Nothing closes or goes back by itself.

## Actions

| Action | Route | What it does |
|---|---|---|
| Back | The navigation bar's Back button | Returns to what was under the page |

## Words

**Provisional.** These are drafts: the title "Not here", and the line "This is gone, or it isn't shared with you."

## Accessibility

The title and the line are one element, read when the page appears. Back is the next element.

## Secrecy

The page is the same for a missing thing and a hidden thing, as the server's 404 is. So it never confirms that a hidden list, item, user, or gift exists. A fully claimed item that a giver can no longer see shows this page, with nothing that says it was claimed.
