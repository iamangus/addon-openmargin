local addonName, ns = ...

-- Sniper: watch a short list of high-volume commodities and alert as soon as
-- the cheapest listing is at or below vendor sell + a small spread. Blizzard
-- throttles searches and requires a secure click for the purchase, so this is
-- a fast manual sniper, not an automated buyer.

local QUERY_TIMEOUT = 2.5
local NEXT_DELAY = 0.15
local MIN_QUERY_GAP = 0.6
local QUOTE_TIMEOUT = 15
local PURCHASE_TIMEOUT = 30

local SORTS = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

-- Curated cloth, herb and ore list. Skinning/leather is intentionally absent.
local DEFAULT_WATCHLIST = {
	2589, -- Linen Cloth
	2592, -- Wool Cloth
	4306, -- Silk Cloth
	4338, -- Mageweave Cloth
	14047, -- Runecloth
	2447, -- Peacebloom
	765, -- Silverleaf
	2449, -- Earthroot
	785, -- Mageroyal
	2453, -- Bruiseweed
	3356, -- Kingsblood
	3357, -- Liferoot
	8838, -- Sungrass
	8848, -- Dreamfoil
	2770, -- Copper Ore
	2771, -- Tin Ore
	2772, -- Iron Ore
	3858, -- Mithril Ore
	10620, -- Thorium Ore
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

ns.snipe = ns.snipe or {
	running = false,
	deals = {},
	alerted = {},
	status = "Stopped",
}

local function inCombat()
	return _G.InCombatLockdown and _G.InCombatLockdown() or false
end

local function canQuery()
	if _G.C_AuctionHouse and type(_G.C_AuctionHouse.CanSendAuctionQuery) == "function" then
		local ok, value = pcall(_G.C_AuctionHouse.CanSendAuctionQuery)
		if ok and value ~= nil then return value == true end
	end
	if type(_G.CanSendAuctionQuery) == "function" then
		local ok, value = pcall(_G.CanSendAuctionQuery)
		if ok and value ~= nil then return value == true end
	end
	return true
end

local function playAlert()
	if _G.PlaySound and _G.SOUNDKIT and _G.SOUNDKIT.IG_MAINMENU_OPEN then
		local ok = pcall(_G.PlaySound, _G.SOUNDKIT.IG_MAINMENU_OPEN)
		if ok then return end
	end
	pcall(_G.PlaySoundFile, "Sound\\Interface\\AuctionWindowOpen.ogg")
end

-- ---------------------------------------------------------------------------
-- Watchlist
-- ---------------------------------------------------------------------------

function ns.GetSnipeWatchlist()
	if not ns.db then return {} end
	if type(ns.db.snipeWatchlist) ~= "table" then
		ns.db.snipeWatchlist = {}
		for index = 1, #DEFAULT_WATCHLIST do
			ns.db.snipeWatchlist[index] = DEFAULT_WATCHLIST[index]
		end
	end
	return ns.db.snipeWatchlist
end

local function containsItem(list, itemID)
	for index = 1, #list do
		if list[index] == itemID then return index end
	end
	return nil
end

function ns.AddSnipeItem(itemID)
	itemID = tonumber(itemID)
	if not itemID or itemID <= 0 then return false end
	local list = ns.GetSnipeWatchlist()
	if containsItem(list, itemID) then return false end
	list[#list + 1] = itemID
	if ns.snipe then ns.snipe.watchlistDirty = true end
	if _G.C_Item and type(_G.C_Item.RequestLoadItemDataByID) == "function" then
		pcall(_G.C_Item.RequestLoadItemDataByID, itemID)
	end
	return true
end

function ns.RemoveSnipeItem(itemID)
	itemID = tonumber(itemID)
	local list = ns.GetSnipeWatchlist()
	local index = containsItem(list, itemID)
	if not index then return false end
	table.remove(list, index)
	if ns.snipe then
		ns.snipe.deals[itemID] = nil
		ns.snipe.watchlistDirty = true
	end
	if ns.db and ns.db.settings and tonumber(ns.db.settings.snipeFocus) == itemID then
		ns.db.settings.snipeFocus = 0
	end
	return true
end

function ns.SetSnipeFocus(itemID)
	if not ns.db or not ns.db.settings then return end
	itemID = tonumber(itemID) or 0
	local current = tonumber(ns.db.settings.snipeFocus) or 0
	ns.db.settings.snipeFocus = current == itemID and 0 or itemID
	if ns.RefreshSniperFrame then ns.RefreshSniperFrame() end
end

local function resolveItemID(text)
	text = ns.Trim(tostring(text or ""))
	if text == "" then return nil end
	local linkID = text:match("item:(%d+)")
	if linkID then return tonumber(linkID) end
	local number = tonumber(text)
	if number and number > 0 then return number end
	if _G.C_Item and type(_G.C_Item.GetItemInfoInstant) == "function" then
		local ok, itemID = pcall(_G.C_Item.GetItemInfoInstant, text)
		if ok and type(itemID) == "number" and itemID > 0 then return itemID end
	end
	if type(_G.GetItemInfo) == "function" then
		local ok, _, link = pcall(_G.GetItemInfo, text)
		if ok and type(link) == "string" then
			local id = link:match("item:(%d+)")
			if id then return tonumber(id) end
		end
	end
	return nil
end

function ns.AddSnipeItemFromText(text)
	local itemID = resolveItemID(text)
	if not itemID then
		ns.Print("Sniper: could not resolve that item.")
		return false
	end
	if ns.AddSnipeItem(itemID) then
		if ns.RefreshSniperFrame then ns.RefreshSniperFrame() end
		ns.Print("Sniper: added " .. ns.GetItemName(itemID) .. ".")
		return true
	end
	ns.Print("Sniper: already watching " .. ns.GetItemName(itemID) .. ".")
	return false
end

function ns.RemoveSnipeItemFromText(text)
	local itemID = resolveItemID(text)
	if not itemID then
		ns.Print("Sniper: could not resolve that item.")
		return false
	end
	if ns.RemoveSnipeItem(itemID) then
		if ns.RefreshSniperFrame then ns.RefreshSniperFrame() end
		ns.Print("Sniper: removed " .. ns.GetItemName(itemID) .. ".")
		return true
	end
	ns.Print("Sniper: that item is not being watched.")
	return false
end

-- ---------------------------------------------------------------------------
-- Price evaluation
-- ---------------------------------------------------------------------------

function ns.GetSnipeOver()
	local over = ns.db and ns.db.settings and tonumber(ns.db.settings.snipeOver) or 5
	if over < 0 then over = 0 end
	return over
end

function ns.GetSnipeBudget()
	local budget = ns.db and ns.db.settings and tonumber(ns.db.settings.snipeBudget) or 0
	if budget < 0 then budget = 0 end
	return budget
end

local function buildSnipePlan(deal, limit)
	local quantity, cost, profit = 0, 0, 0
	for index = 1, #deal.tiers do
		local tier = deal.tiers[index]
		if tier.unitPrice > deal.maxPrice then break end
		local affordable = math.floor((limit - cost) / tier.unitPrice)
		if affordable <= 0 then break end
		local take = math.min(tier.quantity, affordable)
		quantity = quantity + take
		cost = cost + take * tier.unitPrice
		profit = profit + take * (deal.resale - tier.unitPrice)
	end
	deal.quantity = quantity
	deal.cost = cost
	deal.profit = profit
	deal.margin = cost > 0 and profit / cost or nil
end

function ns.EvaluateSnipeItem(itemID)
	local state = ns.snipe
	if not state or not itemID then return end

	local vendor = ns.GetVendorSellPrice(itemID)
	if not vendor then
		state.deals[itemID] = nil
		state.alerted[itemID] = nil
		return
	end

	local api = _G.C_AuctionHouse
	local count = 0
	if api and type(api.GetNumCommoditySearchResults) == "function" then
		local ok, value = pcall(api.GetNumCommoditySearchResults, itemID)
		if ok and type(value) == "number" then count = value end
	end
	if count <= 0 then
		state.deals[itemID] = nil
		state.alerted[itemID] = nil
		return
	end

	local maxPrice = vendor + ns.GetSnipeOver()
	local tiers = {}
	local best
	for index = 1, count do
		local ok, info = pcall(api.GetCommoditySearchResultInfo, itemID, index)
		if ok and type(info) == "table" and type(info.unitPrice) == "number" then
			if info.unitPrice > maxPrice then break end
			local own = tonumber(info.numOwnerItems) or 0
			local quantity = (tonumber(info.quantity) or 0) - own
			if quantity > 0 then
				tiers[#tiers + 1] = { unitPrice = info.unitPrice, quantity = quantity }
				if not best or info.unitPrice < best then best = info.unitPrice end
			end
		end
	end
	if #tiers == 0 then
		state.deals[itemID] = nil
		state.alerted[itemID] = nil
		return
	end

	local budget = ns.GetSnipeBudget()
	local money = ns.GetBuyMoney() or math.huge
	local limit = budget > 0 and math.min(budget, money) or money
	local deal = {
		itemID = itemID,
		name = ns.GetItemName(itemID),
		vendor = vendor,
		resale = vendor,
		maxPrice = maxPrice,
		unitPrice = best,
		over = best - vendor,
		tiers = tiers,
	}
	buildSnipePlan(deal, limit)
	if deal.quantity <= 0 or deal.cost <= 0 then
		state.deals[itemID] = nil
		state.alerted[itemID] = nil
		return
	end

	state.deals[itemID] = deal
	-- Arm the buy button before the slower Auctionator market lookup and UI
	-- refresh. The purchase plan only needs the listing tiers and vendor cap.
	if ns.ArmSniperBuy then ns.ArmSniperBuy() end

	local market = ns.GetPrice(itemID)
	local cut = (ns.db and ns.db.settings and tonumber(ns.db.settings.ahCut) or 5) / 100
	deal.market = market
	deal.resale = market and market > 0 and market * (1 - cut) or vendor
	buildSnipePlan(deal, limit)

	if state.alerted[itemID] ~= deal.unitPrice then
		state.alerted[itemID] = deal.unitPrice
		playAlert()
		local marketText = deal.market and ns.FormatMoneyFull(deal.market) or "no market price"
		ns.Print(string.format("Sniper: %s at %s (max %s, market %s, profit %s, %d available)",
			deal.name, ns.FormatMoneyFull(deal.unitPrice), ns.FormatMoneyFull(deal.maxPrice),
			marketText, ns.FormatMoney(deal.profit, true), deal.quantity))
	end
end

-- ---------------------------------------------------------------------------
-- Query loop
-- ---------------------------------------------------------------------------

local function resetRun()
	local state = ns.snipe
	state.running = true
	state.index = 0
	state.awaiting = false
	state.currentItem = nil
	state.queryAt = 0
	state.token = (state.token or 0) + 1
	state.tick = 0
	state.deals = {}
	state.alerted = {}
	state.status = "Starting..."
end

function ns.StartSnipe()
	local state = ns.snipe
	if state.running then return end
	if ns.StopVendorScan then ns.StopVendorScan() end
	if ns.StopDisenchantScan then ns.StopDisenchantScan() end
	resetRun()
	ns.RefreshSniperFrame()
	ns.SnipeTick()
end

function ns.StopSnipe(reason)
	local state = ns.snipe
	state.running = false
	state.token = (state.token or 0) + 1
	state.awaiting = false
	state.currentItem = nil
	state.status = reason or "Stopped"
	if not inCombat() and ns.snipeSecureButton then ns.snipeSecureButton:Hide() end
	ns.RefreshSniperFrame()
end

function ns.SnipeTick()
	local state = ns.snipe
	if not state.running then return end
	if state.pending then
		ns.After(0.3, ns.SnipeTick)
		return
	end
	if not ns.IsAuctionHouseOpen() then
		ns.StopSnipe("Auction house closed")
		return
	end
	if state.awaiting then
		if GetTime() - (state.queryAt or 0) < QUERY_TIMEOUT then
			ns.After(0.2, ns.SnipeTick)
			return
		end
		state.awaiting = false
	end
	if not canQuery() then
		ns.After(0.2, ns.SnipeTick)
		return
	end
	if GetTime() - (state.lastQueryAt or 0) < MIN_QUERY_GAP then
		ns.After(0.15, ns.SnipeTick)
		return
	end

	local list = ns.GetSnipeWatchlist()
	if #list == 0 then
		state.status = "Watchlist is empty - add an item"
		ns.RefreshSniperFrame()
		return
	end

	local settings = ns.db and ns.db.settings or {}
	local focus = tonumber(settings.snipeFocus) or 0
	local focusOnly = settings.snipeFocusOnly == true
	if focus > 0 and not containsItem(list, focus) then
		settings.snipeFocus = 0
		focus = 0
	end
	if focusOnly and focus == 0 then
		state.status = "Focus only is on but no focus item is set"
		ns.RefreshSniperFrame()
		return
	end

	state.tick = (state.tick or 0) + 1
	local itemID, label
	if focus > 0 and (focusOnly or state.tick % 2 == 1) then
		itemID = focus
		label = "focus"
	else
		state.index = (state.index or 0) % #list + 1
		itemID = list[state.index]
		label = string.format("%d/%d", state.index, #list)
	end

	local api = _G.C_AuctionHouse
	if not api or type(api.SendSearchQuery) ~= "function" or type(api.MakeItemKey) ~= "function" then
		ns.StopSnipe("Auction house search API unavailable")
		return
	end
	local ok, itemKey = pcall(api.MakeItemKey, itemID)
	if not ok or not itemKey then
		ns.After(NEXT_DELAY, ns.SnipeTick)
		return
	end

	local token = state.token
	state.awaiting = true
	state.currentItem = itemID
	state.queryAt = GetTime()
	state.lastQueryAt = state.queryAt
	state.status = string.format("Checking %s (%s)...", ns.GetItemName(itemID), label)
	ns.RefreshSniperFrame()

	local sent = pcall(api.SendSearchQuery, itemKey, SORTS, false)
	if not sent then
		state.awaiting = false
		ns.After(0.3, ns.SnipeTick)
		return
	end

	ns.After(QUERY_TIMEOUT, function()
		if state.running and state.token == token and state.awaiting and state.currentItem == itemID then
			state.awaiting = false
			state.currentItem = nil
			ns.SnipeTick()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function snipeDeals()
	local state = ns.snipe
	local list = {}
	for _, deal in pairs(state.deals) do
		list[#list + 1] = deal
	end
	table.sort(list, function(lhs, rhs)
		local left = lhs.unitPrice or math.huge
		local right = rhs.unitPrice or math.huge
		if left ~= right then return left < right end
		return (lhs.profit or 0) > (rhs.profit or 0)
	end)
	state.currentDeals = list
	return list
end

local function topDeal()
	return snipeDeals()[1]
end

-- Fast path: light the buy button as soon as a deal is stored, before the
-- market-price lookup and list redraw.
function ns.ArmSniperBuy()
	local secure = ns.snipeSecureButton
	if not secure or inCombat() then return end
	local deal = topDeal()
	if not deal then return end
	local target = ns.GetNativeBuyTarget()
	if not target then return end
	secure:SetAttribute("clickbutton", target)
	secure:Enable()
	secure:SetAlpha(1)
	secure:Show()
end

local function refreshWatchlist()
	local frame = ns.snipeFrame
	if not frame then return end
	local list = ns.GetSnipeWatchlist()
	local rows = ns.snipeWatchRows or {}
	for index = 1, #list do
		local itemID = list[index]
		local row = rows[index]
		if not row then
			row = CreateFrame("Frame", nil, ns.snipeWatchContent)
			row:SetHeight(20)
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
			row.name:SetWidth(145)
			row.name:SetJustifyH("LEFT")
			row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.remove:SetSize(18, 18)
			row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
			row.remove:SetText("X")
			row.focus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.focus:SetSize(18, 18)
			row.focus:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
			row.focus:SetText("F")
			rows[index] = row
		end
		row.itemID = itemID
		local focused = (tonumber(ns.db and ns.db.settings and ns.db.settings.snipeFocus) or 0) == itemID
		row.name:SetText(ns.GetItemName(itemID))
		row.name:SetTextColor(focused and 1 or 0.9, focused and 0.82 or 0.9, focused and 0 or 0.9)
		row.focus:SetScript("OnClick", function() ns.SetSnipeFocus(itemID) end)
		row.remove:SetScript("OnClick", function()
			ns.RemoveSnipeItem(itemID)
			refreshWatchlist()
			ns.RefreshSniperFrame()
		end)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", ns.snipeWatchContent, "TOPLEFT", 0, -((index - 1) * 20))
		row:SetPoint("TOPRIGHT", ns.snipeWatchContent, "TOPRIGHT", 0, -((index - 1) * 20))
		row:Show()
	end
	for index = #list + 1, #rows do
		rows[index]:Hide()
	end
	ns.snipeWatchContent:SetHeight(math.max(#list * 20, 1))
	if ns.snipeWatchEmpty then ns.snipeWatchEmpty:SetShown(#list == 0) end
	if ns.snipeWatchTitle then ns.snipeWatchTitle:SetText("Watchlist (" .. #list .. ")") end
end

local function refreshDeals()
	local frame = ns.snipeFrame
	if not frame then return end
	local list = snipeDeals()
	local rows = ns.snipeRows or {}
	for index = 1, #list do
		local deal = list[index]
		local row = rows[index]
		if not row then
			row = ns.CreateSniperRow(ns.snipeContent)
			rows[index] = row
		end
		row.deal = deal
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", ns.snipeContent, "TOPLEFT", 0, -((index - 1) * 24))
		row:SetPoint("TOPRIGHT", ns.snipeContent, "TOPRIGHT", 0, -((index - 1) * 24))
		row:Show()
		ns.UpdateSniperRow(row, index == 1)
	end
	for index = #list + 1, #rows do
		rows[index]:Hide()
	end
	ns.snipeContent:SetHeight(math.max(#list * 24, 1))
	ns.snipeEmpty:SetShown(#list == 0)
end

function ns.RefreshSniperFrame()
	local frame = ns.snipeFrame
	if not frame then return end
	if not frame:IsShown() then
		if ns.snipeSecureButton and not inCombat() then ns.snipeSecureButton:Hide() end
		return
	end

	local state = ns.snipe
	local list = ns.GetSnipeWatchlist()
	local over = ns.GetSnipeOver()
	local budget = ns.GetSnipeBudget()
	local money = ns.GetBuyMoney()

	if ns.snipeOverBox and not ns.snipeOverBox:HasFocus() then
		ns.snipeOverBox:SetText(over > 0 and ns.FormatMoneyInput(over) or "")
	end
	if ns.snipeBudgetBox and not ns.snipeBudgetBox:HasFocus() then
		ns.snipeBudgetBox:SetText(budget > 0 and ns.FormatMoneyInput(budget) or "")
	end
	if ns.snipeStartButton then
		ns.snipeStartButton:SetText(state.running and "Stop" or "Start")
	end
	if ns.snipeStatus then
		ns.snipeStatus:SetText(state.status or "Stopped")
	end
	if ns.snipeSummary then
		local summary = string.format("Watching %d   Deals %d   Max: vendor + %s   Money: %s",
			#list, #(state.currentDeals or {}), ns.FormatMoneyInput(over), ns.FormatMoneyInput(money or 0))
		if #list > 0 then
			summary = summary .. "   Cycle: ~" .. tostring(math.max(1, math.floor(#list * 0.9 + 0.5))) .. "s"
		end
		if budget > 0 then
			summary = summary .. "   Per buy: " .. ns.FormatMoneyInput(budget)
		end
		ns.snipeSummary:SetText(summary)
	end

	if state.watchlistDirty then
		state.watchlistDirty = false
		refreshWatchlist()
	end
	refreshDeals()

	local top = topDeal()
	local secure = ns.snipeSecureButton
	if secure and not inCombat() then
		secure:Show()
		if top and not state.pending then
			local target = ns.GetNativeBuyTarget()
			if target then
				secure:SetAttribute("clickbutton", target)
				secure:Enable()
				secure:SetAlpha(1)
				secure:SetText("Buy")
			else
				secure:SetAttribute("clickbutton", nil)
				secure:Disable()
				secure:SetAlpha(0.5)
				secure:SetText("Buy")
			end
		else
			secure:SetAttribute("clickbutton", nil)
			secure:Disable()
			secure:SetAlpha(0.5)
			secure:SetText(state.pending and "Buying..." or "Buy")
		end
	end
end

function ns.CreateSniperRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)
	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.035)
	row.bg = bg

	local function label(x, width)
		local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", row, "LEFT", x, 0)
		text:SetWidth(width)
		text:SetJustifyH("LEFT")
		return text
	end

	row.itemText = label(6, 120)
	row.bestText = label(130, 50)
	row.maxText = label(184, 50)
	row.marketText = label(238, 50)
	row.qtyText = label(292, 38)
	row.costText = label(334, 60)
	row.profitText = label(398, 60)
	return row
end

function ns.UpdateSniperRow(row, isTop)
	local deal = row.deal
	if not deal then return end
	row.itemText:SetText(deal.name)
	row.bestText:SetText(ns.FormatMoneyInput(deal.unitPrice or 0))
	row.maxText:SetText(ns.FormatMoneyInput(deal.maxPrice or 0))
	row.marketText:SetText(deal.market and ns.FormatMoneyInput(deal.market) or "—")
	row.qtyText:SetText(tostring(deal.quantity or 0))
	row.costText:SetText(ns.FormatMoneyInput(deal.cost or 0))
	row.profitText:SetText(ns.FormatMoney(deal.profit or 0, true))
	row.bg:SetColorTexture(1, 1, 1, isTop and 0.10 or 0.035)
end

-- ---------------------------------------------------------------------------
-- Purchase
-- ---------------------------------------------------------------------------

function ns.BeginSnipeBuy()
	local state = ns.snipe
	if state.pending then return end
	if ns.buyPending then
		state.status = "A Buy Orders purchase is already in progress"
		ns.RefreshSniperFrame()
		return
	end
	if ns.vendor and ns.vendor.pending then
		state.status = "A Vendor Flip purchase is already in progress"
		ns.RefreshSniperFrame()
		return
	end
	local deal = topDeal()
	if not deal then return end
	local money = ns.GetBuyMoney()
	if deal.quantity <= 0 or deal.cost <= 0 or (money and deal.cost > money) then
		state.status = "Not enough money for this deal"
		ns.RefreshSniperFrame()
		return
	end

	ns.DisableNativeBuy()
	local plan = {
		itemID = deal.itemID,
		quantity = deal.quantity,
		cost = deal.cost,
		maxUnit = deal.maxPrice,
	}
	local pending = {
		deal = deal,
		plan = plan,
		phase = "quote",
		startedAt = GetTime(),
	}
	state.pending = pending
	state.status = "Checking price..."
	local target = ns.PrepareNativeBuy(plan)
	if not target then
		state.pending = nil
		state.status = "Native auction buy button unavailable"
		ns.RefreshSniperFrame()
		return
	end
	if ns.snipeSecureButton then ns.snipeSecureButton:SetText("Buying...") end
	ns.After(0, function()
		if state.pending == pending then ns.RefreshSniperFrame() end
	end)

	ns.After(QUOTE_TIMEOUT, function()
		if state.pending == pending and pending.phase == "quote" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			if ns.HideBuyDialog then ns.HideBuyDialog() end
			state.pending = nil
			state.status = "No response from the auction house"
			ns.RefreshSniperFrame()
		end
	end)
	ns.After(PURCHASE_TIMEOUT, function()
		if state.pending == pending then
			state.pending = nil
			state.status = "Purchase result unknown"
			ns.RefreshSniperFrame()
		end
	end)
end

function ns.HandleSnipePrice(unitPrice, totalPrice)
	local state = ns.snipe
	local pending = state.pending
	if not pending or pending.phase ~= "quote" then return end
	if type(unitPrice) ~= "number" or type(totalPrice) ~= "number" then return end
	local money = ns.GetBuyMoney()
	local within = unitPrice <= pending.plan.maxUnit
		and totalPrice <= pending.plan.cost
		and (not money or totalPrice <= money)
	if not within then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		if ns.HideBuyDialog then ns.HideBuyDialog() end
		state.pending = nil
		state.status = "Price moved above the snipe limit - skipped"
		state.deals[pending.deal.itemID] = nil
		ns.RefreshSniperFrame()
		return
	end

	pending.phase = "buy"
	pending.actualCost = totalPrice
	state.status = "Buying..."
	local ok = pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, pending.plan.itemID, pending.plan.quantity)
	if not ok then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		if ns.HideBuyDialog then ns.HideBuyDialog() end
		state.pending = nil
		state.status = "Purchase could not be confirmed"
		ns.RefreshSniperFrame()
	end
end

function ns.HandleSnipePurchaseSucceeded()
	local state = ns.snipe
	local pending = state.pending
	if not pending then return end
	local deal = pending.deal
	local cost = tonumber(pending.actualCost) or pending.plan.cost or 0
	local quantity = pending.plan.quantity or 0
	state.pending = nil
	state.deals[deal.itemID] = nil
	state.alerted[deal.itemID] = nil
	state.status = string.format("Bought %d %s for %s", quantity, deal.name or "item", ns.FormatMoneyInput(cost))
	ns.Print(string.format("Sniper bought %d %s for %s.", quantity, deal.name or "item", ns.FormatMoneyFull(cost)))
	ns.RefreshSniperFrame()
	ns.After(0.2, ns.SnipeTick)
end

function ns.HandleSnipePurchaseFailed()
	local state = ns.snipe
	if not state.pending then return end
	if state.pending.deal then
		state.deals[state.pending.deal.itemID] = nil
		state.alerted[state.pending.deal.itemID] = nil
	end
	state.pending = nil
	state.status = "Purchase failed"
	ns.RefreshSniperFrame()
end

function ns.HandleSnipeUnavailable()
	local state = ns.snipe
	if not state.pending or state.pending.phase ~= "quote" then return end
	pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
	if ns.HideBuyDialog then ns.HideBuyDialog() end
	if state.pending.deal then
		state.deals[state.pending.deal.itemID] = nil
		state.alerted[state.pending.deal.itemID] = nil
	end
	state.pending = nil
	state.status = "No stock at the snipe limit"
	ns.RefreshSniperFrame()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function ns.OnSniperEvent(event, ...)
	local state = ns.snipe
	if event == "AUCTION_HOUSE_SHOW" then
		ns.SetupSniperTab()
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ns.IsAuctionHouseOpen() then ns.SetupSniperTab() end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ns.StopSnipe("Auction house closed")
	elseif event == "COMMODITY_SEARCH_RESULTS_ADDED" or event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if state.running and state.awaiting and state.currentItem == itemID then
			state.awaiting = false
			ns.EvaluateSnipeItem(itemID)
			ns.RefreshSniperFrame()
			ns.After(NEXT_DELAY, ns.SnipeTick)
		end
	elseif event == "ITEM_SEARCH_RESULTS_ADDED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
		local itemKey = ...
		local itemID = type(itemKey) == "table" and itemKey.itemID or nil
		if state.running and state.awaiting and state.currentItem == itemID then
			state.awaiting = false
			state.deals[itemID] = nil
			state.status = string.format("%s is not a commodity", ns.GetItemName(itemID))
			ns.RefreshSniperFrame()
			ns.After(NEXT_DELAY, ns.SnipeTick)
		end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		local unitPrice, totalPrice = ...
		ns.HandleSnipePrice(unitPrice, totalPrice)
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		ns.HandleSnipeUnavailable()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		ns.HandleSnipePurchaseSucceeded()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		ns.HandleSnipePurchaseFailed()
	elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
		local code = tonumber((...)) or ...
		if state.pending then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			if ns.HideBuyDialog then ns.HideBuyDialog() end
			state.pending = nil
			state.status = code == 10 and "Auction house busy - try again" or "Auction house error"
			ns.RefreshSniperFrame()
		elseif state.running then
			state.status = code == 10 and "Auction house busy - slowing down" or "Auction house error"
			ns.RefreshSniperFrame()
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

function ns.SelectSniperTab()
	local ah = _G.AuctionHouseFrame
	if not ah or not ns.snipeFrame then return false end
	if ns.snipeTabLib then
		local ok = pcall(ns.snipeTabLib.SetSelected, ns.snipeTabLib, "OpenMarginSniper")
		return ok
	end

	ah:SetDisplayMode({})
	ah.displayMode = nil
	local tabs = ah.Tabs or {}
	for index = 1, #tabs do PanelTemplates_DeselectTab(tabs[index]) end
	if ns.ahTab then PanelTemplates_DeselectTab(ns.ahTab) end
	if ns.vendorAhTab then PanelTemplates_DeselectTab(ns.vendorAhTab) end
	if ns.disAhTab then PanelTemplates_DeselectTab(ns.disAhTab) end
	if ns.snipeAhTab then PanelTemplates_SelectTab(ns.snipeAhTab) end
	ah:SetTitle("Sniper")
	if ns.buyFrame then ns.buyFrame:Hide() end
	if ns.vendorFrame then ns.vendorFrame:Hide() end
	if ns.disFrame then ns.disFrame:Hide() end
	ns.snipeFrame:Show()
	ns.RefreshSniperFrame()
	return true
end

function ns.SetupSniperTab()
	local ah = _G.AuctionHouseFrame
	if not ah then return false end
	if not ns.snipeFrame then ns.CreateSniperFrame(ah) end
	if ns.snipeTabCreated then return true end

	local lib = getLibAHTab()
	if lib then
		local ok = pcall(lib.CreateTab, lib, "OpenMarginSniper", ns.snipeFrame, "Sniper", "Sniper")
		if ok then
			ns.snipeTabLib = lib
			ns.snipeTabCreated = true
			return true
		end
	end

	if not ah.Tabs or #ah.Tabs == 0 then return false end

	local root = CreateFrame("Frame", nil, ah)
	root:SetSize(10, 10)
	local anchor = ns.disAhTab or ns.vendorAhTab or ns.ahTab or ah.Tabs[#ah.Tabs]
	root:SetPoint("TOPLEFT", anchor, "TOPRIGHT")

	local created, tab = pcall(CreateFrame, "Button", "OpenMarginSniperTab", root, "AuctionHouseFrameDisplayModeTabTemplate")
	if not created or not tab then return false end
	tab:SetText("Sniper")
	PanelTemplates_TabResize(tab, 20, nil, 70)
	tab:SetPoint("TOPLEFT", root, "TOPLEFT", 3, 0)
	PanelTemplates_DeselectTab(tab)
	tab.frameRef = ns.snipeFrame
	tab.tabHeader = "Sniper"
	tab:SetScript("OnClick", ns.SelectSniperTab)
	ns.snipeAhTab = tab
	ns.snipeTabRoot = root

	hooksecurefunc(ah, "SetDisplayMode", function(_, mode)
		if mode ~= nil and #mode > 0 then
			if ns.snipeFrame then ns.snipeFrame:Hide() end
			if ns.snipeAhTab then PanelTemplates_DeselectTab(ns.snipeAhTab) end
			if ns.snipeSecureButton and not inCombat() then ns.snipeSecureButton:Hide() end
		end
	end)

	ns.snipeTabCreated = true
	return true
end

function ns.OpenSniper()
	if not ns.IsAuctionHouseOpen() then
		ns.Print("Open the Auction House first; Sniper is a tab there.")
		return
	end
	if ns.SetupSniperTab() then ns.SelectSniperTab() end
end

function ns.CreateSniperFrame(ah)
	if ns.snipeFrame then return ns.snipeFrame end
	ah = ah or _G.AuctionHouseFrame
	if not ah then return nil end

	local frame = CreateFrame("Frame", "OpenMarginSniperFrame", ah, "InsetFrameTemplate")
	if ah.CategoriesList then
		frame:SetPoint("TOPLEFT", ah.CategoriesList, "TOPLEFT", 0, 0)
	else
		frame:SetPoint("TOPLEFT", ah, "TOPLEFT", 4, -70)
	end
	frame:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -23, 34)
	frame:SetFrameLevel(ah:GetFrameLevel() + 5)
	frame:Hide()
	ns.snipeFrame = frame

	ns.snipe = ns.snipe or {
		running = false,
		deals = {},
		alerted = {},
		status = "Stopped",
	}
	ns.snipe.deals = ns.snipe.deals or {}
	ns.snipe.alerted = ns.snipe.alerted or {}
	ns.snipe.watchlistDirty = true
	ns.snipeRows = {}
	ns.snipeWatchRows = {}

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
	title:SetText("Sniper")
	ns.snipeTitle = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	hint:SetWidth(640)
	hint:SetJustifyH("LEFT")
	hint:SetText("Start once, then spam Buy. Buy stays greyed out until a listing is at or below vendor sell + spread. Blizzard throttles queries, so keep the watchlist short.")

	local overLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	overLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -58)
	overLabel:SetText("Max over vendor:")
	local overBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	overBox:SetSize(70, 20)
	overBox:SetPoint("LEFT", overLabel, "RIGHT", 6, 0)
	overBox:SetAutoFocus(false)
	overBox:SetMaxLetters(20)
	overBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	overBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	overBox:SetScript("OnEditFocusLost", function(self)
		local value = ns.ParseMoneyInput(self:GetText())
		if not value or value < 0 then value = 0 end
		ns.db.settings.snipeOver = value
		self:SetText(value > 0 and ns.FormatMoneyInput(value) or "")
		ns.RefreshSniperFrame()
	end)
	ns.snipeOverBox = overBox

	local budgetLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	budgetLabel:SetPoint("LEFT", overBox, "RIGHT", 22, 0)
	budgetLabel:SetText("Max per buy:")
	local budgetBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	budgetBox:SetSize(80, 20)
	budgetBox:SetPoint("LEFT", budgetLabel, "RIGHT", 6, 0)
	budgetBox:SetAutoFocus(false)
	budgetBox:SetMaxLetters(20)
	budgetBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	budgetBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	budgetBox:SetScript("OnEditFocusLost", function(self)
		local value = ns.ParseMoneyInput(self:GetText())
		if not value or value < 0 then value = 0 end
		ns.db.settings.snipeBudget = value
		self:SetText(value > 0 and ns.FormatMoneyInput(value) or "")
		ns.RefreshSniperFrame()
	end)
	ns.snipeBudgetBox = budgetBox

	local start = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	start:SetSize(90, 24)
	start:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -86)
	start:SetText("Start")
	start:SetScript("OnClick", function()
		if ns.snipe.running then ns.StopSnipe() else ns.StartSnipe() end
	end)
	ns.snipeStartButton = start

	local focusOnly = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	focusOnly:SetSize(20, 20)
	focusOnly:SetPoint("LEFT", start, "RIGHT", 10, 0)
	focusOnly:SetScript("OnClick", function()
		ns.db.settings.snipeFocusOnly = not (ns.db.settings.snipeFocusOnly == true)
		ns.RefreshSniperFrame()
	end)
	ns.snipeFocusOnlyCheck = focusOnly

	local focusOnlyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	focusOnlyLabel:SetPoint("LEFT", focusOnly, "RIGHT", 2, 0)
	focusOnlyLabel:SetText("Focus only")

	local secure = CreateFrame("Button", nil, _G.UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
	secure:SetSize(100, 24)
	secure:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -10)
	secure:SetFrameStrata("DIALOG")
	secure:SetFrameLevel(100)
	secure:SetAttribute("type", "click")
	secure:RegisterForClicks("AnyUp", "AnyDown")
	secure:SetText("Buy")
	secure:Hide()
	secure:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then ns.BeginSnipeBuy() end
	end)
	secure:HookScript("PostClick", function()
		ns.After(0, function() ns.RefreshSniperFrame() end)
	end)
	ns.snipeSecureButton = secure

	local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	status:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -116)
	status:SetWidth(700)
	status:SetJustifyH("LEFT")
	ns.snipeStatus = status

	local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	summary:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -132)
	summary:SetWidth(740)
	summary:SetJustifyH("LEFT")
	summary:SetTextColor(0.75, 0.75, 0.75)
	ns.snipeSummary = summary

	local watchTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	watchTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -158)
	watchTitle:SetText("Watchlist")
	ns.snipeWatchTitle = watchTitle

	local watchScroll = CreateFrame("ScrollFrame", "OpenMarginSniperWatchScroll", frame, "UIPanelScrollFrameTemplate")
	watchScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -174)
	watchScroll:SetSize(230, 250)
	local watchContent = CreateFrame("Frame", nil, watchScroll)
	watchContent:SetSize(200, 1)
	watchScroll:SetScrollChild(watchContent)
	ns.snipeWatchScroll = watchScroll
	ns.snipeWatchContent = watchContent

	local addBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	addBox:SetSize(150, 20)
	addBox:SetPoint("TOPLEFT", watchScroll, "BOTTOMLEFT", 4, -8)
	addBox:SetAutoFocus(false)
	addBox:SetMaxLetters(80)
	addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	addBox:SetScript("OnEnterPressed", function(self)
		local itemID = resolveItemID(self:GetText())
		if itemID then
			ns.AddSnipeItem(itemID)
			self:SetText("")
			ns.RefreshSniperFrame()
		end
		self:ClearFocus()
	end)
	ns.snipeAddBox = addBox

	local addButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addButton:SetSize(44, 20)
	addButton:SetPoint("LEFT", addBox, "RIGHT", 4, 0)
	addButton:SetText("Add")
	addButton:SetScript("OnClick", function()
		local kind, itemID = _G.GetCursorInfo()
		if kind == "item" and itemID then
			ns.AddSnipeItem(itemID)
			ns.RefreshSniperFrame()
		else
			local resolved = resolveItemID(addBox:GetText())
			if resolved then
				ns.AddSnipeItem(resolved)
				addBox:SetText("")
				ns.RefreshSniperFrame()
			end
		end
	end)
	ns.snipeAddButton = addButton

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("TOPLEFT", watchContent, "TOPLEFT", 4, -4)
	empty:SetText("No items. Add an item ID or shift-click / pick up an item and click Add.")
	ns.snipeWatchEmpty = empty

	local dealTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	dealTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 270, -158)
	dealTitle:SetText("Deals")
	ns.snipeDealTitle = dealTitle

	local headers = {
		{ text = "Item", x = 270, width = 120 },
		{ text = "Best", x = 400, width = 50 },
		{ text = "Max", x = 454, width = 50 },
		{ text = "Market", x = 508, width = 50 },
		{ text = "Qty", x = 562, width = 38 },
		{ text = "Cost", x = 604, width = 60 },
		{ text = "Profit", x = 668, width = 60 },
	}
	for index = 1, #headers do
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", frame, "TOPLEFT", headers[index].x, -174)
		label:SetWidth(headers[index].width)
		label:SetText(headers[index].text)
		label:SetTextColor(0.8, 0.8, 0.8)
	end

	local dealScroll = CreateFrame("ScrollFrame", "OpenMarginSniperScrollFrame", frame, "UIPanelScrollFrameTemplate")
	dealScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 264, -190)
	dealScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 10)
	local content = CreateFrame("Frame", nil, dealScroll)
	content:SetSize(500, 1)
	dealScroll:SetScrollChild(content)
	ns.snipeScroll = dealScroll
	ns.snipeContent = content

	local emptyDeals = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyDeals:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
	emptyDeals:SetText("No deals yet. Start the sniper.")
	ns.snipeEmpty = emptyDeals

	frame:SetScript("OnShow", function() ns.RefreshSniperFrame() end)
	frame:SetScript("OnHide", function()
		if ns.snipeSecureButton and not inCombat() then ns.snipeSecureButton:Hide() end
	end)

	ns.RefreshSniperFrame()
	return frame
end

local sniperEventFrame = CreateFrame("Frame")
local sniperEvents = {
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"PLAYER_ENTERING_WORLD",
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
for index = 1, #sniperEvents do
	pcall(sniperEventFrame.RegisterEvent, sniperEventFrame, sniperEvents[index])
end
sniperEventFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnSniperEvent, event, ...)
	if not ok then ns.ReportError(err) end
end)
