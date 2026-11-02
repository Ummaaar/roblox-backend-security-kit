--[[
	ReceiptHandler
	--------------
	Idempotent Developer Product processing (MarketplaceService.ProcessReceipt).

	Common bugs this avoids:
	  * Granting twice: Roblox may call ProcessReceipt again for the same
	    purchase (server crash, timeout). We store PurchaseIds in the player's
	    data and skip anything already granted.
	  * Granting without saving: returning PurchaseGranted before the grant is
	    persisted means a crash loses what the player paid for. We save first.
	  * Granting before data is loaded: we return NotProcessedYet and Roblox
	    retries later (including on the player's next join).

	The grant and the PurchaseId are written in the SAME record, in the SAME
	UpdateAsync, so they are persisted (or lost) together: no double grant,
	no lost purchase.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local HISTORY_SIZE = 50

-- A product handler mutates session.Data and returns true if it granted.
export type ProductHandler = (session: any, receipt: { [string]: any }) -> boolean

local ReceiptHandler = {}

function ReceiptHandler.init(store: any, handlers: { [number]: ProductHandler })
	MarketplaceService.ProcessReceipt = function(receipt)
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if player == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local session = store:Get(player)
		if session == nil or session.Released then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local history = session.Data.purchaseHistory

		-- Already granted in a previous call: make sure it is persisted, then ack.
		if table.find(history, receipt.PurchaseId) then
			if session:SaveAsync() then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local handler = handlers[receipt.ProductId]
		if handler == nil then
			warn(`[ReceiptHandler] no handler for product {receipt.ProductId}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local ok, granted = pcall(handler, session, receipt)
		if not ok then
			warn(`[ReceiptHandler] handler error for product {receipt.ProductId}: {granted}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if granted ~= true then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Record the purchase in memory right after the grant (no yield in
		-- between), then persist both together.
		table.insert(history, receipt.PurchaseId)
		while #history > HISTORY_SIZE do
			table.remove(history, 1)
		end

		if not session:SaveAsync() then
			-- Grant + PurchaseId stay in memory; the retry path above will
			-- persist them without granting again.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

return ReceiptHandler
