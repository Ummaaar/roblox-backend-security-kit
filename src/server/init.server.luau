--[[
	Server bootstrap: wires the data layer, the shop and receipt processing.
]]

local SessionStore = require(script.Data.SessionStore)
local DefaultData = require(script.Data.DefaultData)
local ShopService = require(script.Commerce.ShopService)
local ReceiptHandler = require(script.Commerce.ReceiptHandler)

local store = SessionStore.new({
	name = "PlayerData_v1",
	template = DefaultData,
	schemaVersion = 1,
	migrations = {
		-- [2] = function(data) data.gems = 0 return data end,
	},
	onLoaded = function(session)
		local data = session.Data
		data.stats.joins += 1
		if data.stats.firstJoin == 0 then
			data.stats.firstJoin = os.time()
		end
	end,
})

ShopService.init(store)
ReceiptHandler.init(store, ShopService.productHandlers())

store:Start()
