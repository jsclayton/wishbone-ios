---
status: accepted
---

# Writes are a journal of unsent changes that the server decides, and claims are online only

Most writes are **unsent changes**. Each one is saved in a journal with an ID, applied to the local copy at once, and sent in order when the instance answers. Each is an intent, such as "mark bought" or "move this item here", and the server decides it against its current state. A create carries an `Idempotency-Key`, so a resend after a lost answer can't make it twice. A create that later changes refer to gets a local stand-in ID, which the app replaces with the server's ID from the answer. A refusal from the server rolls the change back and shows once. **A claim, and raising a gift's quantity, are never unsent changes:** their button waits for the server's answer. No write sends `If-Match`.

Wishbone's rules are on the server: quantity, the flags on a gift, and what each caller sees. A sync model that copies rows, or merges edits on the device, would have to copy those rules, and they would drift. A giver acts on a claim: they go and buy the thing. A claim made offline and refused later is a double gift.

## Considered Options

- **Row replication**, as CouchDB, WatermelonDB, PowerSync, and Electric do it. Rejected. The client writes rows, and the server's rules become checks after the fact.
- **CRDTs.** Rejected. They merge edits on every device, but Wishbone's edits need the server's rules, not a merge.
- **No queue: every write online.** Rejected. A family on a tailnet loses the instance whenever the VPN is off, and most writes are safe to send later.
- **Claims queued like every other write.** Rejected, because of the double gift. An idempotency key doesn't change this: it stops a duplicate claim, not a refused one.
- **`If-Match` on every write.** Rejected. The `ETag` covers what each caller sees, so it changes for reasons that have nothing to do with the edit (a claim changes a parent's `ETag` on a child's item). Writes would fail for no real conflict, more so after waiting offline. A narrower version that covers only editable fields is not worth a server change and a conflict screen.

## Consequences

- This is the model of client mutations under server authority, as Replicache, Zero, and Linear use it, and as Apple's CKSyncEngine is shaped.
- Each change is a merge patch of only the fields changed, so the last writer wins for each field. If use shows lost edits, this is the decision to revisit.
- Sign-out and the API's own 401 discard every unsent change.
- The journal's tables carry through every database migration, though the copy's tables can be dropped (see [ADR 0005](0005-grdb-is-the-local-database-and-screens-read-only-it.md)).
- The share extension keeps no journal, so it needs the instance to add.
- The app needs a server that takes an `Idempotency-Key` on writes, and that gives a cheap way to keep a copy current. Both are in the minimum server version.
