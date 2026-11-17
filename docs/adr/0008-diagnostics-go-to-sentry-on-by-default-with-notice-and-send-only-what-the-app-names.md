---
status: accepted
---

# Diagnostics go to Sentry, on by default with notice, and send only what the app names

The app sends **diagnostics** (crash and fault reports) to Sentry, in its EU region. Everything sent is a case of one typed event, from a closed vocabulary, through one file in `WishboneDiagnostics`. Every SDK feature is off unless it is turned on on purpose. Nothing carries **family content**. Diagnostics are on by default, for each device, but the SDK stays off until the sign-in screen has shown a notice line, which opens the switch. Turning them off deletes anything not sent. Neither extension links Sentry. The repo's DSN is empty, so CI and forks send nothing, and the real DSN is only in the maintainer's local configuration.

The app runs against servers that its maintainer can't see. Without reports, a crash on one family's instance is invisible. But the app holds what a family wants to keep private, including what each person is giving, so what leaves the device must be named in code, not filtered after the fact.

## Considered Options

- **Opt-in.** Rejected. It gives far fewer reports, and one more step before a family member reaches their list. Notice plus an easy way to withdraw is the basis Apple's guideline 5.1.1(ii) allows, and GDPR's legitimate interest.
- **No SDK**, with only Apple's reports. Rejected. Apple's crash reports come late and without the app's own faults, such as a response that can't be decoded.
- **A DSN in the repo, with a filter on the bundle ID.** Rejected. Every fork and CI run holds the DSN, and a fork that keeps the bundle ID passes the filter.
- **Sentry in the extensions too.** Rejected. The share extension runs under a memory limit of about 120 MB, starting the SDK costs every share, and the switch and the ID would have to move into the shared container.

## Consequences

- Every new error type picks its side: captured, a breadcrumb, or never. A 5xx, an unreachable instance, and the API's own 401 are never captured.
- A request is reported by method and path template only. A scrubber tested at the envelope is the second net.
- A fitness test holds the single import of Sentry, the app as its only linker, and the app's privacy manifest against the event vocabulary.
- A Debug build sends only when launched with an explicit argument.
- The operator gets no switch for the instance. The README and the [privacy policy](../../PRIVACY.md) tell them what is sent.
