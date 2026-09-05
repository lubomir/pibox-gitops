# Fail2ban on Traefik

This document explains how the fail2ban middleware is set up in this cluster, how
it behaves, and what was learned from investigating its logs.

## What it is

A Traefik plugin middleware implementing fail2ban-style banning based on HTTP
status codes. It counts "failed" requests per client IP and temporarily bans an
IP once a threshold is reached.

Plugin: https://github.com/tomMoulard/fail2ban

## Configuration

Two middleware instances exist, both `fail2ban` plugin configs:

| Middleware | Namespace | File | Notes |
|---|---|---|---|
| `global-fail2ban` | `traefik` | `clusters/pibox/apps/traefik/middleware-fail2ban.yaml` | Strict, used by most apps |
| `grafana-fail2ban` | `grafana` | `clusters/pibox/apps/grafana/middleware-fail2ban.yaml` | Same rules + relaxed for Grafana API |

## How the middleware is attached

Each middleware is referenced explicitly from the Ingress that should use it via
the Traefik ingress annotation:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: traefik-global-fail2ban@kubernetescrd
```

Qualified middleware references are `<namespace>-<name>@kubernetescrd`, e.g. the
`global-fail2ban` middleware in the `traefik` namespace is
`traefik-global-fail2ban@kubernetescrd`, and `grafana-fail2ban` in the `grafana`
namespace is `grafana-grafana-fail2ban@kubernetescrd`.

## Key behavior

### Ban state is per-router, not global

Even though the middleware is defined once, Traefik instantiates a fail2ban
instance per router (= per host). Each instance keeps its **own in-memory map of
banned IPs**. Consequences:

- A ban triggered on one host does **not** affect other hosts.
- Ban state is lost whenever the Traefik pod restarts or is rolled.

### Two kinds of log lines

Both are logged by the plugin when Traefik log level is INFO:

- `"reason":"status code ban"` — the request that *triggered* the ban: the
  backend responded with a status code in `statuscode` and this was the retry
  that crossed `maxretry` within `findtime`.
- `"reason":"banned"` — a subsequent request that was refused because the IP is
  already banned. It is answered with `429`.

So a ban always starts with one `status code ban` line followed by many
`banned` lines until the `bantime` expires. What happened before the ban is not
logged by traefik.

### Where to look

Traefik logs (the plugin writes structured JSON):

```bash
kubectl -n traefik logs deploy/my-traefik | grep FailToBan
```

Access logs from the backend apps are useful to cross-check, they might show
whether a request actually reached the app (meaning it was not blocked by the
middleware). Traefik's access log is not enabled in this cluster, so the plugin
lines are the only Traefik-side record.

### What this means operationally

- A 24h ban on an app that a human uses regularly (e.g. opening weight-watcher
  tabs that 404 on stale links) will look like an outage. Before assuming
  misconfiguration, check the Traefik logs for a `status code ban` from the
  affected IP, then look at the request path/status that triggered it.
- Internal traffic is exempted via the `allowlist`; a client behind the cluster
  network should never be banned.
