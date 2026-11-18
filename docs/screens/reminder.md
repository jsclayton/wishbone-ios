# A reminder

## Purpose

A notification that the app schedules on the device, to say that an occasion is coming. It is the same for every user, whatever they claimed or bought. The rules are in the spec: [section 8, Reminders](../spec.md#8-reminders). Its settings are in [reminders-settings](reminders-settings.md).

## What it shows

- One line that names the occasion and the person, and when it is.
- Two reminders for each occasion: the early one, and one on the day. Both arrive at 9:00 in the device's time zone.
- Every occasion that the user can see in the next 60 days gets them: other people's birthdays and custom occasions, shared occasions, and the user's own.

**Provisional.** The words are drafts, as the spec lists them:

| Occasion | The early reminder | On the day |
|---|---|---|
| Someone's birthday | "Emma's birthday is in 2 weeks" | "It's Emma's birthday today" |
| A custom occasion | "Emma's graduation is in 2 weeks" | "It's Emma's graduation today" |
| A shared occasion | "Christmas is in 2 weeks" | "It's Christmas today" |
| The user's own | "Your birthday is in 2 weeks" | "It's your birthday today" |

The title of each notification is "Wishbone". The time in the early reminder follows the setting: "in 1 week", "in 2 weeks", or "in 4 weeks".

## What it never shows

- Claim state, or anything about gifts. There is no "not bought yet" reminder, and no reminder that fires only when a gift is not bought.
- A reveal. No reminder says that gifts were given.
- A badge on the app icon.
- A list, an item, a price, or the instance address.

## Actions

| Action | Route | What it does |
|---|---|---|
| Open | A tap on the reminder | Opens the app in the window used last, on top of Home |

- Someone else's birthday or custom occasion opens that person's page.
- The user's own occasion opens their primary list.
- A shared occasion opens Home.

A reminder has no action buttons.

## States

- **Provisional permission:** reminders arrive quietly in Notification Center, and iOS offers Keep or Turn Off on the first one.
- **Full permission:** reminders also show on the Lock Screen.
- **Notifications off in iOS, or reminders off in the app:** none are scheduled.
- **Signed out:** none exist. Sign-out, the API's own 401, and a fresh install remove every reminder.
- **A reminder from another session:** a tap opens Home.
- **A person the user can no longer see:** a tap opens the "not found" page, on top of Home.
- **A stale reminder:** when neither the app nor background refresh ran for weeks, a reminder can fire for an occasion that moved or went away. This is an accepted cost.
- **The app is locked with iOS's Require Face ID:** iOS keeps the reminder's content out of previews.
