# The profile screen

## Purpose

A user's profile: the name, the photo, the birthday, good to know, and their occasions. The screen is the same for the user and for anyone who acts for them. The rules are in the spec: [The For {name} part](../spec.md#the-for-name-part). The server's rules are in [Users](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#users) and [Occasions of a user](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md#occasions-of-a-user).

## How you get here, and where you go

- **Pushed** from **Your profile** in [Settings](settings.md), for the user's own profile.
- **Pushed** from **Edit {name}'s profile** in the For {name} part of a [user's page](user.md), for a parent or the admin.
- **New occasion** and a custom occasion's row open the occasion form as a sheet. From Settings, where the screen is already in a sheet, the form is pushed.

## Content

A form, filled with the profile:

1. **Photo**: the avatar, with Take a photo, Choose a photo, and Remove.
2. **Name** (required) and **Last name** (optional).
3. **Birthday**: month and day (required), and an optional year.
4. **Good to know**: markdown that givers see, such as sizes, favorite colors, or allergies.
5. **Occasions**: the user's birthday, their custom occasions, and the shared occasions that apply to them, each with its next date. Then **New occasion**, from `can_add_occasion`.

The screen has no time zone field. For a child, an edit never confirms the profile.

**Provisional.** Plain default: a system form. Each field saves when it loses focus, so the screen has no Save button.

### The occasion form

For a custom occasion: **Name**, and **When**, with the four date rules that a shared occasion has (see [occasions](occasions.md)). On Edit, the form also has **Delete occasion**.

**Provisional.** Plain default: a system form with Cancel and Save.

## States

- **Saving:** none shown. Each edit is an unsent change, and shows at once.
- **A field is not valid:** the field is marked, and keeps its last saved value on the server.
- **The photo can't be used:** the words for the image's error code, and the old photo stays.
- **The admin's view of another user:** Occasions shows only what the server gives the admin, so no custom occasions through the admin's access.
- **A deactivated user:** nobody reaches this screen for them, because the For row is hidden.
- **Can't reach, and the rest:** as every screen. A photo uploads when the instance answers.

## Windows

One column of readable width. A window asks before it closes while the occasion form has typed changes.

## Actions

| Action | Route | What it does |
|---|---|---|
| Change the photo | A menu on the photo | Take a photo, Choose a photo, or Remove |
| Edit a field | The field | Saves when the field loses focus |
| New occasion | A row, from `can_add_occasion` | Opens the occasion form |
| Edit an occasion | A tap on a custom occasion, from `can_edit` | Opens the form, filled in |
| Delete occasion | A row in the form, from `can_delete` | Deletes it, after a confirmation |

A birthday and a shared occasion show in Occasions with no action. The birthday changes through the Birthday field.

## Words

Decided, as the web app has them: "Your profile", "Edit {name}'s profile", "Good to know".

**Provisional.** These are drafts:

| Where | Words |
|---|---|
| Title | "Your profile", or "{name}'s profile" |
| Good to know, prompt | "Sizes, favorite colors, allergies, or anything givers need" |
| Good to know, footer | "Everyone who can see you sees this.", or "Everyone who can see {name} sees this." |
| The year | "Year (optional)", with the footer "With a year, your family sees the age you're turning." |
| Occasions | "Occasions", "New occasion" |
| An occasion's row | "Birthday · March 4", "Graduation · June 12", "Christmas · December 25" |
| Occasion form, titles | "New occasion", "Edit occasion" |
| Delete, confirmation | "Delete {occasion}? Gifts picked for it move to {name}'s next occasion, and each giver sees why.", with the button "Delete {occasion}" |
| Name is empty | "Enter a name." |

## Accessibility

- The photo control reads "Photo, {name}" or "Add a photo", and its menu holds the actions.
- Good to know is a text editor with its label read first.
- An occasion's row is one element: the name and the next date. A custom occasion says that it can be edited.
- At the largest text sizes, each label sits above its field.

## Secrecy

None. The profile is seen by everyone who can see the user. The screen shows nothing about gifts. The delete confirmation says that gifts move, whether or not any gift is picked for the occasion, so it tells the user nothing about claims.
