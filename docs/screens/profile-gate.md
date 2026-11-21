# The profile gate

## Purpose

A new user checks their own profile before anything else: the name, the birthday, and a photo. A parent or the admin often filled it in, and only the user can confirm it. The rules are in the spec: [The profile gate](../spec.md#the-profile-gate).

## How you get here, and where you go

- It replaces the whole window, after sign-in and at each launch, while the user's `can_confirm_profile` is `true` (see [What sits in front of the tabs](../spec.md#what-sits-in-front-of-the-tabs)).
- A link from outside that arrives while it shows is dropped.
- **Continue** confirms the profile, and the window shows [Home](home.md). The app then asks for provisional permission for reminders (see [Turning them on](../spec.md#turning-them-on)).
- **Sign out** returns to the [signed-out](signed-out.md) screen.

## Content

One form, filled with what the profile has:

1. A line that says why the screen shows.
2. **Photo**, optional: Take a photo, Choose a photo, or Remove.
3. **Name** (required) and **Last name** (optional).
4. **Birthday**: month and day (required), and an optional year.
5. **Continue**.
6. **Sign out**.

The form has no time zone and no good to know. The time zone is reported by the app, and good to know is in [Your profile](profile.md).

**Provisional.** Plain default: one system form with the profile's fields. Continue is the form's main button, at the trailing end of the toolbar, and Sign out is a toolbar button at its leading end.

## States

- **Saving:** Continue shows progress. The app saves the changed fields, then confirms the profile.
- **Can't reach {address}:** the form stays as typed, with the line and Try again. The gate needs the instance, because only the server's answer confirms a profile.
- **A field is not valid:** the field is marked.
- **The photo can't be used:** the words for the image's error code, and the form keeps the old photo.

## Windows

Every window shows the gate until the profile is confirmed. The form stays in a column of readable width.

## Actions

| Action | Route | What it does |
|---|---|---|
| Take a photo, Choose a photo | A menu on the photo | Sets the avatar. The system camera, or the system photo picker |
| Remove photo | The same menu, when there is a photo | Clears the avatar |
| Continue | The form's main button | Saves the fields, then `POST /users/me/confirm-profile` |
| Sign out | A toolbar button | Signs out, with the warning from [Sign out](../spec.md#sign-out) |

## Words

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Finish your profile" |
| The line | "Check your name and birthday. Your family sees them." |
| The year | "Year (optional)", with the footer "With a year, your family sees the age you're turning." |
| Photo | "Add a photo", with the footer "A photo is optional." |
| Name is empty | "Enter your name." |
| The photo's menu | "Take a photo", "Choose a photo", "Remove photo". With a photo, the control reads "Photo" |
| The birthday's rows | "Month", "Day", and "Year (optional)", whose picker starts with "No year" |
| A field that a 422 names | "Check your name.", "Check your last name.", "Check your birthday." |
| Continue with no connection | "Can't reach {address}", and the button reads "Try again" |

## Accessibility

- The photo control reads "Photo, {name}" or "Add a photo", and its menu holds the three actions.
- The birthday uses system pickers, which work with VoiceOver and Voice Control.
- At the largest text sizes, each label sits above its field.

## Secrecy

None. The screen shows only the user's own profile.
