# Backend Security Audit — Sample Report

> **This is an example report for a fictional game ("Crystal Miners Simulator").** It shows the format and depth of a real audit deliverable. No real game, studio or player is described here.

| | |
|---|---|
| **Client** | Example Studio (fictional) |
| **Experience** | Crystal Miners Simulator (fictional) |
| **Scope** | Server scripts, RemoteEvents/RemoteFunctions, data layer, shop & trading, Developer Products |
| **Out of scope** | Client-side anti-cheat, UI, game design, load testing |
| **Method** | Static code review of the place file + review in a private test server. No testing on the live game. |
| **Auditor** | Omar Ben Najem |
| **Date** | YYYY-MM-DD |
| **Version** | 1.0 |

---

## 1. Executive summary

The game's core loop is solid, but its **economy is currently exploitable**. We found **2 critical**, **3 high**, **2 medium** and **2 low** severity issues.

The two critical issues allow (1) **duplicating any item through fast server hops** and (2) **buying any shop item for free** by sending a custom price. Both are trivial to reproduce with public exploit tools and are very likely already known to part of the player base: they match the "duped items" and "infinite gems" reports in the game's Discord.

**Recommended priority:** fix C-1 and C-2 before the next update or event. Fixing all critical and high issues is estimated at **[X] days** of work.

### Findings overview

| ID | Title | Severity | Effort |
|---|---|---|---|
| C-1 | Player data has no session lock (server-hop dupe) | 🔴 Critical | M |
| C-2 | Shop trusts the price sent by the client | 🔴 Critical | S |
| H-1 | Trade completion yields between validation and swap | 🟠 High | M |
| H-2 | `ProcessReceipt` grants before saving and is not idempotent | 🟠 High | S |
| H-3 | No rate limiting on `MineCrystal` remote | 🟠 High | S |
| M-1 | Remote arguments not type-checked (NaN / huge strings accepted) | 🟡 Medium | S |
| M-2 | Teleport-to-shop not checked server-side | 🟡 Medium | S |
| L-1 | Errors in remote handlers are not logged | 🔵 Low | S |
| L-2 | Autosave writes all players at once (budget spikes) | 🔵 Low | S |

**Severity scale**
- 🔴 **Critical** — direct, easy economy or data compromise; fix immediately.
- 🟠 **High** — exploitable with moderate effort or significant player impact.
- 🟡 **Medium** — exploitable in specific conditions, or a building block for a larger exploit.
- 🔵 **Low** — hardening, observability, robustness.

**Effort:** S < ½ day · M ½–2 days · L > 2 days

---

## 2. Detailed findings

### C-1 — Player data has no session lock (server-hop dupe)

**Severity:** 🔴 Critical · **Location:** `ServerScriptService.DataManager`, lines 12–48

**Description**
Player data is loaded with `GetAsync` on join and saved with `SetAsync` on leave. Nothing records which server currently owns a player's data.

**Impact**
A player who trades or drops an item and immediately rejoins another server loads the old record, where the item still exists. The same race causes progress rollbacks when a late save overwrites newer data.

**Reproduction (test server only)**
1. Give item to an alt account.
2. Rejoin into a new server within a few seconds.
3. The item is present on both accounts.

**Recommendation**
Move to session-locked data: `UpdateAsync`-based load that refuses a live foreign lock, lock heartbeat on autosave, ownership check before every write, lock released on leave and in `BindToClose`. Migrate existing records without a wipe (lock field added on first load).

**Status:** Open

---

### C-2 — Shop trusts the price sent by the client

**Severity:** 🔴 Critical · **Location:** `ShopHandler`, `BuyItem.OnServerEvent`

**Description**
The `BuyItem` remote receives `(itemName, price)` and deducts `price` from the player's coins.

**Impact**
An exploit can call `BuyItem:FireServer("LegendaryPickaxe", 0)` and receive any item for free. A negative price *adds* coins.

**Recommendation**
Remove `price` from the remote. Read prices from a server-side catalog, validate `itemName` against the catalog keys, and check balance, ownership limit and shop proximity on the server.

**Status:** Open

---

### H-1 — Trade completion yields between validation and swap

**Severity:** 🟠 High · **Location:** `TradeService:Complete()`

**Description**
After both players confirm, the code validates both inventories, then calls `WaitForChild` on each character before swapping items.

**Impact**
During that yield, a second request can modify an inventory (sell/drop the same item), leading to items existing in two places or negative stacks.

**Recommendation**
Perform validation and swap in one non-yielding block. Use unique item ids, a trade ledger, and save both players right after completion.

**Status:** Open

---

### H-2 — `ProcessReceipt` grants before saving and is not idempotent

**Severity:** 🟠 High · **Location:** `MarketplaceHandler`

**Description**
`ProcessReceipt` adds gems and returns `PurchaseGranted` immediately. PurchaseIds are not stored.

**Impact**
Server crash after grant → paid gems lost (refund requests, bad reviews). Duplicate callback → gems granted twice.

**Recommendation**
Store PurchaseIds in player data, save grant + PurchaseId together, return `PurchaseGranted` only after a successful save, and `NotProcessedYet` if data isn't loaded.

**Status:** Open

---

### H-3 — No rate limiting on `MineCrystal`

**Severity:** 🟠 High · **Location:** `MiningService`

**Description / Impact**
The remote can be fired hundreds of times per second. Auto-farm scripts mine at 50× normal speed, inflating the crystal supply.

**Recommendation**
Per-player token-bucket rate limit sized to the real tool speed, plus a server-side check that the targeted ore exists, is in range and is not on cooldown.

**Status:** Open

---

### M-1 — Remote arguments not type-checked

**Severity:** 🟡 Medium · **Location:** 11 remotes (see appendix)

**Description / Impact**
Arguments are used without type checks. `NaN` passed as a quantity bypasses `<`/`>` comparisons; very long strings are stored in DataStores and can push records toward the size limit.

**Recommendation**
Central validation layer: exact arity, type, range, length, finite numbers, strict table shapes.

**Status:** Open

---

### M-2 — Shop proximity not checked server-side

**Severity:** 🟡 Medium · **Location:** `ShopHandler`

**Recommendation**
Check the distance between the character and a tagged shop part on the server before any purchase.

**Status:** Open

---

### L-1 — Handler errors not logged

**Recommendation:** wrap handlers in `xpcall` with traceback and forward to your logging (webhook or analytics).

### L-2 — Autosave burst

**Recommendation:** stagger autosaves across the interval to stay within DataStore request budgets.

---

## 3. Remediation plan

| Phase | Items | Goal |
|---|---|---|
| **Immediate** (before next update) | C-1, C-2 | Stop active dupe and free-buy exploits |
| **Short term** (≤ 2 weeks) | H-1, H-2, H-3 | Secure trading, purchases and farming |
| **Hardening** | M-1, M-2, L-1, L-2 | Defense in depth and observability |
| **After fixes** | Duplicate-uid scan | Detect and clean items duped before the fix |

---

## 4. Appendix

- List of remotes reviewed and their validation status
- Code references (file / line) for each finding
- Retest results (filled in after fixes)

---

*This audit reflects the code provided on the review date. It is not a guarantee that no other vulnerability exists. No exploit was run against the live experience or real players.*
