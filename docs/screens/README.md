# Screen specs

One file for each screen and each **system surface** of the app. A screen's spec says where the screen is, what it holds, and what each action does. The [spec](../spec.md) holds the rules that several screens share, and a screen's spec links to them and never copies them. The server's [spec](https://github.com/jsclayton/wishbone/blob/main/docs/spec.md) holds the rules for who sees what and who can do what.

A screen and its spec always agree. A change to a screen changes its spec in the same pull request (see [Keeping the docs current](../workflow.md#keeping-the-docs-current)).

## Placement is decided, presentation is provisional

The rule is in the spec: [Placement is decided, presentation is provisional](../spec.md#placement-is-decided-presentation-is-provisional). In short:

- **Decided, and not marked:** which places exist (a tab, a sheet, or a pushed screen), where a link opens, what each action does, and the words, unless they are marked.
- **Provisional, and marked:** layout, look, order, symbols, and draft words. Each has a plain default, written as "**Provisional.** Plain default: ...".
- An implementer builds the plain default without asking: system lists, forms, and controls, the system font with Dynamic Type, SF Symbols, and the one accent color.
- A mark comes off in a pull request, after the maintainer has used the screen.

In a screen's spec, the **Content** section gives the plain default for the layout. The **Words** section says which words are drafts.

## Index

### In front of the tabs

| Spec | What it is |
|---|---|
| [signed-out](signed-out.md) | The signed-out screen, with the scanner and the help sheet |
| [version-block](version-block.md) | The two blocks: the app is too old, or the instance is too old |
| [profile-gate](profile-gate.md) | The finish-your-profile steps |

### Tabs

| Spec | What it is |
|---|---|
| [tabs-and-sidebar](tabs-and-sidebar.md) | The frame: the tab bar, and the sidebar in a wide window |
| [home](home.md) | The Home tab: the countdown, your people, and Coming up |
| [lists](lists.md) | The Lists tab, with the New list form |
| [gifts](gifts.md) | The Gifts tab: Giving, Given, and Received |
| [add](add.md) | The Add screen |
| [add-form](add-form.md) | The add form |

### Pages

| Spec | What it is |
|---|---|
| [user](user.md) | A user's page, with the For {name} part |
| [list](list.md) | A list's page |
| [item](item.md) | An item's page, with Edit item |
| [gift](gift.md) | A gift's page |
| [people](people.md) | The People page |
| [group](group.md) | A group's page, for the admin |
| [new-user](new-user.md) | The New user form, for the admin |
| [occasions](occasions.md) | The Occasions screen, with a shared occasion's page and form |
| [not-found](not-found.md) | The one "not found" page |

### From Settings

| Spec | What it is |
|---|---|
| [settings](settings.md) | Settings |
| [profile](profile.md) | The profile screen, with the custom occasion form |
| [sign-in-and-devices](sign-in-and-devices.md) | Sign-in and devices, with the login link sheet |
| [reminders-settings](reminders-settings.md) | The Reminders screen |
| [share-diagnostics](share-diagnostics.md) | The Share diagnostics screen |
| [delete-account](delete-account.md) | The Delete account screen |
| [blocked-stores](blocked-stores.md) | Blocked stores, for the admin |
| [acknowledgements](acknowledgements.md) | Acknowledgements |

### System surfaces

| Spec | What it is |
|---|---|
| [countdown-widget](countdown-widget.md) | The countdown widget |
| [reminder](reminder.md) | A reminder |
| [share-extension](share-extension.md) | The share extension |
| [add-item-control](add-item-control.md) | The "Add item" control |
| [app-icon](app-icon.md) | The app icon |

`just lint` checks that this index matches the folder.

## The template

A screen's spec has these nine headings, in this order. Every heading stays. Write "None." under a heading that has nothing to say. A spec has no open questions: an open question is an issue.

```markdown
# The screen's name

## Purpose

What the screen is for, in one or two sentences.

## How you get here, and where you go

A tab, a sheet, or a pushed screen. What opens it, links from outside, and what it opens.

## Content

What the screen shows, in order, with the plain default for the layout.

## States

Loading, empty, and each failure, with what the screen shows from the local copy.

## Windows

A narrow window, a wide window, and several windows. By what the window and the system allow, never by device.

## Actions

Each action, with its button or menu route, and what it does. Nothing is only a drag or only a swipe.

## Words

The exact text for each state and action. Drafts are marked provisional.

## Accessibility

Labels, what VoiceOver reads, and what changes at the largest text sizes.

## Secrecy

Which claim state the screen shows, and to whom. Or "None."
```

A system surface uses the short form:

```markdown
# The surface's name

## Purpose
## What it shows
## What it never shows
## Actions
## States
```

A sheet or a form that belongs to one screen is in that screen's spec, under its own heading inside **Content** or **Actions**.

## What every screen shares

These rules hold on every screen. A screen's spec repeats none of them, and says only where it differs.

### States

- **Loading.** A screen shows what the local copy has at once, with no spinner over saved data (see [Screens read a local copy](../spec.md#screens-read-a-local-copy)). During the first sync after sign-in, a screen with no rows yet shows the system's progress indicator, and fills as rows arrive.
- **Empty.** An empty state shows only after a successful sync found nothing. It says what is missing and what to do next.
- **Can't reach.** When the instance can't be reached, the screen shows what is saved, under the line "Can't reach {address}". The line blocks nothing. A screen with no rows yet shows the unreachable state with Try again, never an empty state. While unsent changes wait, the line adds how many (see [Unsent changes, sign-out, and late refusals](../spec.md#unsent-changes-sign-out-and-late-refusals)).
- **Gone.** A page whose thing is missing or hidden shows the [not-found](not-found.md) page in its place.
- **Signed out.** Signing out, or the API's own 401, replaces every window with the [signed-out](signed-out.md) screen.
- **A late refusal** shows once, as [Late refusals](../spec.md#late-refusals) says.
- **Pull to refresh** works on every screen that scrolls, and syncs everything.

**Provisional.** Plain default: the "Can't reach" line is a row pinned under the navigation bar, the unreachable state and each empty state use the system's unavailable-content view, and Try again is its button.

### Buttons come from the server

- A button shows only when its `can_*` field is `true`. A screen never works out a permission from who the user is.
- A write that is an **unsent change** shows its result at once. A claim, and a raise of a gift's quantity, wait for the server (see [Claims are online only](../spec.md#claims-are-online-only)).
- A name opens that user's page only when the user can see that user. Any other name shows with no link, and nothing says why.
- "Deactivated" shows beside the name of a deactivated user, wherever the viewer gets the user's `deactivated_at`.

### Forms and pickers

- A form or a picker opens as a sheet over the page it belongs to, with Cancel and its main button (Save or Add). The add form is the exception: it is pushed (see [add-form](add-form.md)).
- A sheet never opens a second sheet. A picker inside a form is pushed within that sheet. The system's own sheets are exempt: the camera, the photo picker, and the share sheet.
- A form with typed changes that are not saved asks before it closes, and before its window closes (see [Closing a window](../spec.md#closing-a-window)).
- A 422 `invalid_input` marks the fields that the server's `errors` names.

### Windows

- **A narrow window** has the tab bar. **A wide window** has the sidebar. The set of places is the same (see [Tabs that become a sidebar](../spec.md#tabs-that-become-a-sidebar)).
- A screen's content keeps a readable width in a wide window. A live resize keeps the screen's place and its scroll position.
- **Several windows**, where the system allows them: every window is the whole app, and every window shows a change at once, because all read the one local copy.
- With a pointer, controls use the system's hover effects. A context menu also opens with a secondary click.

**Provisional.** Plain default: system layouts at every size, and no layout of the app's own for a wide window.

### Keyboard shortcuts

With a hardware keyboard, on every screen behind the tabs. Each shortcut repeats an action that also has a button or a menu item, and each shows in the system's shortcut list.

| Keys | Action |
|---|---|
| Command-N | Add item: opens the Add screen with its field ready |
| Command-1, Command-2, Command-3 | Home, Lists, Gifts |
| Command-R | Sync now, as pull to refresh does |
| Command-comma | Settings |
| Return | The form's main button |
| Escape | Cancel a sheet |

There is no cut, copy, or paste of items.

### Web links

Every web link opens in the default browser (see [Web links](../spec.md#web-links)). A row that is a web link has the link-out arrow, and VoiceOver reads its words followed by "opens in browser".

**Provisional.** The words "opens in browser", and the symbol. Plain default: `arrow.up.right`.

### Accessibility

The rules for every screen are in [Accessibility](../spec.md#accessibility). A screen's spec adds only what is its own: what a row reads as one element, which actions a row has, and what stacks at the largest text sizes.

### Words for error codes

The app shows its own words for each error code of the API, never the server's `detail` (see [Words](../spec.md#words)). For a code that is not in this table and not in the screen's spec, the app shows the server's `detail`.

**Provisional.** Every line in this table is a draft.

| Code | The app's words |
|---|---|
| `forbidden`, `field_not_writable` | "You can't do this any more." |
| `not_found`, `reference_not_found`, `reference_not_allowed` | "This is gone, or it isn't shared with you." |
| `user_deactivated` | "Only the admin can reactivate {name}. Until then, you can't change anything for {name}." |
| `invalid_input` | "Some fields need another look.", with each named field marked |
| `rate_limited`, from a search, Add link, or Refresh prices | "You've read 30 links and photos in the last hour. Try again later." |
| `rate_limited`, from anything else | "Too many tries. Wait a minute, then try again." |
| `request_too_large`, `image_too_large` | "That photo is too large. Choose a smaller one." |
| `image_invalid` | "Wishbone can't use that file. Choose a JPEG, PNG, GIF, or WebP photo." |
| `image_fetch_failed` | "One picture couldn't be saved, so the item was added without it." |
| `store_blocked` | "Links from {store} are blocked on this Wishbone." |
| `too_many_store_links` | "An item can have 10 store links." |
| `too_many_images` | "An item can have 5 photos." |
| `cannot_edit_target_list` | "You can't add to {list} any more." |
| `item_fully_claimed` | "Someone else just got this." |
| `recipient_cannot_claim` | "You can't claim on a list that is for you." |
| `quantity_raise_not_allowed` | "You can only lower how many, because this list is now for you too." |
| `occasion_not_allowed` | "That occasion can't be used for this gift. Pick another." |
| `occasion_locked` | "The occasion for this gift can't be changed." |
| `gift_given` | "This gift was already given." |
| `last_recipient` | "You're the only recipient of {list}, so you can't leave it. You can delete it." |
| `list_has_other_recipients` | "{list} has other recipients now, so it can't be deleted. You can leave it." |
| `primary_list` | "You can't do this to a primary list." |
| `birthday_required` | "A birthday is required." |
| `birthday` | "A birthday can't be deleted." |
| `admin_has_no_parents` | "The admin can't have parents." |
| `admin_cannot_be_deactivated` | "The admin can't be deactivated." |
| `occasion_is_everyone` | "This occasion is for everyone, so it takes no groups." |
| `parent_loop`, `group_loop` | The server's `detail` |

- These codes count as success, and show nothing: `already_claimed`, `already_invited`, `already_recipient`, `already_in_group`, `already_attached`, and `already_blocked`.
- These codes have their own screens or lines: `unauthorized` (signed out), `api_version_removed` ([version-block](version-block.md)), and `login_link_invalid` ([signed-out](signed-out.md)).
- A 5xx is "Can't reach {address}".
- A code that only a fault in the app can cause (`unknown_filter`, `unknown_sort`, `cursor_mismatch`, `image_attached`, `resource_changed`) shows "Something went wrong in Wishbone. Try again."
