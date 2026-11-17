---
status: accepted
---

# Tabs that become a sidebar, and one kind of window

The app has three fixed tabs: Home, Lists, and Gifts. In a narrow window they are a tab bar at the bottom. In a wide window they become a sidebar, from the same declaration (SwiftUI's `TabView` with `.sidebarAdaptable`). The set of places never changes with the window's size. Adding is the system's search slot at the end of the tab bar, and Settings is a sheet from the avatar. The app has one kind of window: every window is the whole app, with its own tab and its own place. **Open in New Window** opens a whole-app window with the page on top of Home, as a link from outside does.

Navigation shapes every screen, and several windows with drag and drop between them are a first-release feature, so this structure can't be added late. Apple's Human Interface Guidelines name two kinds of window: a primary window, which "presents the main navigation and content of an app", and an auxiliary window, which is "dedicated to one experience" and "doesn't allow navigation to other app areas". A whole-app window is a primary window.

## Considered Options

- **One list of everything, with no tab bar.** Rejected, in favor of a few fixed places that a wide window can show as a sidebar.
- **Three tabs under a tab bar at the top, with occasions first.** Rejected. Home already leads with the next occasion, and the tabs follow the jobs that people do: giving, keeping their lists, and their gifts.
- **A list-only window for Open in New Window.** Rejected. It is an auxiliary window with no way to reach another list, so two lists side by side need two different kinds of window.
- **A People tab.** Not taken. People are on Home and in the sidebar. A People tab is the fix if reaching a person on a narrow window turns out to be too far.

## Consequences

- No tab for people, Settings, or the admin. Admin work lives on full screens reached from People and Coming up, and in one Settings section.
- A link from outside always opens its page on top of Home, in the window used last. Lists and Gifts keep their place.
- Sidebar-only rows must be hidden in a narrow window, or the tab bar grows a "More" tab.
- Every rule about windows goes by what the window and the system allow, never by the device. iPad and the iPhone Duo both allow several windows.
