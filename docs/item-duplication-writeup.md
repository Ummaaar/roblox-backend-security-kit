# How item duplication happens on Roblox, and how to prevent it

*Omar Ben Najem — Roblox backend security*

Duplication ("duping") is the exploit that hurts a game the most. A single working dupe floods the economy with rare items, crashes their trade value, and pushes honest players out. Most dupes don't need a cheat engine at all: they abuse **timing gaps in how the game saves data.**

This write-up covers the four most common dupe families, why they work, and the fix for each. Reference code: [Roblox Backend Security Kit](../README.md).

---

## 1. The server-hop dupe (missing session lock)

**The classic.** Most "dupe methods" shared on YouTube are a variant of this one.

### How it works

1. Player is on **Server A** with a rare item.
2. Player gives the item to a friend (or drops/sells it), then immediately teleports or rejoins into **Server B**.
3. Server A starts saving the player's data on `PlayerRemoving`. The DataStore write takes time, or fails and is retried.
4. Server B loads the player's data **before Server A's save landed**. B reads the *old* record, where the item is still in the inventory.
5. The item now exists twice: once with the friend, once back in the player's inventory.

The same gap, in the other direction, causes **rollbacks**: Server A's late save overwrites the progress the player already made on Server B.

### Why naive code is vulnerable

```lua
-- Vulnerable pattern
Players.PlayerAdded:Connect(function(player)
    data[player] = store:GetAsync(key) -- reads whatever is there, no ownership
end)
Players.PlayerRemoving:Connect(function(player)
    store:SetAsync(key, data[player]) -- blind overwrite, no ownership check
end)
```

`GetAsync` + `SetAsync` have no notion of *who currently owns* this record.

### The fix: session locking

- The record stores a **lock**: which server and which session own it, plus a heartbeat timestamp.
- **Load** is an `UpdateAsync` that only succeeds if there is no lock, or the lock is stale (owner server crashed). Otherwise the new server **waits and retries** instead of reading stale data.
- **Every save** is an `UpdateAsync` that first checks the lock is still ours. If not, we **refuse to write** and end the session.
- **Leaving** clears the lock in the same write as the final save, so the next server can load as soon as the data is safe.

See [`SessionStore.luau`](../src/server/Data/SessionStore.luau).

---

## 2. The trade dupe (non-atomic transfers)

### How it works

A trade touches **two records** (two players, two keys). A DataStore can't write two keys atomically. If the server crashes or a save fails *between* the two writes:

- Player A's save (item removed) fails, player B's save (item added) succeeds → **dupe**.
- Or the reverse → **item lost**, angry players, support tickets.

Exploiters provoke this on purpose by forcing disconnects or server overload at the right moment.

### The fix

- Give every item a **unique id (uid)** at creation. Inventories hold records, not counters: `{ uid, itemId, acquiredAt }`.
- Execute trades **server-side, in memory, with no yield** between "both sides validated" and "both sides swapped".
- Record each trade in a **ledger** (trade id, both parties, item uids) and store the trade id in both records. On load, reconcile against the ledger.
- Periodically **scan for duplicate uids** across your data (analytics job): two records sharing a uid = proof of a dupe, and you know exactly which item and when.

---

## 3. The double-spend (yield between check and mutate)

### How it works

```lua
-- Vulnerable pattern
remote.OnServerEvent:Connect(function(player, itemId)
    if data.coins >= price then
        local ok = someYieldingCheck(player) -- WaitForChild, InvokeClient, HTTP, DataStore...
        data.coins -= price
        giveItem(player, itemId)
    end
end)
```

An exploit fires the remote 20 times in the same frame. Every call passes `coins >= price` **before** any of them deducts, because each one yields in the middle. The player gets 20 items for the price of one, and ends with a negative balance.

### The fix

- **Check, deduct and grant with no yield in between.** Luau runs a script on a single thread: code that does not yield cannot be interleaved.
- **Rate-limit** the remote, so a burst of 20 calls is cut down to a few.
- Never let the client send the price. Read it from a **server-side catalog**.

See [`ShopService.luau`](../src/server/Commerce/ShopService.luau) and [`RemoteGuard.luau`](../src/server/Net/RemoteGuard.luau).

---

## 4. The receipt dupe (non-idempotent `ProcessReceipt`)

### How it works

Roblox can call `ProcessReceipt` **more than once** for the same purchase: after a crash, a timeout, or when the player rejoins. If the game grants every time it's called, a single paid purchase can be granted several times. The opposite bug is just as bad: returning `PurchaseGranted` **before** saving means a crash loses something the player paid real money for.

### The fix

- Store processed **PurchaseIds** in the player's data. Already in the list → don't grant again.
- Write the grant **and** the PurchaseId in the **same record, same save**. They are persisted together or lost together: never a double grant, never a lost purchase.
- Return `PurchaseGranted` **only after** that save succeeded. Data not loaded yet → `NotProcessedYet`, Roblox will retry.

See [`ReceiptHandler.luau`](../src/server/Commerce/ReceiptHandler.luau).

---

## Checklist for your game

- [ ] Player data uses session locking (custom or a proven library). No `GetAsync`/`SetAsync` pair on player data.
- [ ] Every save checks ownership before writing.
- [ ] Items have unique ids; inventories are records, not counters.
- [ ] Trades are server-side, no-yield, logged in a ledger.
- [ ] Every remote validates argument types, ranges and arity.
- [ ] Every remote is rate-limited per player.
- [ ] Prices, rewards and cooldowns live on the server.
- [ ] No yield between "check balance" and "deduct balance".
- [ ] `ProcessReceipt` is idempotent and saves before acknowledging.
- [ ] Duplicate-uid scans or economy anomaly alerts are in place.

---

If you're seeing dupes, rollbacks or economy anomalies in your game and want a second pair of eyes, I offer fixed-price backend security audits. Contact: Discord **umar6113** · Email **omarbenn.pro@gmail.com**
