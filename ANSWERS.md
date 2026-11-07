# Q1 — Migrating ingress-nginx to Gateway API

I would handle this as a parallel migration and not remove ingress-nginx in one shot.

First, I would inventory all 40 Ingress objects, DNS names, TLS secrets, paths, and nginx-specific annotations. I would group them by risk and identify features such as regex rewrites, authentication, canary routing, timeouts, body-size limits, WebSockets, and custom snippets. These are the areas most likely to behave differently.

Next, I would select a Gateway API controller only after checking that it supports our required features. I would install its CRDs and controller alongside ingress-nginx. The platform team can manage `GatewayClass` and shared `Gateway` listeners, while application teams manage their `HTTPRoute` resources. Cross-namespace access should be restricted and `ReferenceGrant` used only where required.

I would convert the routes in small batches. A conversion tool can give a starting point, but every route needs review and tests for redirects, headers, rewrites, TLS/SNI, gRPC, WebSockets, uploads, and failure cases.

The new Gateway should use a separate address initially. I would test it directly, then move one low-risk hostname using weighted DNS or another traffic-splitting method: 1%, 10%, 50%, and finally 100%. At each stage I would compare errors, latency, logs, and certificates. DNS TTL should be reduced in advance, and ingress-nginx should remain available for quick rollback.

After migrating all applications and observing them for a safe period, I would block new nginx annotations, remove the old Ingress objects, and finally uninstall ingress-nginx. I expect annotation behaviour, regex paths, default backends, source IP handling, TLS ownership, and timeout or retry defaults to cause most issues.
