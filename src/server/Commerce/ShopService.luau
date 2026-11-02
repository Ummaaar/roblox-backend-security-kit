--[[
	ShopService
	-----------
	Server-authoritative in-game currency shop. Reference implementation of
	"never trust the client":

	  * The client sends only an item id. Price, currency and limits come
	    from the server-side Catalog.
	  * The server checks the player is actually near a shop (anti teleport-buy).
	  * Check + deduct + grant happen with NO yield in between, so two
	    concurrent requests can't both pass the balance check (double-spend).
	  * Every granted item gets a unique id, so duplicates are detectable.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Validators = require(Shared.Validators)
local Catalog = require(Shared.Config.Catalog)

local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)

local SHOP_TAG = "Shop"

local ShopService = {}

local function countOwned(inventory, itemId: string): number
	local count = 0
	for _, record in inventory do
		if record.itemId == itemId then
			count += 1
		end
	end
	return count
end

local function isNearShop(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	for _, shop in CollectionService:GetTagged(SHOP_TAG) do
		if shop:IsA("BasePart") and (shop.Position - root.Position).Magnitude <= Catalog.ShopInteractionRange then
			return true
		end
	end
	return false
end

function ShopService.init(store)
	local purchaseResult = RemoteGuard.outbound("PurchaseResult")

	local function reply(player: Player, ok: boolean, code: string, itemId: string?)
		purchaseResult:FireClient(player, { ok = ok, code = code, itemId = itemId })
	end

	RemoteGuard.on({
		name = "RequestPurchase",
		args = { Validators.keyOf(Catalog.ShopItems) },
		rateLimit = { capacity = 4, refillPerSecond = 1 },
		kickThreshold = 25,
		handler = function(player: Player, itemId: string)
			local session = store:Get(player)
			if session == nil or session.Released then
				return reply(player, false, "DATA_NOT_READY", itemId)
			end

			if not isNearShop(player) then
				return reply(player, false, "TOO_FAR", itemId)
			end

			-- From here to the grant: NO yielding calls (no WaitForChild,
			-- task.wait, DataStore, HTTP...). Luau runs this atomically.
			local item = Catalog.ShopItems[itemId]
			local data = session.Data

			if item.maxOwned ~= nil and countOwned(data.inventory, itemId) >= item.maxOwned then
				return reply(player, false, "LIMIT_REACHED", itemId)
			end
			if data.coins < item.price then
				return reply(player, false, "INSUFFICIENT_FUNDS", itemId)
			end

			data.coins -= item.price
			table.insert(data.inventory, {
				uid = HttpService:GenerateGUID(false),
				itemId = itemId,
				acquiredAt = os.time(),
			})

			reply(player, true, "OK", itemId)
			-- Persisted by autosave / release. For high-value items, call
			-- session:SaveAsync() here (costs DataStore budget).
		end,
	})
end

-- Handlers for Catalog.DevProducts, consumed by ReceiptHandler.
function ShopService.productHandlers()
	local handlers = {}
	for productId, product in Catalog.DevProducts do
		handlers[productId] = function(session)
			session.Data.coins += product.grantsCoins
			return true
		end
	end
	return handlers
end

return ShopService
