# The "Add item" control

## Purpose

One tap from Control Center, the Lock Screen, or the Action button to the [Add screen](add.md). It covers the case that the share extension can't: in a shop, with nothing to share. The rules are in the spec: [The "Add item" control](../spec.md#the-add-item-control).

## What it shows

A symbol and the words "Add item". It is the same for every user, signed in or not.

**Provisional.** Plain default: the plus symbol, with the app's accent as its tint.

## What it never shows

Any data: no list, no count, no name, and no state of the session. It has no value to read, so it can't show claim state.

## Actions

| Action | Route | What it does |
|---|---|---|
| Add item | A tap on the control, or a press of the Action button | Opens the app on the Add screen, on the user's primary list |

- It opens in the window used last. With no window open, the app opens one.
- It runs one App Intent with no parameters.
- From the Lock Screen, iOS asks to unlock the device before the app opens.

## States

- **Signed in:** opens the Add screen.
- **Signed out:** opens the app on the signed-out screen.
- **A version block, or the profile gate, shows:** the tap opens the app, and the block or the gate stays. The Add screen does not open.
- **No connection:** the Add screen opens, and says "Can't reach {address}" when a search is tried.

**Provisional.** The words "Add item" are decided. The control's description in the system's gallery is a draft: "Add something to your Wishbone list."
