--[[
	DefaultData
	-----------
	Template for a brand-new player. Missing keys are filled in ("reconciled")
	on every load, so you can add fields later without a migration.

	Keep it DataStore-friendly: string keys or pure arrays, no mixed tables,
	no Instances, no NaN/inf, no functions.
]]

return {
	coins = 0,
	-- Each owned item is a record with a unique id (uid). Unique ids make
	-- duplicated items detectable (two records sharing one uid = a dupe).
	inventory = {} :: { { uid: string, itemId: string, acquiredAt: number } },
	-- Last N processed Developer Product PurchaseIds (idempotent receipts).
	purchaseHistory = {} :: { string },
	stats = {
		joins = 0,
		firstJoin = 0,
	},
}
