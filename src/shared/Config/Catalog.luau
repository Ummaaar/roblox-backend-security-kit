--!strict
--[[
	Catalog (single source of truth for prices)
	-------------------------------------------
	Shared so the client can DISPLAY prices, but the server only ever reads
	prices from this module, never from a client argument.
]]

export type ShopItem = {
	displayName: string,
	price: number,
	currency: "Coins",
	maxOwned: number?, -- nil = unlimited
}

export type DevProduct = {
	displayName: string,
	grantsCoins: number,
}

local Catalog = {}

Catalog.ShopItems = {
	WoodenSword = { displayName = "Wooden Sword", price = 100, currency = "Coins", maxOwned = 1 },
	IronSword = { displayName = "Iron Sword", price = 750, currency = "Coins", maxOwned = 1 },
	HealthPotion = { displayName = "Health Potion", price = 25, currency = "Coins", maxOwned = 20 },
} :: { [string]: ShopItem }

-- Replace the keys with your real Developer Product IDs (Creator Hub > Monetization).
Catalog.DevProducts = {
	[0000001] = { displayName = "500 Coins", grantsCoins = 500 },
	[0000002] = { displayName = "2,000 Coins", grantsCoins = 2000 },
} :: { [number]: DevProduct }

-- Max distance (studs) between the player and a part tagged "Shop" to buy.
Catalog.ShopInteractionRange = 15

return Catalog
