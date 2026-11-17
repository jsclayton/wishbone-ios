---
status: accepted
---

# Plain-HTTP instances are accepted

The app accepts any `http` or `https` instance address, on any port, with any path. App Transport Security is opened with `NSAllowsArbitraryLoads` in the app and in both extensions. The app shows no warning for an `http` instance. Settings shows the full address with its scheme.

Wishbone is self-hosted. A family can run it on a private network, such as a tailnet, where it is safe over plain HTTP on an IP address and a port, with no domain and no certificate. The server's cookies are always `Secure`, so the web app can't sign in over plain HTTP except on `localhost`. For such an instance, the app is the only way in.

## Considered Options

- **HTTPS only.** Rejected. It shuts out the families whose instance is safe on a private network.
- **The local-network exception only.** Rejected. A tailnet's DNS name is a full host name, so the exception does not cover it.
- **A warning for an `http` instance.** Rejected. The app can't tell a tailnet from the open internet, and the person who scans a link can't act on a warning.

## Consequences

- On an untrusted network, a plain-HTTP instance exposes its traffic, the token included. That is the operator's choice, and it is out of scope for security reports (see [SECURITY.md](../../SECURITY.md)).
- A certificate that the device doesn't trust gets its own message, with no bypass. An operator with a private certificate authority installs it on the device, or serves plain HTTP inside the private network.
- App Review sees the exception, so the review notes explain it.
