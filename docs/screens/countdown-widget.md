# The countdown widget

## Purpose

The next occasions, with a countdown, on the Home Screen and the Lock Screen. It tells a person that an occasion is coming, without opening the app. The rules are in the spec: [The rule for system surfaces](../spec.md#the-rule-for-system-surfaces), [The widget's file](../spec.md#the-widgets-file), and [The extensions and the control](../spec.md#the-extensions-and-the-control).

## What it shows

- The occasions in the next 60 days that the session's user can see, soonest first, the user's own included.
- For each: the occasion's words ("Emma's birthday", "Christmas"), how many days are left, and the person's initials in their person color.
- As many occasions as the size holds. The smallest sizes show one.
- It has no settings, and no photos.

The widget never calls the API. It reads a file that the app writes after each successful sync. It makes one entry for each local midnight, so the days count down while the app is closed.

**Provisional.** Plain default: the next occasions with their countdown, and initials in the person's color, in the small and medium Home Screen sizes and the Lock Screen sizes. The small size shows one occasion, and the medium size shows three.

## What it never shows

- Claim state, or anything about gifts, not even a count. Home's "2 from you · 1 still to buy" is never here.
- Lists, items, prices, or notes.
- The instance address.

The file that it reads holds occasions only, so the widget can't show more.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open an occasion | A tap on the widget, or on an occasion's row in the medium size | Opens the app in the window used last, on top of Home |

A tap follows the rule for a reminder (see [What a tap opens](../spec.md#what-a-tap-opens)):

- a person's birthday or custom occasion: that person's page
- the user's own occasion: their primary list
- a shared occasion: Home

The widget has no buttons.

## States

- **Signed out:** "Open Wishbone to sign in." A tap opens the app on the signed-out screen.
- **Nothing in the next 60 days:** it says so.
- **The app has not synced for a long time:** the widget keeps its last file. A date that moved on the server is corrected at the next sync.
- **The instance can't be reached:** no change. The widget never needs the instance.
- **After the API's own 401, or a sign-out:** the app deletes the file, and the widget shows the signed-out state.
- **Tinted and clear appearances:** the person color gives way to the system's tint. The name carries the meaning.

**Provisional.** These words are drafts: "Nothing in the next 60 days.", "in 12 days", "tomorrow", "today". "Open Wishbone to sign in." is decided in the spec.

VoiceOver reads each occasion as one element: the occasion, then the time left.
