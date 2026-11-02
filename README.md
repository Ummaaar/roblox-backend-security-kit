# Roblox Backend Security Kit

Production-minded reference implementations of the server-side systems that most often break in growing Roblox games: **remote validation, rate limiting, session-locked player data and idempotent purchases.**

Built and maintained by **Omar Ben Najem** — systems & network administrator, specializing in Roblox backend security (anti-exploit, anti-dupe, data reliability).

> Available for audits and backend work. See [Hire me](#hire-me).

---

## What's inside

| Module | Problem it solves |
|---|---|
| [`Validators`](src/shared/Validators.luau) | Exploiters send arbitrary payloads to your remotes: NaN, huge strings, injected table keys, wrong types. Exact-arity, typed, bounded validation for every argument. |
| [`RateLimiter`](src/shared/RateLimiter.luau) | Remote spam (auto-clickers, exploit loops). Token bucket: tolerates honest bursts, caps sustained abuse. |
| [`RemoteGuard`](src/server/Net/RemoteGuard.luau) | One entry point for every client → server event: rate limit → validate → protected handler → violation scoring with decay and optional kick. |
| [`SessionStore`](src/server/Data/SessionStore.luau) | Data rollbacks and **item duplication** caused by fast server hops. Session locking, lock heartbeat, stale-lock recovery, lock-loss detection, schema migrations, staggered autosave, safe shutdown. |
| [`ReceiptHandler`](src/server/Commerce/ReceiptHandler.luau) | Double grants and lost Developer Product purchases. Idempotent `ProcessReceipt`: grant + PurchaseId persisted atomically before acknowledging. |
| [`ShopService`](src/server/Commerce/ShopService.luau) | Client-controlled prices, teleport-buying and double-spend. Server-side catalog, proximity check, no-yield check-and-deduct, unique item ids. |

Write-up: **[How item duplication happens on Roblox, and how to prevent it](docs/item-duplication-writeup.md)**
Sample deliverable: **[Security audit report (example)](docs/sample-audit-report.md)**

---

## Design principles

1. **The client is untrusted.** It can only *request*. The server owns prices, balances, cooldowns and positions.
2. **Validate shape, then validate state.** A well-typed request can still be illegitimate (wrong position, not owned, on cooldown).
3. **Never overwrite fresher data.** Every save proves it still owns the session lock.
4. **Persist before you acknowledge.** A purchase is granted only once its record is saved.
5. **No yield between check and mutate.** Luau is single-threaded per script; a yield in the middle is where double-spends live.

---

## Getting started

Toolchain (via [Rokit](https://github.com/rojo-rbx/rokit)):

```bash
rokit add rojo-rbx/rojo
rokit add Kampfkarren/selene
rokit add JohnnyMorganz/StyLua
```

Run:

```bash
rojo serve            # then connect from the Rojo plugin in Roblox Studio
selene src            # lint
stylua src tests      # format
```

In Studio: **Game Settings → Security → Enable Studio Access to API Services** (required for DataStores), and tag at least one part `Shop` to try the example shop (press **B** near it).

### Tests

The pure modules are unit-tested outside Roblox with the [Luau CLI](https://github.com/luau-lang/luau/releases):

```bash
luau tests/run.luau
```

---

## Layout

```
src/
├─ shared/                 → ReplicatedStorage.Shared
│  ├─ Validators.luau
│  ├─ RateLimiter.luau
│  └─ Config/Catalog.luau  (server-authoritative prices)
├─ server/                 → ServerScriptService.Server
│  ├─ init.server.luau     (bootstrap)
│  ├─ Net/RemoteGuard.luau
│  ├─ Data/SessionStore.luau, DefaultData.luau
│  └─ Commerce/ShopService.luau, ReceiptHandler.luau
└─ client/                 → StarterPlayerScripts.Client
tests/run.luau
docs/
```

---

## Known limits (on purpose)

- **Cross-player trades** are not included: two players' records live under two keys, so a trade cannot be one atomic DataStore write. Doing it safely needs a trade ledger and reconciliation on load (covered in the write-up).
- `SessionStore` is intentionally small and readable. For very large games, a battle-tested library such as ProfileStore is a valid choice; the point here is to show the mechanics.

---

## Hire me

I help Roblox studios and game owners with:

- **Security audit** — remotes, server authority, economy, dupe vectors, data layer. Fixed price, prioritized report.
- **Hardening & fixes** — implementing the audit's recommendations.
- **Data migration** — moving to session-locked data without losing player progress.
- **Ongoing maintenance** — exploit monitoring and fixes on a monthly retainer.

Contact: Discord **umar6113** · Email **omarbenn.pro@gmail.com** · [GitHub](https://github.com/Ummaaar)

---

MIT License — see [LICENSE](LICENSE).
