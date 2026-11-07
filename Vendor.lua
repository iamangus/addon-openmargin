local addonName, ns = ...

-- Vendor Flip: scan the Auction House for auctions whose buyout is below the
-- item's vendor sell value, rank them by percent margin, and buy the best
-- affordable deal. Commodities are bought one item at a time through the same
-- secure proxy as Buy Orders. Non-commodity auctions are opened in the native
-- Buy tab for the final Buyout click.

local SEARCH_DELAY = 0.7
local SEARCH_TIMEOUT = 10
local SUMMARY_TIMEOUT = 15
local QUOTE_TIMEOUT = 15
local PURCHASE_TIMEOUT = 30
local ROW_HEIGHT = 30

local SORTS = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

ns.vendor = ns.vendor or {
	scanState = "idle",
	deals = {},
	status = "Scan the Auction House to find vendor deals.",
}
ns.vendorSpent = ns.vendorSpent or 0

local function inCombat()
	return _G.InCombatLockdown and _G.InCombatLockdown() or false
end

local function itemName(itemID)
	local info = ns.GetItemInfo(itemID)
	if info and info.name then return info.name end
	return "item:" .. tostring(itemID)
end

local function itemSellPrice(itemID)
	local info = ns.GetItemInfo(itemID)
	local price = info and tonumber(info.sellPrice)
	if price and price > 0 then return price end
	return nil
end

function ns.GetVendorCap()
	local cap = ns.db and ns.db.settings and tonumber(ns.db.settings.vendorCap) or 0
	if cap < 0 then cap = 0 end
	return cap
end

function ns.GetVendorRemaining()
	local money = ns.GetBuyMoney()
	local remaining = money
	local cap = ns.GetVendorCap()
	if cap > 0 then
		local capLeft = cap - (ns.vendorSpent or 0)
		if capLeft < 0 then capLeft = 0 end
		if not remaining or capLeft < remaining then remaining = capLeft end
	end
	return remaining or 0
end

function ns.ComputeCommodityDeal(deal)
	if not deal or not deal.sellPrice then return false end
	local remaining = ns.GetVendorRemaining()
	local quantity, cost = 0, 0
	local tiers = deal.tiers or {}
	for index = 1, #tiers do
		local tier = tiers[index]
		if tier.unitPrice >= deal.sellPrice then break end
		local affordable = math.floor((remaining - cost) / tier.unitPrice)
		if affordable <= 0 then break end
		local take = math.min(tier.quantity, affordable)
		quantity = quantity + take
		cost = cost + take * tier.unitPrice
	end
	deal.quantity = quantity
	deal.cost = cost
	deal.vendorValue = quantity * deal.sellPrice
	deal.profit = deal.vendorValue - cost
	deal.margin = cost > 0 and deal.profit / cost or nil
	return quantity > 0 and deal.profit > 0
end

function ns.VendorDeals()
	local vendor = ns.vendor
	local remaining = ns.GetVendorRemaining()
	local list = {}
	for index = 1, #vendor.deals do
		local deal = vendor.deals[index]
		if deal.kind == "commodity" then
			if ns.ComputeCommodityDeal(deal) then
				list[#list + 1] = deal
			end
		elseif deal.kind == "item" then
			if not deal.opened and deal.profit > 0 and deal.buyout <= remaining then
				list[#list + 1] = deal
			end
		end
	end
	table.sort(list, function(lhs, rhs)
		local left = lhs.margin or 0
		local right = rhs.margin or 0
		if left ~= right then return left > right end
		return (lhs.profit or 0) > (rhs.profit or 0)
	end)
	vendor.currentDeals = list
	return list
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function refreshVendorFrame()

	local vendor = ns.vendor
	local frame = ns.vendorFrame
	if not frame then return end
	if not frame:IsShown() then
		if ns.vendorSecureButton and not inCombat() then ns.vendorSecureButton:Hide() end
		return
	end

	local deals = ns.VendorDeals()
	local cap = ns.GetVendorCap()
	local remaining = ns.GetVendorRemaining()
	local money = ns.GetBuyMoney()

	if ns.vendorCapBox and not ns.vendorCapBox:HasFocus() then
		ns.vendorCapBox:SetText(cap > 0 and ns.FormatMoneyInput(cap) or "")
	end

	if vendor.status then
		ns.vendorStatus:SetText(vendor.status)
	end
	local capText = "Cap: " .. (cap > 0 and ns.FormatMoneyInput(cap) or "none")
		.. "   Left: " .. ns.FormatMoneyInput(remaining)
		.. "   Money: " .. ns.FormatMoneyInput(money or 0)
	if vendor.scanState == "scanning" then
		capText = "Scanning...   " .. capText
	end
	ns.vendorSummary:SetText(capText)

	local top = deals[1]
	local normal = ns.vendorActionButton
	local secure = ns.vendorSecureButton

	local showSecure = false
	local activeScan = vendor.scanState == "scanning" or vendor.scanState == "ready"
	if vendor.pending then
		showSecure = false
	elseif not inCombat() and activeScan and top and top.kind == "commodity" then
		local target = ns.GetNativeBuyTarget()
		if target and ns.ComputeCommodityDeal(top) and top.quantity > 0 then
			showSecure = true
			secure:SetAttribute("clickbutton", target)
			secure:SetText(string.format("Buy %d", top.quantity))
		end
	end

	if showSecure then
		secure:Show()
		normal:Hide()
	else
		if not inCombat() then secure:Hide() end
		normal:Show()
		if vendor.pending then
			normal:SetText("Buying...")
			normal:Disable()
		elseif top and activeScan then
			if top.kind == "item" then
				normal:SetText(string.format("Open next +%d%%", math.floor((top.margin or 0) * 100 + 0.5)))
			else
				normal:SetText(string.format("Buy %d", top.quantity))
			end
			normal:Enable()
		elseif vendor.scanState == "scanning" then
			normal:SetText("Scanning...")
			normal:Disable()
		else
			normal:SetText("Scan")
			normal:Enable()
		end
	end

	ns.vendorStopButton:SetShown(vendor.scanState == "scanning")

	local rows = ns.vendorRows or {}
	for index = 1, #deals do
		local row = rows[index]
		if not row then
			row = ns.CreateVendorRow(ns.vendorContent)
			rows[index] = row
		end
		row.rule = deals[index]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", ns.vendorContent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
		row:SetPoint("TOPRIGHT", ns.vendorContent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))
		row:Show()
		ns.UpdateVendorRow(row, index == 1)
	end
	for index = #deals + 1, #rows do
		rows[index]:Hide()
	end
	ns.vendorContent:SetHeight(math.max(#deals * ROW_HEIGHT, 1))
	ns.vendorEmpty:SetShown(#deals == 0)
end

function ns.RefreshVendorFrame()
	refreshVendorFrame()
end

function ns.ResetVendorState()
	ns.vendor = {
		scanState = "idle",
		deals = {},
		status = "Scan the Auction House to find vendor deals.",
	}
	ns.vendorSpent = 0
	if ns.vendorSecureButton and not inCombat() then ns.vendorSecureButton:Hide() end
	if ns.vendorFrame and ns.vendorFrame:IsShown() then ns.RefreshVendorFrame() end
end

function ns.CreateVendorRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT - 2)

	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.035)
	row.bg = bg

	local function label(x, width, font)
		local text = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
		text:SetPoint("LEFT", row, "LEFT", x, 0)
		text:SetWidth(width)
		text:SetJustifyH("LEFT")
		return text
	end

	row.itemText = label(14, 220)
	row.typeText = label(240, 70)
	row.qtyText = label(310, 50)
	row.costText = label(360, 80)
	row.vendorText = label(440, 80)
	row.profitText = label(520, 80)
	row.marginText = label(610, 70)
	return row
end

function ns.UpdateVendorRow(row, isTop)
	local deal = row.rule
	if not deal then return end
	row.itemText:SetText(deal.name or itemName(deal.itemID))
	row.typeText:SetText(deal.kind == "commodity" and "Commodity" or "Item")
	row.qtyText:SetText(tostring(deal.quantity or deal.count or 0))
	row.costText:SetText(ns.FormatMoneyInput(deal.cost or deal.buyout or 0))
	row.vendorText:SetText(ns.FormatMoneyInput(deal.vendorValue or 0))
	row.profitText:SetText(ns.FormatMoneyInput(deal.profit or 0))
	row.marginText:SetText(deal.margin and string.format("+%d%%", math.floor(deal.margin * 100 + 0.5)) or "—")
	row.bg:SetColorTexture(1, 1, 1, isTop and 0.10 or 0.035)
end

-- ---------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------

local function resetScan()
	local vendor = ns.vendor
	vendor.scanState = "scanning"
	vendor.deals = {}
	vendor.candidates = {}
	vendor.seenItems = {}
	vendor.currentDeals = {}
	vendor.candidateIndex = 0
	vendor.searchItem = nil
	vendor.scanPaused = false
	vendor.searchToken = (vendor.searchToken or 0) + 1
	vendor.scanToken = (vendor.scanToken or 0) + 1
	vendor.summaryComplete = false
	vendor.searchComplete = false
	vendor.browseRequests = 0
	vendor.summaryStarted = GetTime()
	vendor.status = "Requesting auction summary..."
	ns.vendorSpent = 0
end

function ns.StartVendorScan()
	if ns.vendor.scanState == "scanning" then return end
	resetScan()
	ns.RefreshVendorFrame()

	local api = _G.C_AuctionHouse
	if not api or type(api.SendBrowseQuery) ~= "function" then
		ns.vendor.scanState = "idle"
		ns.vendor.status = "Auction house browse API unavailable"
		ns.RefreshVendorFrame()
		return
	end

	local query = {
		searchString = "",
		filters = {},
		itemClassFilters = {},
		sorts = SORTS,
	}
	local ok = pcall(api.SendBrowseQuery, query)
	log("vendor scan browse query ok=%s", tostring(ok))
	if not ok then
		ns.vendor.scanState = "idle"
		ns.vendor.status = "Auction house browse query failed"
		ns.RefreshVendorFrame()
		return
	end

	local token = ns.vendor.scanToken
	ns.After(1, function()
		if token == ns.vendor.scanToken then ns.ProcessVendorBrowseResults(token) end
	end)
end

function ns.StopVendorScan()
	if ns.vendor.scanState ~= "scanning" then return end
	ns.vendor.scanToken = (ns.vendor.scanToken or 0) + 1
	ns.vendor.scanState = "idle"
	ns.vendor.searchItem = nil
	ns.vendor.status = "Scan cancelled"
	if not inCombat() then ns.DisableNativeBuy() end
	ns.RefreshVendorFrame()
end

function ns.ProcessVendorBrowseResults(token)
	local vendor = ns.vendor
	if token ~= vendor.scanToken or vendor.scanState ~= "scanning" or vendor.summaryComplete then return end

	local api = _G.C_AuctionHouse
	local results = {}
	if api and type(api.GetBrowseResults) == "function" then
		local ok, value = pcall(api.GetBrowseResults)
		if ok and type(value) == "table" then results = value end
	end

	for index = 1, #results do
		local result = results[index]
		local itemKey = result.itemKey
		local itemID = itemKey and itemKey.itemID
		local variantKey = itemID and string.format("%d:%d:%d:%d",
			itemID, tonumber(itemKey.itemLevel) or 0, tonumber(itemKey.itemSuffix) or 0,
			tonumber(itemKey.battlePetSpeciesID) or 0) or nil
		if variantKey and not vendor.seenItems[variantKey] then
			vendor.seenItems[variantKey] = true
			local minPrice = tonumber(result.minPrice)
			local sellPrice = itemSellPrice(itemID)
			if minPrice and sellPrice and minPrice > 0 and minPrice < sellPrice then
				local keyInfo
				if type(api.GetItemKeyInfo) == "function" then
					local ok, value = pcall(api.GetItemKeyInfo, itemKey)
					if ok then keyInfo = value end
				end
				vendor.candidates[#vendor.candidates + 1] = {
					itemID = itemID,
					itemKey = {
						itemID = itemID,
						itemLevel = tonumber(itemKey.itemLevel) or 0,
						itemSuffix = tonumber(itemKey.itemSuffix) or 0,
						battlePetSpeciesID = tonumber(itemKey.battlePetSpeciesID) or 0,
					},
					minPrice = minPrice,
					sellPrice = sellPrice,
					isCommodity = keyInfo and keyInfo.isCommodity == true or false,
				}
			end
		end
	end

	local full = true
	if api and type(api.HasFullBrowseResults) == "function" then
		local ok, value = pcall(api.HasFullBrowseResults)
		if ok then full = value == true end
	end

	if not full and vendor.browseRequests < 20 then
		vendor.browseRequests = vendor.browseRequests + 1
		if api.RequestMoreBrowseResults then pcall(api.RequestMoreBrowseResults) end
		ns.After(0.7, function()
			if token == vendor.scanToken then ns.ProcessVendorBrowseResults(token) end
		end)
		return
	end

	if not full and (GetTime() - (vendor.summaryStarted or 0)) < SUMMARY_TIMEOUT then
		ns.After(0.7, function()
			if token == vendor.scanToken then ns.ProcessVendorBrowseResults(token) end
		end)
		return
	end

	vendor.summaryComplete = true
	vendor.status = string.format("Scanning candidates (%d)...", #vendor.candidates)
	ns.RefreshVendorFrame()

	table.sort(vendor.candidates, function(lhs, rhs)
		local left = (lhs.sellPrice - lhs.minPrice) / lhs.minPrice
		local right = (rhs.sellPrice - rhs.minPrice) / rhs.minPrice
		return left > right
	end)
	vendor.candidateIndex = 0
	ns.RunNextVendorSearch(token)
end

function ns.RunNextVendorSearch(token)
	local vendor = ns.vendor
	if token ~= vendor.scanToken or vendor.scanState ~= "scanning" then return end
	if vendor.pending or vendor.scanPaused then
		ns.After(0.4, function() ns.RunNextVendorSearch(token) end)
		return
	end
	if vendor.searchItem then return end

	vendor.candidateIndex = (vendor.candidateIndex or 0) + 1
	local candidate = vendor.candidates[vendor.candidateIndex]
	if not candidate then
		vendor.searchComplete = true
		vendor.scanState = "ready"
		vendor.status = string.format("Ready: %d affordable deals", #ns.VendorDeals())
		log("vendor scan complete deals=%d", #ns.VendorDeals())
		ns.RefreshVendorFrame()
		return
	end

	local api = _G.C_AuctionHouse
	if not api or type(api.SendSearchQuery) ~= "function" or type(api.MakeItemKey) ~= "function" then
		vendor.scanState = "idle"
		vendor.status = "Auction house search API unavailable"
		ns.RefreshVendorFrame()
		return
	end

	local itemKey = candidate.itemKey
	if not itemKey then
		local ok, value = pcall(api.MakeItemKey, candidate.itemID)
		if not ok or not value then
			ns.After(SEARCH_DELAY, function() ns.RunNextVendorSearch(token) end)
			return
		end
		itemKey = value
	end

	vendor.searchItem = candidate
	vendor.searchAt = GetTime()
	vendor.searchToken = (vendor.searchToken or 0) + 1
	local searchToken = vendor.searchToken
	vendor.status = string.format("Searching %s (%d/%d)...", itemName(candidate.itemID), vendor.candidateIndex, #vendor.candidates)
	ns.RefreshVendorFrame()

	local sent = pcall(api.SendSearchQuery, itemKey, SORTS, false)
	log("vendor search itemID=%s ok=%s", tostring(candidate.itemID), tostring(sent))
	if not sent then
		vendor.searchItem = nil
		ns.After(SEARCH_DELAY, function() ns.RunNextVendorSearch(token) end)
		return
	end

	ns.After(SEARCH_TIMEOUT, function()
		if vendor.scanToken == token and vendor.searchToken == searchToken and vendor.searchItem == candidate then
			vendor.searchItem = nil
			log("vendor search timeout itemID=%s", tostring(candidate.itemID))
			ns.After(SEARCH_DELAY, function() ns.RunNextVendorSearch(token) end)
		end
	end)
end

local function finishVendorSearch()
	local vendor = ns.vendor
	vendor.searchItem = nil
	if not vendor.pending then ns.RefreshVendorFrame() end
	local token = vendor.scanToken
	ns.After(SEARCH_DELAY, function() ns.RunNextVendorSearch(token) end)
end

function ns.BuildCommodityVendorDeal(candidate)
	local api = _G.C_AuctionHouse
	local itemID = candidate.itemID
	local count = 0
	if type(api.GetNumCommoditySearchResults) == "function" then
		local ok, value = pcall(api.GetNumCommoditySearchResults, itemID)
		if ok and type(value) == "number" then count = value end
	end
	local tiers = {}
	for index = 1, count do
		local infoOk, info = pcall(api.GetCommoditySearchResultInfo, itemID, index)
		if infoOk and type(info) == "table" and type(info.unitPrice) == "number" then
			if info.unitPrice < candidate.sellPrice then
				local own = tonumber(info.numOwnerItems) or 0
				local quantity = (tonumber(info.quantity) or 0) - own
				if quantity > 0 then
					tiers[#tiers + 1] = { unitPrice = info.unitPrice, quantity = quantity }
				end
			end
		end
	end
	if #tiers > 0 then
		table.sort(tiers, function(lhs, rhs) return lhs.unitPrice < rhs.unitPrice end)
		local deal = {
			kind = "commodity",
			itemID = itemID,
			name = itemName(itemID),
			sellPrice = candidate.sellPrice,
			tiers = tiers,
		}
		if ns.ComputeCommodityDeal(deal) then
			ns.vendor.deals[#ns.vendor.deals + 1] = deal
			log("vendor commodity deal itemID=%s qty=%d cost=%d profit=%d margin=%s", tostring(itemID), deal.quantity, deal.cost, deal.profit, tostring(deal.margin))
		end
	end
end

function ns.BuildItemVendorDeals(candidate)
	local api = _G.C_AuctionHouse
	local itemKey = candidate.itemKey
	if not itemKey then
		local ok, value = pcall(api.MakeItemKey, candidate.itemID)
		if not ok or not value then return end
		itemKey = value
	end
	local count = 0
	if type(api.GetNumItemSearchResults) == "function" then
		local valueOk, value = pcall(api.GetNumItemSearchResults, itemKey)
		if valueOk and type(value) == "number" then count = value end
	end
	for index = 1, count do
		local infoOk, info = pcall(api.GetItemSearchResultInfo, itemKey, index)
		if infoOk and type(info) == "table" then
			local buyout = tonumber(info.buyoutAmount)
			local quantity = tonumber(info.quantity)
			if buyout and quantity and buyout > 0 and quantity > 0
				and not info.containsOwnerItem and not info.containsAccountItem then
				local vendorValue = candidate.sellPrice * quantity
				local profit = vendorValue - buyout
				if profit > 0 then
					local deal = {
						kind = "item",
						itemID = candidate.itemID,
						itemKey = itemKey,
						name = itemName(candidate.itemID),
						sellPrice = candidate.sellPrice,
						count = quantity,
						buyout = buyout,
						vendorValue = vendorValue,
						profit = profit,
						margin = profit / buyout,
						auctionID = info.auctionID,
					}
					ns.vendor.deals[#ns.vendor.deals + 1] = deal
					log("vendor item deal itemID=%s qty=%d buyout=%d profit=%d margin=%s", tostring(candidate.itemID), quantity, buyout, profit, tostring(deal.margin))
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Action and purchase
-- ---------------------------------------------------------------------------

local function topDeal()
	local deals = ns.VendorDeals()
	return deals[1]
end

function ns.OpenVendorItem(deal)
	if not deal or deal.kind ~= "item" then return end
	local api = _G.C_AuctionHouse
	local ah = _G.AuctionHouseFrame
	deal.opened = true
	ns.vendor.scanPaused = true
	ns.vendor.status = string.format("Open %s: %d x %s buyout in the native Buy tab",
		deal.name or itemName(deal.itemID), deal.count or 0, ns.FormatMoneyInput(deal.buyout or 0))
	ns.RefreshVendorFrame()

	local itemKey = deal.itemKey
	if not itemKey then
		local keyOk, value = pcall(api.MakeItemKey, deal.itemID)
		if keyOk then itemKey = value end
	end
	if itemKey then
		pcall(api.SendSearchQuery, itemKey, SORTS, false)
		if ah and ah.ItemBuyFrame and type(ah.ItemBuyFrame.SetItemKey) == "function" then
			pcall(ah.ItemBuyFrame.SetItemKey, ah.ItemBuyFrame, itemKey)
		end
	end
	if ah and _G.AuctionHouseFrameDisplayMode and type(ah.SetDisplayMode) == "function" then
		pcall(ah.SetDisplayMode, ah, _G.AuctionHouseFrameDisplayMode.ItemBuy)
	end
end

function ns.OnVendorAction()
	local vendor = ns.vendor
	if vendor.scanState == "idle" then
		ns.StartVendorScan()
		return
	end
	if vendor.scanState ~= "scanning" and vendor.scanState ~= "ready" then return end

	local deal = topDeal()
	if not deal then
		if vendor.scanState == "ready" then ns.StartVendorScan() end
		return
	end
	if deal.kind == "item" then
		ns.OpenVendorItem(deal)
	else
		vendor.status = "Use the native buy button for commodities"
		ns.RefreshVendorFrame()
	end
end

function ns.BeginVendorBuy()
	local vendor = ns.vendor
	if vendor.pending then
		if ns.vendorSecureButton then ns.vendorSecureButton:SetAttribute("clickbutton", nil) end
		return
	end
	if ns.buyPending then
		vendor.status = "Another purchase is already in progress"
		ns.RefreshVendorFrame()
		return
	end
	ns.DisableNativeBuy()
	local deal = topDeal()
	if not deal or deal.kind ~= "commodity" or not ns.ComputeCommodityDeal(deal) then return end

	local remaining = ns.GetVendorRemaining()
	if deal.quantity <= 0 or deal.cost <= 0 or deal.cost > remaining then
		vendor.status = "Not enough room in the budget"
		ns.RefreshVendorFrame()
		return
	end

	local plan = {
		itemID = deal.itemID,
		quantity = deal.quantity,
		cost = deal.cost,
		maxUnit = deal.sellPrice,
	}
	local pending = {
		deal = deal,
		plan = plan,
		phase = "quote",
		startedAt = GetTime(),
	}
	vendor.pending = pending
	vendor.status = "Checking price..."
	local target = ns.PrepareNativeBuy(plan)
	if not target then
		vendor.pending = nil
		vendor.status = "Native auction buy button unavailable"
		ns.RefreshVendorFrame()
		return
	end

	if ns.vendorSecureButton then ns.vendorSecureButton:SetText("Buying...") end
	log("vendor armed itemID=%s qty=%d cost=%d", tostring(plan.itemID), plan.quantity, plan.cost)

	ns.After(QUOTE_TIMEOUT, function()
		if vendor.pending == pending and pending.phase == "quote" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			if ns.HideBuyDialog then ns.HideBuyDialog() end
			vendor.pending = nil
			vendor.status = "No response from the auction house"
			ns.RefreshVendorFrame()
		end
	end)

	ns.After(PURCHASE_TIMEOUT, function()
		if vendor.pending == pending then
			vendor.pending = nil
			vendor.status = "Purchase result unknown"
			ns.RefreshVendorFrame()
		end
	end)
end

function ns.HandleVendorPrice(unitPrice, totalPrice)
	local vendor = ns.vendor
	local pending = vendor.pending
	if not pending or pending.phase ~= "quote" then return end
	if type(unitPrice) ~= "number" or type(totalPrice) ~= "number" then return end
	local plan = pending.plan
	local deal = pending.deal
	local remaining = ns.GetVendorRemaining()
	local within = unitPrice < deal.sellPrice
		and totalPrice <= plan.cost
		and totalPrice <= remaining
	log("vendor quote unit=%s total=%s sell=%s planCost=%s remaining=%s within=%s", tostring(unitPrice), tostring(totalPrice), tostring(deal.sellPrice), tostring(plan.cost), tostring(remaining), tostring(within))

	if not within then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		if ns.HideBuyDialog then ns.HideBuyDialog() end
		vendor.pending = nil
		for index = #vendor.deals, 1, -1 do
			if vendor.deals[index] == deal then table.remove(vendor.deals, index) end
		end
		vendor.status = "Price no longer profitable - skipped"
		ns.RefreshVendorFrame()
		return
	end

	pending.phase = "buy"
	pending.actualCost = totalPrice
	pending.unitPrice = unitPrice
	vendor.status = "Buying..."
	local confirmed, err = pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, plan.itemID, plan.quantity)
	log("vendor confirm ok=%s err=%s", tostring(confirmed), tostring(err))
	if not confirmed then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		if ns.HideBuyDialog then ns.HideBuyDialog() end
		vendor.pending = nil
		vendor.status = "Purchase could not be confirmed"
		ns.RefreshVendorFrame()
	end
end

function ns.HandleVendorPurchaseSucceeded()
	local vendor = ns.vendor
	local pending = vendor.pending
	if not pending then return end
	local deal = pending.deal
	local cost = tonumber(pending.actualCost) or pending.plan.cost or 0
	local quantity = pending.plan.quantity or 0
	ns.vendorSpent = (ns.vendorSpent or 0) + cost
	vendor.pending = nil

	for index = #vendor.deals, 1, -1 do
		if vendor.deals[index] == deal then table.remove(vendor.deals, index) end
	end
	vendor.status = string.format("Bought %d for %s (profit %s)", quantity, ns.FormatMoneyInput(cost), ns.FormatMoneyInput((deal.sellPrice or 0) * quantity - cost))
	log("vendor purchase success itemID=%s qty=%d cost=%d spent=%d", tostring(deal.itemID), quantity, cost, ns.vendorSpent)
	ns.RefreshVendorFrame()
end

function ns.HandleVendorPurchaseFailed()
	local vendor = ns.vendor
	if not vendor.pending then return end
	vendor.pending = nil
	if ns.HideBuyDialog then ns.HideBuyDialog() end
	vendor.status = "Purchase failed"
	ns.RefreshVendorFrame()
end

function ns.HandleVendorUnavailable()
	local vendor = ns.vendor
	if not vendor.pending or vendor.pending.phase ~= "quote" then return end
	pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
	if ns.HideBuyDialog then ns.HideBuyDialog() end
	vendor.pending = nil
	vendor.status = "No stock at a profitable price"
	ns.RefreshVendorFrame()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function ns.OnVendorEvent(event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		ns.SetupVendorTab()
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ns.IsAuctionHouseOpen() then ns.SetupVendorTab() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if ns.vendorSecureHidePending then
			ns.vendorSecureHidePending = false
			if ns.vendorSecureButton then ns.vendorSecureButton:Hide() end
		end
		if ns.vendorFrame and ns.vendorFrame:IsShown() then ns.RefreshVendorFrame() end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if ns.vendorSecureButton then
			if inCombat() then
				ns.vendorSecureHidePending = true
			else
				ns.vendorSecureButton:Hide()
			end
		end
		if ns.vendor.pending and ns.vendor.pending.phase == "quote" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			ns.vendor.pending = nil
		end
		ns.vendor.scanState = "idle"
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		if ns.vendor.scanState == "scanning" and not ns.vendor.summaryComplete then
			ns.ProcessVendorBrowseResults(ns.vendor.scanToken)
		end
	elseif event == "COMMODITY_SEARCH_RESULTS_ADDED" or event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if ns.vendor.searchItem and ns.vendor.searchItem.itemID == itemID then
			local candidate = ns.vendor.searchItem
			ns.BuildCommodityVendorDeal(candidate)
			finishVendorSearch()
		end
	elseif event == "ITEM_SEARCH_RESULTS_ADDED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
		local itemKey = ...
		local itemID = type(itemKey) == "table" and itemKey.itemID or nil
		if ns.vendor.searchItem and ns.vendor.searchItem.itemID == itemID then
			local candidate = ns.vendor.searchItem
			ns.BuildItemVendorDeals(candidate)
			finishVendorSearch()
		end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		local unitPrice, totalPrice = ...
		ns.HandleVendorPrice(unitPrice, totalPrice)
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		ns.HandleVendorUnavailable()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		ns.HandleVendorPurchaseSucceeded()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		ns.HandleVendorPurchaseFailed()
	elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
		local code = tonumber((...)) or ...
		if ns.vendor.pending then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			if ns.HideBuyDialog then ns.HideBuyDialog() end
			ns.vendor.pending = nil
			ns.vendor.status = code == 10 and "Auction house busy - click again" or "Auction house error - click again"
			ns.RefreshVendorFrame()
		elseif ns.vendor.scanState == "scanning" then
			ns.vendor.status = code == 10 and "Auction house busy - click again" or "Scan error - click again"
			ns.RefreshVendorFrame()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Auction House tab and frame
-- ---------------------------------------------------------------------------

local function getLibAHTab()
	local libStub = _G.LibStub
	if type(libStub) ~= "table" or type(libStub.GetLibrary) ~= "function" then return nil end
	local ok, lib = pcall(libStub.GetLibrary, libStub, "LibAHTab-1-0", true)
	if ok and type(lib) == "table" and type(lib.CreateTab) == "function" then return lib end
	return nil
end

function ns.ResumeVendorScanIfNeeded()
	local vendor = ns.vendor
	if vendor.scanState == "scanning" and vendor.scanPaused then
		vendor.scanPaused = false
		ns.RunNextVendorSearch(vendor.scanToken)
	end
end

function ns.SelectVendorTab()
	local ah = _G.AuctionHouseFrame
	if not ah or not ns.vendorFrame then return false end
	if ns.vendorTabLib then
		local ok = pcall(ns.vendorTabLib.SetSelected, ns.vendorTabLib, "OpenMarginVendorFlip")
		ns.ResumeVendorScanIfNeeded()
		return ok
	end

	ah:SetDisplayMode({})
	ah.displayMode = nil
	local tabs = ah.Tabs or {}
	for index = 1, #tabs do PanelTemplates_DeselectTab(tabs[index]) end
	if ns.ahTab then PanelTemplates_DeselectTab(ns.ahTab) end
	if ns.vendorAhTab then PanelTemplates_SelectTab(ns.vendorAhTab) end
	ah:SetTitle("Vendor Flip")
	if ns.buyFrame then ns.buyFrame:Hide() end
	ns.vendorFrame:Show()
	ns.RefreshVendorFrame()
	ns.ResumeVendorScanIfNeeded()
	return true
end

function ns.SetupVendorTab()
	local ah = _G.AuctionHouseFrame
	if not ah then return false end
	if not ns.vendorFrame then ns.CreateVendorFrame(ah) end
	if ns.vendorTabCreated then return true end

	local lib = getLibAHTab()
	if lib then
		local ok = pcall(lib.CreateTab, lib, "OpenMarginVendorFlip", ns.vendorFrame, "Vendor Flip", "Vendor Flip")
		if ok then
			ns.vendorTabLib = lib
			ns.vendorTabCreated = true
			return true
		end
	end

	if not ah.Tabs or #ah.Tabs == 0 then return false end

	local root = CreateFrame("Frame", nil, ah)
	root:SetSize(10, 10)
	local anchor = ns.ahTab or ah.Tabs[#ah.Tabs]
	if not ns.ahTab then
		local auctionatorTabs = _G.Auctionator and _G.Auctionator.State and _G.Auctionator.State.TabFrameRef
			and _G.Auctionator.State.TabFrameRef.Tabs
		if type(auctionatorTabs) == "table" and #auctionatorTabs > 0 then
			anchor = auctionatorTabs[#auctionatorTabs]
		end
	end
	root:SetPoint("TOPLEFT", anchor, "TOPRIGHT")

	local created, tab = pcall(CreateFrame, "Button", "OpenMarginVendorFlipTab", root, "AuctionHouseFrameDisplayModeTabTemplate")
	if not created or not tab then return false end
	tab:SetText("Vendor Flip")
	PanelTemplates_TabResize(tab, 20, nil, 70)
	tab:SetPoint("TOPLEFT", root, "TOPLEFT", 3, 0)
	PanelTemplates_DeselectTab(tab)
	tab.frameRef = ns.vendorFrame
	tab.tabHeader = "Vendor Flip"
	tab:SetScript("OnClick", ns.SelectVendorTab)
	ns.vendorAhTab = tab
	ns.vendorTabRoot = root

	hooksecurefunc(ah, "SetDisplayMode", function(_, mode)
		if mode ~= nil and #mode > 0 then
			if ns.vendorFrame then ns.vendorFrame:Hide() end
			if ns.vendorAhTab then PanelTemplates_DeselectTab(ns.vendorAhTab) end
		end
	end)

	ns.vendorTabCreated = true
	return true
end

function ns.OpenVendorFlip()
	if not ns.IsAuctionHouseOpen() then
		ns.Print("Open the Auction House first; Vendor Flip is a tab there.")
		return
	end
	if ns.SetupVendorTab() then ns.SelectVendorTab() end
end

function ns.CreateVendorFrame(ah)
	if ns.vendorFrame then return ns.vendorFrame end
	ah = ah or _G.AuctionHouseFrame
	if not ah then return nil end

	local frame = CreateFrame("Frame", "OpenMarginVendorFrame", ah, "InsetFrameTemplate")
	if ah.CategoriesList then
		frame:SetPoint("TOPLEFT", ah.CategoriesList, "TOPLEFT", 0, 0)
	else
		frame:SetPoint("TOPLEFT", ah, "TOPLEFT", 4, -70)
	end
	frame:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -23, 34)
	frame:SetFrameLevel(ah:GetFrameLevel() + 5)
	frame:Hide()
	ns.vendorFrame = frame
	ns.vendor = ns.vendor or { scanState = "idle", deals = {}, status = "Scan the Auction House to find vendor deals." }
	ns.vendor.deals = ns.vendor.deals or {}
	ns.vendorRows = {}
	ns.vendorSpent = 0

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
	title:SetText("Vendor Flip")
	ns.vendorTitle = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	hint:SetWidth(540)
	hint:SetJustifyH("LEFT")
	hint:SetText("Finds auctions that vendor for more than their buyout. Scan, then use the same button to buy the best margin. Cap resets each scan.")

	local capLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	capLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60)
	capLabel:SetText("Spend cap:")
	ns.vendorCapLabel = capLabel

	local capBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	capBox:SetSize(90, 20)
	capBox:SetPoint("LEFT", capLabel, "RIGHT", 6, 0)
	capBox:SetAutoFocus(false)
	capBox:SetMaxLetters(20)
	capBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	capBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	capBox:SetScript("OnEditFocusLost", function(self)
		local value = ns.ParseMoneyInput(self:GetText())
		if not value or value < 0 then value = 0 end
		ns.db.settings.vendorCap = value
		self:SetText(value > 0 and ns.FormatMoneyInput(value) or "")
		ns.RefreshVendorFrame()
	end)
	ns.vendorCapBox = capBox

	local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	status:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -82)
	status:SetWidth(560)
	status:SetJustifyH("LEFT")
	ns.vendorStatus = status

	local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	summary:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -98)
	summary:SetWidth(720)
	summary:SetJustifyH("LEFT")
	summary:SetTextColor(0.75, 0.75, 0.75)
	ns.vendorSummary = summary

	local action = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	action:SetSize(110, 24)
	action:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -10)
	action:SetText("Scan")
	action:SetScript("OnClick", function() ns.OnVendorAction() end)
	ns.vendorActionButton = action

	local stop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	stop:SetSize(54, 24)
	stop:SetPoint("TOPRIGHT", action, "TOPLEFT", -6, 0)
	stop:SetText("Stop")
	stop:SetScript("OnClick", function() ns.StopVendorScan() end)
	stop:Hide()
	ns.vendorStopButton = stop

	local secure = CreateFrame("Button", nil, _G.UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
	secure:SetSize(110, 24)
	secure:SetPoint("TOPRIGHT", action, "TOPRIGHT", 0, 0)
	secure:SetFrameStrata("DIALOG")
	secure:SetFrameLevel(100)
	secure:SetAttribute("type", "click")
	secure:RegisterForClicks("AnyUp", "AnyDown")
	secure:Hide()
	secure:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then ns.BeginVendorBuy() end
	end)
	secure:HookScript("PostClick", function()
		ns.After(0, function() ns.RefreshVendorFrame() end)
	end)
	ns.vendorSecureButton = secure

	local headers = {
		{ text = "Item", x = 14, width = 220 },
		{ text = "Type", x = 240, width = 70 },
		{ text = "Qty", x = 310, width = 50 },
		{ text = "Cost", x = 360, width = 80 },
		{ text = "Vendor", x = 440, width = 80 },
		{ text = "Profit", x = 520, width = 80 },
		{ text = "Margin", x = 610, width = 70 },
	}
	for index = 1, #headers do
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", frame, "TOPLEFT", headers[index].x, -120)
		label:SetWidth(headers[index].width)
		label:SetText(headers[index].text)
		label:SetTextColor(0.8, 0.8, 0.8)
	end

	local scroll = CreateFrame("ScrollFrame", "OpenMarginVendorScrollFrame", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -136)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 10)
	ns.vendorScroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(700, 1)
	scroll:SetScrollChild(content)
	ns.vendorContent = content

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("CENTER", scroll, "CENTER", 0, 20)
	empty:SetText("No vendor deals yet. Click Scan.")
	ns.vendorEmpty = empty

	frame:SetScript("OnShow", function() ns.RefreshVendorFrame() end)
	frame:SetScript("OnHide", function()
		if ns.vendorSecureButton then
			if inCombat() then
				ns.vendorSecureHidePending = true
			else
				ns.vendorSecureButton:Hide()
			end
		end
	end)

	ns.RefreshVendorFrame()
	return frame
end

local vendorEventFrame = CreateFrame("Frame")
local vendorEvents = {
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"PLAYER_ENTERING_WORLD",
	"PLAYER_REGEN_ENABLED",
	"AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"COMMODITY_SEARCH_RESULTS_ADDED",
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_ADDED",
	"ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED",
	"COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED",
	"COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_SHOW_ERROR",
}
for index = 1, #vendorEvents do
	pcall(vendorEventFrame.RegisterEvent, vendorEventFrame, vendorEvents[index])
end
vendorEventFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnVendorEvent, event, ...)
	if not ok then ns.ReportError(err) end
end)
