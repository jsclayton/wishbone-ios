import SwiftUI
import WishboneSession

/// A plain screen that stands in for Home until the tabs are built: the titles of the items on the user's primary
/// list, read from the local copy. Its states are the ones that every screen shares (see "What every screen
/// shares" in `docs/screens/README.md`).
struct HomeStandInScreen: View {
  let session: SessionModel

  var body: some View {
    NavigationStack {
      List {
        if session.isInstanceUnreachable, session.primaryList != nil {
          // The line blocks nothing: what is saved shows under it.
          cantReach
        }
        ForEach(session.primaryListItems) { item in
          Text(item.title)
        }
      }
      .overlay {
        if session.primaryList == nil {
          if session.isInstanceUnreachable { unreachable } else { ProgressView() }
        } else if session.primaryListItems.isEmpty {
          ContentUnavailableView {
            Text("Nothing on this list yet.", bundle: #bundle)
          }
        }
      }
      .navigationTitle(Text(session.primaryList?.name ?? session.user?.name ?? ""))
      .refreshable { await session.sync() }
    }
  }

  private var cantReach: some View {
    Text("Can't reach \(session.session.instance.text)", bundle: #bundle)
      .foregroundStyle(.secondary)
  }

  /// A screen with no rows yet shows the unreachable state with Try again, never an empty state.
  private var unreachable: some View {
    ContentUnavailableView {
      Label {
        Text("Can't reach \(session.session.instance.text)", bundle: #bundle)
      } icon: {
        Image(systemName: "wifi.slash")
      }
    } actions: {
      Button {
        Task { await session.sync() }
      } label: {
        Text("Try again", bundle: #bundle)
          .frame(minHeight: 44)
      }
    }
  }
}
