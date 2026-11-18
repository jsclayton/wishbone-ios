# The app icon

## Purpose

The app's mark on the Home Screen. The glossary counts it as a **system surface**, because anyone near the device sees it. The rules are in the spec: [The rule for system surfaces](../spec.md#the-rule-for-system-surfaces) and [The app icon](../spec.md#the-app-icon).

## What it shows

The plain wishbone shape, and the name "Wishbone" under it.

**Provisional.** Plain default: a white wishbone on a colorful background, as a layered icon with light, dark, tinted, and clear appearances.

## What it never shows

A badge. The count of gifts that need attention is on the Gifts tab, inside the app. A number on the icon tells whoever sees the device that the owner has gifts to buy. A fitness test holds that nothing sets a badge.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open the app | A tap | Opens the window used last, at its place |
| Require Face ID | Touch and hold the icon | iOS's own lock for the whole app (see [No Face ID lock of the app's own](../spec.md#no-face-id-lock-of-the-apps-own)) |

The icon has no quick actions of the app's own.

## States

One state. The icon is the same signed in and signed out.
