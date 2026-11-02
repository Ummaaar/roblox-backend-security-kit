--[[
	Client example. The client only REQUESTS; the server decides.
	Press B near a part tagged "Shop" to try buying a Wooden Sword.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestPurchase = Remotes:WaitForChild("RequestPurchase") :: RemoteEvent
local purchaseResult = Remotes:WaitForChild("PurchaseResult") :: RemoteEvent

purchaseResult.OnClientEvent:Connect(function(result)
	if result.ok then
		print(`Bought {result.itemId}`)
	else
		print(`Purchase refused: {result.code}`)
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.B then
		requestPurchase:FireServer("WoodenSword")
	end
end)
