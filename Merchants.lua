local addonName, ns = ...

-- Blizzard exposes what a vendor pays you (sellPrice) but not what a vendor
-- charges for an arbitrary item. TSM solves this the same way: remember the
-- current prices from the merchant frame whenever a vendor is open.

local function scanMerchant()
	if not _G.C_MerchantFrame or type(_G.C_MerchantFrame.GetItemInfo) ~= "function" then
		return
	end
	local num = 0
	if type(_G.GetMerchantNumItems) == "function" then
		local ok, value = pcall(_G.GetMerchantNumItems)
		if ok and type(value) == "number" then num = value end
	end
	if num <= 0 then return end

	local changed = false
	for index = 1, num do
		local infoOk, info = pcall(_G.C_MerchantFrame.GetItemInfo, index)
		if infoOk and type(info) == "table" then
			local price = tonumber(info.price)
			local stack = tonumber(info.stackCount) or 1
			if stack < 1 then stack = 1 end
			if price and price > 0 and not info.hasExtendedCost then
				local itemID
				if type(_G.GetMerchantItemID) == "function" then
					local idOk, value = pcall(_G.GetMerchantItemID, index)
					if idOk then itemID = value end
				end
				if not itemID and type(_G.GetMerchantItemLink) == "function" then
					local linkOk, link = pcall(_G.GetMerchantItemLink, index)
					if linkOk and link then itemID = ns.GetItemIDFromLink(link) end
				end
				if itemID then
					local unit = math.floor(price / stack + 0.5)
					if unit > 0 and ns.GetVendorBuyPrice(itemID) ~= unit then
						ns.SetVendorBuyPrice(itemID, unit)
						changed = true
					end
				end
			end
		end
	end

	if changed then
		if ns.ClearEconCache then ns.ClearEconCache() end
		if ns.RefreshAll then ns.RefreshAll() end
	end
end

local function scheduleScan()
	if ns.merchantScanScheduled then return end
	ns.merchantScanScheduled = true
	ns.After(0.2, function()
		ns.merchantScanScheduled = false
		scanMerchant()
	end)
end

local frame = CreateFrame("Frame")
pcall(frame.RegisterEvent, frame, "MERCHANT_SHOW")
pcall(frame.RegisterEvent, frame, "MERCHANT_UPDATE")
frame:SetScript("OnEvent", function(_, event)
	if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
		scheduleScan()
	end
end)
