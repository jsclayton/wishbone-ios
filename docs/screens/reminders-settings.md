# The Reminders screen

## Purpose

The settings for **reminders**: on or off, how early, and whether they show on the Lock Screen. What a reminder is and says is in [reminder](reminder.md). The rules are in the spec: [One switch, and the timing](../spec.md#one-switch-and-the-timing) and [Turning them on](../spec.md#turning-them-on).

## How you get here, and where you go

- **Pushed** from **Reminders** in [Settings](settings.md).
- **Open Settings** opens the app's page in iOS Settings.

## Content

1. **Reminders**: the one switch, for all occasions together.
2. **Remind me early**: 1 week, 2 weeks, or 4 weeks before. Two weeks is the default.
3. **On the day**: a switch, on by default.
4. A line that says when reminders arrive: 9:00.
5. **Show on Lock Screen**, while the app has only provisional permission.
6. A line that says what a reminder never shows.

**Provisional.** Plain default: a system form.

## States

- **Provisional permission** (the start): reminders go quietly to Notification Center. Show on Lock Screen is offered.
- **Full permission:** Show on Lock Screen is gone. A line says that reminders show on the Lock Screen.
- **Notifications are off in iOS:** the switches are disabled. A line says so, with Open Settings. The app never asks again.
- **Reminders off:** the timing rows are hidden.
- **No connection:** the screen works. The reminders are made from the local copy.

## Windows

One column of readable width.

## Actions

| Action | Route | What it does |
|---|---|---|
| Turn reminders on or off | The Reminders switch | Makes the whole set again, or removes it |
| Pick how early | The Remind me early row | A menu of the three choices. The set is made again |
| Turn the day-of reminder on or off | The On the day switch | The set is made again |
| Show on Lock Screen | A button | Asks iOS for full permission, with the system alert. Only this tap asks |
| Open Settings | A button, when notifications are off | Opens the app's page in iOS Settings |

## Words

Decided in the spec: "Reminders", "Show on Lock Screen", "1 week", "2 weeks", "4 weeks".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Rows | "Remind me early", "On the day" |
| The time | "Reminders arrive at 9:00 in the morning." |
| What a reminder shows | "A reminder names the occasion and the person. It never says anything about gifts." |
| Provisional permission | "Reminders arrive quietly in Notification Center." |
| Full permission | "Reminders show on the Lock Screen." |
| Notifications off | "Notifications are off for Wishbone. Turn them on in Settings to get reminders." |

## Accessibility

- Each switch reads its label and its state.
- Remind me early reads its value: "Remind me early, 2 weeks".
- The lines of help are read after the control that they explain.

## Secrecy

The screen states the rule for reminders: the occasion and the person only, and nothing about gifts. There is no setting that shows more.
