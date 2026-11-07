local addonName, ns = ...

-- Auction House buy orders.
--
-- WoW only allows a commodity purchase from a hardware event, so a single
-- click cannot both wait for an async search and buy. Each row's button is a
-- two-state control instead: the first click searches, and once the results
-- are in the same button becomes "Buy N". Clicks made while searching are
-- ignored, which makes it safe to spam the button.

local SEARCH_TIMEOUT = 6
local PLAN_MAX_AGE = 2
local QUOTE_TIMEOUT = 5
local PURCHASE_TIMEOUT = 10
local MORE_RESULTS_TIMEOUT = 1.2
local AUTO_SEARCH_DELAY = 0.6

local SORTS = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

local function isSecret(value)
	return _G.issecretvalue and _G.issecretvalue(value) or false
end

local function isNumber(value)
	return type(value) == "number" and not isSecret(value)
end

function ns.GetBuyMoney()
	if type(_G.GetMoney) ~= "function" then return nil end
	local ok, money = pcall(_G.GetMoney)
	if not ok or not isNumber(money) then return nil end
	return money
end

function ns.GetBuyRemaining(rule)
	local limit = tonumber(rule and rule.budgetLimit) or 0
	local spent = tonumber(rule and rule.spent) or 0
	local remaining = limit - spent
	if remaining < 0 then remaining = 0 end
	return remaining
end

-- Plain text money for edit boxes. GetMoneyString returns coin-icon markup on
-- modern clients, which cannot be parsed back when the field is re-read.
function ns.FormatMoneyInput(copper)
	copper = tonumber(copper)
	if not copper or copper < 0 then return "" end
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local rest = copper % 100
	local parts = {}
	if gold > 0 then parts[#parts + 1] = gold .. "g" end
	if silver > 0 then parts[#parts + 1] = silver .. "s" end
	if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
	return table.concat(parts, " ")
end

function ns.ParseMoneyInput(text)
	text = tostring(text or "")
	text = text:gsub("|T.-|t", "") -- coin/texture markup from GetMoneyString
	text = text:gsub("|A.-|a", "") -- atlas markup from GetMoneyString
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:lower()
	text = text:gsub("gold", "g"):gsub("silver", "s"):gsub("copper", "c")
	text = text:gsub("cents", "c"):gsub("cent", "c")
	text = text:gsub("%s+", "")
	if text == "" then return nil end

	if text:match("^%d+%.?%d*$") then
		return math.floor((tonumber(text) or 0) + 0.5)
	end

	local total = 0
	local consumed = 0
	for value, unit in text:gmatch("(%d+%.?%d*)([gsc])") do
		local amount = tonumber(value)
		if not amount then return nil end
		local multiplier = unit == "g" and 10000 or unit == "s" and 100 or 1
		total = total + amount * multiplier
		consumed = consumed + #value + 1
	end

	if consumed == 0 or consumed ~= #text then return nil end
	return math.floor(total + 0.5)
end

local function itemDisplayName(itemID)
	local info = ns.GetItemInfo(itemID)
	if info and info.name and not isSecret(info.name) then
		return info.name
	end
	if info and info.link and not isSecret(info.link) then
		return info.link
	end
	return "item:" .. tostring(itemID)
end

function ns.GetBuyItemDisplay(itemID)
	if not itemID then return "" end
	return itemDisplayName(itemID)
end

function ns.ResolveBuyItemID(text)
	text = ns.Trim(text)
	if text == "" then return nil end

	local id = text:match("item:(%d+)")
	if id then return tonumber(id) end

	id = text:match("^%s*(%d+)%s*$")
	if id then
		id = tonumber(id)
		if id and id > 0 then return id end
	end

	if type(_G.GetItemInfo) == "function" then
		local ok, _, link = pcall(_G.GetItemInfo, text)
		if ok and link then
			id = ns.GetItemIDFromLink(link)
			if id then return id end
		end
	end
	if _G.C_Item and type(_G.C_Item.GetItemInfo) == "function" then
		local ok, _, link = pcall(_G.C_Item.GetItemInfo, text)
		if ok and link then
			id = ns.GetItemIDFromLink(link)
			if id then return id end
		end
	end
	return nil
end

function ns.GetCommodityStatus(itemID)
	if not itemID or not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetItemCommodityStatus then
		return nil
	end
	if not _G.ItemLocation or type(_G.ItemLocation.CreateFromItemID) ~= "function" then
		return nil
	end
	local ok, location = pcall(_G.ItemLocation.CreateFromItemID, _G.ItemLocation, itemID)
	if not ok or not location then return nil end
	local statusOk, status = pcall(_G.C_AuctionHouse.GetItemCommodityStatus, location)
	if not statusOk then return nil end
	return status
end

local function itemEnum()
	return _G.Enum and _G.Enum.ItemCommodityStatus and _G.Enum.ItemCommodityStatus.Item or 1
end

function ns.GetBuyState(rule)
	if not rule then return nil end
	ns.buyRuntime = ns.buyRuntime or {}
	local state = ns.buyRuntime[rule]
	if not state then
		state = {
			phase = "idle",
			status = "Set an item and prices",
		}
		ns.buyRuntime[rule] = state
	end
	return state
end

function ns.ClearBuyRuntime()
	ns.buyPending = nil
	ns.buyRuntime = {}
end

function ns.InitBuyOrders()
	if not ns.db then return end
	if type(ns.db.buyOrders) ~= "table" then ns.db.buyOrders = {} end

	local orders = ns.db.buyOrders
	for index = #orders, 1, -1 do
		local rule = orders[index]
		if type(rule) ~= "table" then
			table.remove(orders, index)
		else
			rule.itemID = tonumber(rule.itemID)
			if rule.itemID and rule.itemID <= 0 then rule.itemID = nil end
			rule.maxUnit = tonumber(rule.maxUnit)
			rule.budgetLimit = tonumber(rule.budgetLimit)
			rule.spent = tonumber(rule.spent) or 0
			if rule.maxUnit and rule.maxUnit <= 0 then rule.maxUnit = nil end
			if rule.budgetLimit and rule.budgetLimit <= 0 then rule.budgetLimit = nil end
			if rule.itemID and not rule.itemName then
				rule.itemName = ns.GetBuyItemDisplay(rule.itemID)
			end
		end
	end
end

function ns.IsAuctionHouseOpen()
	local frame = _G.AuctionHouseFrame
	return frame and type(frame.IsShown) == "function" and frame:IsShown() or false
end

local function refreshRule(rule)
	if not ns.buyFrame or not ns.buyFrame:IsShown() then return end
	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		local state = ns.buyRuntime and ns.buyRuntime[orders[index]]
		if state and state.row then
			ns.UpdateBuyRow(state.row)
		end
	end
end

local function buildPlan(rule, force)

	local state = ns.GetBuyState(rule)
	if state.phase ~= "searching" then return end
	log("plan start itemID=%s max=%s remaining=%s force=%s", tostring(rule.itemID), tostring(rule.maxUnit), tostring(ns.GetBuyRemaining(rule)), tostring(force))

	local itemID = rule.itemID
	if not itemID then
		state.phase = "idle"
		state.status = "Set an item"
		refreshRule(rule)
		return
	end
	if not rule.maxUnit or rule.maxUnit <= 0 then
		state.phase = "idle"
		state.status = "Set max each"
		refreshRule(rule)
		return
	end

	local api = _G.C_AuctionHouse
	if not api or type(api.GetNumCommoditySearchResults) ~= "function" then
		state.phase = "idle"
		state.status = "Auction house API unavailable"
		refreshRule(rule)
		return
	end

	local hasFull = true
	if type(api.HasFullCommoditySearchResults) == "function" then
		local ok, full = pcall(api.HasFullCommoditySearchResults, itemID)
		if ok then hasFull = full == true end
	end

	if not hasFull and not force then
		if not state.moreRequested and type(api.RequestMoreCommoditySearchResults) == "function" then
			state.moreRequested = true
			pcall(api.RequestMoreCommoditySearchResults, itemID)
		end
		log("plan waiting for full itemID=%s hasFull=%s", tostring(itemID), tostring(hasFull))
		state.planSeq = (state.planSeq or 0) + 1
		local seq = state.planSeq
		ns.After(MORE_RESULTS_TIMEOUT, function()
			if rule.itemID == itemID and state.phase == "searching" and state.planSeq == seq then
				buildPlan(rule, true)
			end
		end)
		return
	end

	local num = 0
	local ok, result = pcall(api.GetNumCommoditySearchResults, itemID)
	if ok and isNumber(result) then num = result end
	log("plan results itemID=%s count=%s full=%s", tostring(itemID), tostring(num), tostring(hasFull))

	if num <= 0 then
		state.phase = "idle"
		state.plan = nil
		state.status = "No listings found"
		refreshRule(rule)
		return
	end

	local tiers = {}
	for index = 1, num do
		local infoOk, info = pcall(api.GetCommoditySearchResultInfo, itemID, index)
		if infoOk and type(info) == "table" then
			local unitPrice = info.unitPrice
			local quantity = info.quantity
			local own = info.numOwnerItems or 0
			if isNumber(unitPrice) and unitPrice > 0 and isNumber(quantity) then
				local available = quantity - (isNumber(own) and own or 0)
				log("plan tier itemID=%s index=%s price=%s qty=%s own=%s available=%s", tostring(itemID), tostring(index), tostring(unitPrice), tostring(quantity), tostring(own), tostring(available))
				if available > 0 then
					tiers[#tiers + 1] = {
						unitPrice = unitPrice,
						quantity = available,
					}
				end
			end
		end
	end

	table.sort(tiers, function(lhs, rhs) return lhs.unitPrice < rhs.unitPrice end)

	local available = 0
	for index = 1, #tiers do
		if tiers[index].unitPrice > rule.maxUnit then break end
		available = available + tiers[index].quantity
	end
	log("plan eligible itemID=%s available=%s tiers=%s", tostring(itemID), tostring(available), tostring(#tiers))

	if available <= 0 then
		state.phase = "idle"
		state.plan = nil
		state.status = "No listings at or below " .. ns.FormatMoneyFull(rule.maxUnit)
		refreshRule(rule)
		return
	end

	local spendCap = ns.GetBuyRemaining(rule)
	local money = ns.GetBuyMoney()
	if money and money < spendCap then spendCap = money end
	log("plan budget itemID=%s remaining=%s money=%s spendCap=%s", tostring(itemID), tostring(ns.GetBuyRemaining(rule)), tostring(money), tostring(spendCap))
	if spendCap <= 0 then
		state.phase = "idle"
		state.plan = nil
		state.status = "Budget used - reset to buy again"
		refreshRule(rule)
		return
	end

	local quantity, cost = 0, 0
	for index = 1, #tiers do
		local tier = tiers[index]
		if tier.unitPrice > rule.maxUnit then break end
		local affordable = math.floor((spendCap - cost) / tier.unitPrice)
		if affordable <= 0 then break end
		local take = math.min(tier.quantity, affordable)
		quantity = quantity + take
		cost = cost + take * tier.unitPrice
	end

	if quantity <= 0 then
		state.phase = "idle"
		state.plan = nil
		state.status = "Budget too low for the current price"
		refreshRule(rule)
		return
	end

	state.phase = "ready"
	state.plan = {
		itemID = itemID,
		quantity = quantity,
		cost = cost,
		maxUnit = rule.maxUnit,
		available = available,
		at = GetTime(),
		budgetRemaining = ns.GetBuyRemaining(rule),
	}
	log("plan ready itemID=%s quantity=%s cost=%s available=%s max=%s", tostring(itemID), tostring(quantity), tostring(cost), tostring(available), tostring(rule.maxUnit))
	if quantity < available then
		state.status = string.format("Budget allows %d of %d units - %s total", quantity, available, ns.FormatMoneyFull(cost))
	else
		state.status = string.format("%d units - %s total - <= %s each", quantity, ns.FormatMoneyFull(cost), ns.FormatMoneyFull(rule.maxUnit))
	end
	refreshRule(rule)
end

function ns.SearchBuyRule(rule, row)
	if not rule then return end
	if ns.buyPending then return end

	local state = ns.GetBuyState(rule)
	if state.phase == "searching" or state.phase == "quoting" or state.phase == "buying" then
		return
	end
	log("search request itemID=%s max=%s budget=%s spent=%s remaining=%s phase=%s", tostring(rule.itemID), tostring(rule.maxUnit), tostring(rule.budgetLimit), tostring(rule.spent), tostring(ns.GetBuyRemaining(rule)), tostring(state.phase))
	if not ns.IsAuctionHouseOpen() then
		state.phase = "idle"
		state.plan = nil
		state.status = "Open the auction house first"
		refreshRule(rule)
		return
	end
	if not rule.itemID then
		state.phase = "idle"
		state.status = "Set an item"
		refreshRule(rule)
		return
	end
	if not rule.maxUnit or rule.maxUnit <= 0 then
		state.phase = "idle"
		state.status = "Set max each"
		refreshRule(rule)
		return
	end
	if not rule.budgetLimit or rule.budgetLimit <= 0 then
		state.phase = "idle"
		state.status = "Set a budget"
		refreshRule(rule)
		return
	end
	if ns.GetBuyRemaining(rule) <= 0 then
		state.phase = "idle"
		state.plan = nil
		state.status = "Budget used - reset to buy again"
		refreshRule(rule)
		return
	end
	if type(_G.C_AuctionHouse) ~= "table" or type(_G.C_AuctionHouse.SendSearchQuery) ~= "function" then
		state.phase = "idle"
		state.status = "Auction house API unavailable"
		refreshRule(rule)
		return
	end

	local status = ns.GetCommodityStatus(rule.itemID)
	if status == itemEnum() then
		state.phase = "idle"
		state.plan = nil
		state.status = "Only commodities can be bulk-bought"
		refreshRule(rule)
		return
	end

	local ok, itemKey = pcall(_G.C_AuctionHouse.MakeItemKey, rule.itemID)
	if not ok or not itemKey then
		state.phase = "idle"
		state.status = "Unknown item"
		refreshRule(rule)
		return
	end

	-- Set the phase before sending the query: some clients can deliver the
	-- result immediately from inside SendSearchQuery.
	state.phase = "searching"
	state.plan = nil
	state.moreRequested = nil
	state.planSeq = (state.planSeq or 0) + 1
	state.searchSeq = (state.searchSeq or 0) + 1
	state.status = "Searching..."
	local seq = state.searchSeq
	refreshRule(rule)

	local sent = pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, SORTS, false)
	log("search sent itemID=%s ok=%s", tostring(rule.itemID), tostring(sent))
	if not sent then
		state.phase = "idle"
		state.status = "Search failed"
		refreshRule(rule)
		return
	end

	ns.After(SEARCH_TIMEOUT, function()
		if state.phase == "searching" and state.searchSeq == seq then
			state.phase = "idle"
			state.plan = nil
			state.status = "Search timed out - click again"
			refreshRule(rule)
		end
	end)
end

local function findRulesForItem(itemID, phase)
	local found = {}
	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		local rule = orders[index]
		if rule.itemID == itemID then
			local state = ns.GetBuyState(rule)
			if not phase or state.phase == phase then
				found[#found + 1] = rule
			end
		end
	end
	return found
end

function ns.HandleCommodityResults(itemID)
	if not itemID then return end
	log("ah commodity results itemID=%s", tostring(itemID))
	local rules = findRulesForItem(itemID, "searching")
	for index = 1, #rules do
		buildPlan(rules[index], false)
	end
end

function ns.HandleItemResults(itemID)
	if not itemID then return end
	log("ah item results itemID=%s", tostring(itemID))
	local rules = findRulesForItem(itemID, "searching")
	for index = 1, #rules do
		local rule = rules[index]
		local state = ns.GetBuyState(rule)
		state.phase = "idle"
		state.plan = nil
		state.status = "Only commodities can be bulk-bought"
		refreshRule(rule)
	end
end

function ns.StartBuy(rule)
	local state = ns.GetBuyState(rule)
	local plan = state.plan
	if not plan or state.phase ~= "ready" then return end
	if ns.buyPending then return end

	local remaining = ns.GetBuyRemaining(rule)
	log("start itemID=%s quantity=%s planCost=%s remaining=%s money=%s", tostring(plan.itemID), tostring(plan.quantity), tostring(plan.cost), tostring(remaining), tostring(ns.GetBuyMoney()))
	if plan.cost > remaining then
		state.phase = "idle"
		state.status = "Budget is too low - search again"
		refreshRule(rule)
		return
	end
	local money = ns.GetBuyMoney()
	if money and plan.cost > money then
		state.phase = "idle"
		state.status = "Not enough money"
		refreshRule(rule)
		return
	end

	if not _G.C_AuctionHouse or type(_G.C_AuctionHouse.StartCommoditiesPurchase) ~= "function" then
		state.phase = "idle"
		state.status = "Auction house API unavailable"
		refreshRule(rule)
		return
	end

	local pending = {
		rule = rule,
		plan = plan,
		phase = "quote",
		startedAt = GetTime(),
	}
	ns.buyPending = pending
	state.phase = "quoting"
	state.status = "Checking price..."
	refreshRule(rule)

	-- This must stay in the caller's click handler: StartCommoditiesPurchase
	-- only works during a hardware event.
	local started = pcall(_G.C_AuctionHouse.StartCommoditiesPurchase, plan.itemID, plan.quantity)
	log("start sent ok=%s", tostring(started))
	if not started then
		ns.buyPending = nil
		state.phase = "idle"
		state.status = "The auction house blocked the purchase"
		refreshRule(rule)
		return
	end

	ns.After(QUOTE_TIMEOUT, function()
		if ns.buyPending == pending and pending.phase == "quote" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			ns.buyPending = nil
			state.phase = "idle"
			state.status = "No response from the auction house"
			refreshRule(rule)
		end
	end)

	ns.After(PURCHASE_TIMEOUT, function()
		if ns.buyPending == pending then
			ns.buyPending = nil
			state.phase = "idle"
			state.status = "Purchase result unknown"
			refreshRule(rule)
		end
	end)
end

function ns.OnBuyRowClick(rule, row)
	if not rule then return end
	if row then ns.CommitBuyRow(row) end
	if ns.buyPending then return end

	local state = ns.GetBuyState(rule)
	log("click itemID=%s phase=%s planAge=%s pending=%s", tostring(rule.itemID), tostring(state.phase), tostring(state.plan and (GetTime() - state.plan.at) or nil), tostring(ns.buyPending ~= nil))
	if state.phase == "ready" then
		local plan = state.plan
		if not plan or (GetTime() - plan.at) > PLAN_MAX_AGE then
			ns.SearchBuyRule(rule)
			return
		end
		ns.StartBuy(rule)
	elseif state.phase == "idle" then
		ns.SearchBuyRule(rule)
	end
end

function ns.HandleCommodityPrice(unitPrice, totalPrice)
	local pending = ns.buyPending
	if not pending or pending.phase ~= "quote" then return end
	if not isNumber(unitPrice) or not isNumber(totalPrice) then return end

	local plan = pending.plan
	local rule = pending.rule
	local state = ns.GetBuyState(rule)

	local remaining = ns.GetBuyRemaining(rule)
	local money = ns.GetBuyMoney()

	local withinLimits =
		unitPrice <= plan.maxUnit and
		totalPrice <= plan.cost and
		totalPrice <= remaining and
		(not money or totalPrice <= money)
	log("quote unit=%s total=%s max=%s planCost=%s remaining=%s money=%s within=%s", tostring(unitPrice), tostring(totalPrice), tostring(plan.maxUnit), tostring(plan.cost), tostring(remaining), tostring(money), tostring(withinLimits))

	if not withinLimits then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		ns.buyPending = nil
		state.phase = "idle"
		state.plan = nil
		state.status = "Price moved above your limit - click to search again"
		refreshRule(rule)
		return
	end

	pending.phase = "buy"
	pending.actualCost = totalPrice
	pending.unitPrice = unitPrice
	state.phase = "buying"
	state.status = "Buying..."
	refreshRule(rule)

	-- Confirm on the next frame: the price event can be delivered from inside
	-- StartCommoditiesPurchase, and confirming from a timer is allowed.
	ns.After(0, function()
		if ns.buyPending ~= pending or pending.phase ~= "buy" then return end
		local confirmed = pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, plan.itemID, plan.quantity)
		if not confirmed then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			ns.buyPending = nil
			state.phase = "idle"
			state.status = "Purchase could not be confirmed"
			refreshRule(rule)
		end
	end)
end

function ns.HandleCommodityUnavailable()
	local pending = ns.buyPending
	if not pending or pending.phase ~= "quote" then return end
	log("commodity price unavailable itemID=%s", tostring(pending.rule.itemID))
	if _G.C_AuctionHouse and type(_G.C_AuctionHouse.CancelCommoditiesPurchase) == "function" then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
	end
	ns.buyPending = nil
	local state = ns.GetBuyState(pending.rule)
	state.phase = "idle"
	state.plan = nil
	state.status = "No stock at your price - click to search again"
	refreshRule(pending.rule)
end

function ns.HandlePurchaseSucceeded()
	local pending = ns.buyPending
	if not pending then return end
	local rule = pending.rule
	local state = ns.GetBuyState(rule)
	local cost = tonumber(pending.actualCost) or pending.plan.cost or 0
	local quantity = pending.plan.quantity or 0
	log("purchase succeeded itemID=%s quantity=%s cost=%s oldSpent=%s", tostring(rule.itemID), tostring(quantity), tostring(cost), tostring(rule.spent))

	rule.spent = (tonumber(rule.spent) or 0) + cost
	ns.buyPending = nil
	state.phase = "idle"
	state.plan = nil
	state.status = string.format("Bought %d for %s", quantity, ns.FormatMoneyFull(cost))
	refreshRule(rule)
	ns.Print(string.format("Bought %d x %s for %s.", quantity, rule.itemName or ns.GetBuyItemDisplay(rule.itemID), ns.FormatMoneyFull(cost)))

	ns.After(AUTO_SEARCH_DELAY, function()
		if ns.buyPending then return end
		if not ns.IsAuctionHouseOpen() or not ns.IsBuyFrameShown() then return end
		if not rule.removed and ns.GetBuyRemaining(rule) > 0 then
			ns.SearchBuyRule(rule)
		end
	end)
end

function ns.HandlePurchaseFailed()
	local pending = ns.buyPending
	if not pending then return end
	local rule = pending.rule
	log("purchase failed itemID=%s", tostring(rule.itemID))
	local state = ns.GetBuyState(rule)
	ns.buyPending = nil
	state.phase = "idle"
	state.plan = nil
	state.status = "Purchase failed - click to try again"
	refreshRule(rule)
end

function ns.HandleAuctionClosed()
	log("auction house closed")
	local pending = ns.buyPending
	if pending and pending.phase == "quote" then
		if _G.C_AuctionHouse and type(_G.C_AuctionHouse.CancelCommoditiesPurchase) == "function" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		end
		ns.buyPending = nil
	end
	-- An in-flight "buy" is left alone so its success event can still record
	-- the spend; its own timeout clears it if the close interrupted it.

	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		local rule = orders[index]
		local state = ns.GetBuyState(rule)
		if not ns.buyPending or ns.buyPending.rule ~= rule then
			state.phase = "idle"
			state.plan = nil
			state.status = "Open the auction house to search"
		end
	end
end

function ns.HandleAuctionError(errorCode)
	errorCode = tonumber(errorCode) or errorCode
	log("auction error code=%s pending=%s", tostring(errorCode), tostring(ns.buyPending ~= nil))
	local pending = ns.buyPending
	if pending then
		ns.buyPending = nil
		local state = ns.GetBuyState(pending.rule)
		state.phase = "idle"
		state.plan = nil
		if errorCode == 10 then
			state.status = "Auction house is busy - click again"
		else
			state.status = "Auction house error - click again"
		end
		refreshRule(pending.rule)
		return
	end

	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		local rule = orders[index]
		local state = ns.GetBuyState(rule)
		if state.phase == "searching" then
			state.phase = "idle"
			state.plan = nil
			state.status = errorCode == 10 and "Auction house is busy - click again" or "Search failed - click again"
			refreshRule(rule)
		end
	end
end

function ns.OnBuyEvent(event, ...)
	if event ~= "GET_ITEM_INFO_RECEIVED" then
		log("event %s", tostring(event))
	end
	if event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
		ns.HandleCommodityResults(...)
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
		local itemKey = ...
		local itemID = type(itemKey) == "table" and itemKey.itemID or nil
		ns.HandleItemResults(itemID)
	elseif event == "COMMODITY_PRICE_UPDATED" then
		local unitPrice, totalPrice = ...
		ns.HandleCommodityPrice(unitPrice, totalPrice)
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		ns.HandleCommodityUnavailable()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		ns.HandlePurchaseSucceeded()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		ns.HandlePurchaseFailed()
	elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
		ns.HandleAuctionError(...)
	elseif event == "AUCTION_HOUSE_SHOW" then
		ns.InstallBuyItemHook()
		ns.SetupAuctionTab()
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.InstallBuyItemHook()
		if ns.IsAuctionHouseOpen() then ns.SetupAuctionTab() end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ns.HandleAuctionClosed()
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if ns.buyFrame and ns.buyFrame:IsShown() and not ns.buyItemInfoPending then
			ns.buyItemInfoPending = true
			ns.After(0.2, function()
				ns.buyItemInfoPending = false
				ns.RefreshBuyFrame()
			end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Auction House tab
-- ---------------------------------------------------------------------------

local function getLibAHTab()
	local libStub = _G.LibStub
	if type(libStub) ~= "table" or type(libStub.GetLibrary) ~= "function" then return nil end
	local ok, lib = pcall(libStub.GetLibrary, libStub, "LibAHTab-1-0", true)
	if ok and type(lib) == "table" and type(lib.CreateTab) == "function" then
		return lib
	end
	return nil
end

local function selectOwnTab()
	local ah = _G.AuctionHouseFrame
	if not ah or not ns.ahTab then return end

	ah:SetDisplayMode({})
	ah.displayMode = nil

	local tabs = ah.Tabs or {}
	for index = 1, #tabs do
		PanelTemplates_DeselectTab(tabs[index])
	end
	PanelTemplates_SelectTab(ns.ahTab)
	ah:SetTitle("Buy Orders")

	if ns.buyFrame then
		ns.buyFrame:Show()
		ns.RefreshBuyFrame()
	end
end

function ns.SetupAuctionTab()
	local ah = _G.AuctionHouseFrame
	log("tab setup existing=%s frame=%s", tostring(ns.ahTabCreated), tostring(ns.buyFrame ~= nil))
	if not ah then return false end
	if not ns.buyFrame then ns.CreateBuyFrame(ah) end
	if ns.ahTabCreated then return true end
	if not ns.buyFrame then return false end

	local lib = getLibAHTab()
	if lib then
		local ok = pcall(lib.CreateTab, lib, "OpenMarginBuyOrders", ns.buyFrame, "Buy Orders", "Buy Orders")
		if ok then
			ns.ahTabLib = lib
			ns.ahTabCreated = true
			log("tab created shared")
			return true
		end
	end

	if not ah.Tabs or #ah.Tabs == 0 then
		log("tab creation failed: no built-in tabs")
		return false
	end

	local root = CreateFrame("Frame", nil, ah)
	root:SetSize(10, 10)
	local anchor = ah.Tabs[#ah.Tabs]
	local auctionatorTabs = _G.Auctionator and _G.Auctionator.State and _G.Auctionator.State.TabFrameRef
		and _G.Auctionator.State.TabFrameRef.Tabs
	if type(auctionatorTabs) == "table" and #auctionatorTabs > 0 then
		anchor = auctionatorTabs[#auctionatorTabs]
	end
	root:SetPoint("TOPLEFT", anchor, "TOPRIGHT")
	ns.ahTabRoot = root

	local created, tab = pcall(CreateFrame, "Button", "OpenMarginBuyOrdersTab", root, "AuctionHouseFrameDisplayModeTabTemplate")
	if not created or not tab then
		root:Hide()
		log("tab creation failed: tab template")
		return false
	end
	tab:SetText("Buy Orders")
	PanelTemplates_TabResize(tab, 20, nil, 70)
	tab:SetPoint("TOPLEFT", root, "TOPLEFT", 3, 0)
	PanelTemplates_DeselectTab(tab)
	tab.frameRef = ns.buyFrame
	tab.tabHeader = "Buy Orders"
	tab:SetScript("OnClick", selectOwnTab)
	ns.ahTab = tab

	hooksecurefunc(ah, "SetDisplayMode", function(_, mode)
		if mode ~= nil and #mode > 0 then
			if ns.buyFrame then ns.buyFrame:Hide() end
			if ns.ahTab then PanelTemplates_DeselectTab(ns.ahTab) end
		end
	end)

	ns.ahTabCreated = true
	log("tab created own")
	return true
end

function ns.SelectBuyTab()
	if not ns.ahTabCreated and not ns.SetupAuctionTab() then return false end
	if ns.ahTabLib then
		local ok = pcall(ns.ahTabLib.SetSelected, ns.ahTabLib, "OpenMarginBuyOrders")
		return ok
	end
	selectOwnTab()
	return true
end

function ns.OpenBuyOrders()
	log("open buy orders ahOpen=%s", tostring(ns.IsAuctionHouseOpen()))
	if not ns.IsAuctionHouseOpen() then
		ns.Print("Open the Auction House first; Buy Orders is a tab there.")
		return
	end
	if ns.SetupAuctionTab() then
		ns.SelectBuyTab()
	else
		ns.Print("Could not add the Buy Orders tab to the Auction House.")
	end
end

function ns.IsBuyFrameShown()
	return ns.buyFrame and ns.buyFrame:IsShown() or false
end

-- ---------------------------------------------------------------------------
-- Buy Orders UI
-- ---------------------------------------------------------------------------

function ns.AddBuyRule()
	if not ns.db then return end
	log("add buy rule")
	ns.db.buyOrders = ns.db.buyOrders or {}
	local rule = {
		itemID = nil,
		itemName = nil,
		maxUnit = nil,
		budgetLimit = nil,
		spent = 0,
	}
	ns.db.buyOrders[#ns.db.buyOrders + 1] = rule
	ns.GetBuyState(rule).status = "Set an item and prices"
	ns.RefreshBuyFrame()
	return rule
end

function ns.DeleteBuyRule(rule)
	if not rule or not ns.db then return end
	log("delete buy rule itemID=%s", tostring(rule.itemID))
	local state = ns.GetBuyState(rule)
	if ns.buyPending and ns.buyPending.rule == rule then return end
	rule.removed = true
	ns.buyRuntime[rule] = nil
	local orders = ns.db.buyOrders
	for index = #orders, 1, -1 do
		if orders[index] == rule then table.remove(orders, index) end
	end
	ns.RefreshBuyFrame()
end

function ns.ResetBuyBudget(rule)
	if not rule then return end
	log("reset budget itemID=%s", tostring(rule.itemID))
	local state = ns.GetBuyState(rule)
	if ns.buyPending and ns.buyPending.rule == rule then return end
	rule.spent = 0
	state.phase = "idle"
	state.plan = nil
	state.status = "Budget reset - click to search"
	refreshRule(rule)
end

local function commitMoney(rule, box, field)
	if not box then return end
	local raw = box:GetText()
	local value = ns.ParseMoneyInput(raw)
	log("commit field=%s raw=%q parsed=%s old=%s focus=%s", tostring(field), tostring(raw), tostring(value), tostring(rule[field]), tostring(box:HasFocus()))
	if value ~= rule[field] then
		rule[field] = value
		local state = ns.GetBuyState(rule)
		state.phase = "idle"
		state.plan = nil
		state.status = "Click to search with the new limit"
	end
	if not box:HasFocus() then
		local formatted = value and value > 0 and ns.FormatMoneyInput(value) or ""
		box:SetText(formatted)
		log("commit field=%s setText=%q", tostring(field), tostring(formatted))
	end
end

function ns.CommitBuyRow(row)
	if not row or not row.rule then return end
	local rule = row.rule
	if ns.buyPending and ns.buyPending.rule == rule then return end
	local state = ns.GetBuyState(rule)

	if row.itemBox then
		local text = ns.Trim(row.itemBox:GetText())
		log("commit item raw=%q ruleName=%q ruleID=%s focus=%s", tostring(text), tostring(rule.itemName), tostring(rule.itemID), tostring(row.itemBox:HasFocus()))
		if text ~= (rule.itemName or "") then
			local itemID = ns.ResolveBuyItemID(text)
			if itemID then
				if itemID ~= rule.itemID then rule.spent = 0 end
				rule.itemID = itemID
				rule.itemName = ns.GetBuyItemDisplay(itemID)
				if not row.itemBox:HasFocus() then row.itemBox:SetText(rule.itemName) end
				state.phase = "idle"
				state.plan = nil
				state.status = "Click to search"
			else
				rule.itemID = nil
				rule.itemName = text ~= "" and text or nil
				state.phase = "idle"
				state.plan = nil
				state.status = text == "" and "Set an item" or "Unknown item"
			end
		end
	end

	commitMoney(rule, row.maxBox, "maxUnit")
	commitMoney(rule, row.budgetBox, "budgetLimit")
	log("commit done itemID=%s max=%s budget=%s spent=%s phase=%s", tostring(rule.itemID), tostring(rule.maxUnit), tostring(rule.budgetLimit), tostring(rule.spent), tostring(state.phase))
end

local function setStatusColor(row, state)
	if state.phase == "ready" then
		row.status:SetTextColor(0.35, 0.95, 0.35)
	elseif state.phase == "searching" or state.phase == "quoting" or state.phase == "buying" then
		row.status:SetTextColor(0.95, 0.82, 0.25)
	elseif state.status and (state.status:find("above") or state.status:find("failed") or state.status:find("No ") or state.status:find("Only ")) then
		row.status:SetTextColor(0.95, 0.4, 0.4)
	else
		row.status:SetTextColor(0.7, 0.7, 0.7)
	end
end

function ns.UpdateBuyRow(row)
	if not row or not row.rule then return end
	local rule = row.rule
	local state = ns.GetBuyState(rule)

	if not row.itemBox:HasFocus() then
		local name = rule.itemID and ns.GetBuyItemDisplay(rule.itemID) or (rule.itemName or "")
		if row.itemBox:GetText() ~= name then row.itemBox:SetText(name) end
	end
	if not row.maxBox:HasFocus() then
		local maxText = rule.maxUnit and rule.maxUnit > 0 and ns.FormatMoneyInput(rule.maxUnit) or ""
		if row.maxBox:GetText() ~= maxText then
			log("row max text=%q -> %q rule=%s", tostring(row.maxBox:GetText()), tostring(maxText), tostring(rule.maxUnit))
		end
		row.maxBox:SetText(maxText)
	end
	if not row.budgetBox:HasFocus() then
		local budgetText = rule.budgetLimit and rule.budgetLimit > 0 and ns.FormatMoneyInput(rule.budgetLimit) or ""
		if row.budgetBox:GetText() ~= budgetText then
			log("row budget text=%q -> %q rule=%s", tostring(row.budgetBox:GetText()), tostring(budgetText), tostring(rule.budgetLimit))
		end
		row.budgetBox:SetText(budgetText)
	end

	local remaining = ns.GetBuyRemaining(rule)
	if rule.budgetLimit then
		row.remaining:SetText(ns.FormatMoneyFull(remaining) .. " left")
	else
		row.remaining:SetText("no budget")
	end

	local info = rule.itemID and ns.GetItemInfo(rule.itemID) or nil
	row.icon:SetTexture(info and info.texture or nil)

	row.status:SetText(state.status or "")
	setStatusColor(row, state)

	local busyOther = ns.buyPending and ns.buyPending.rule ~= rule
	if busyOther then
		row.buyButton:SetText("Busy")
		row.buyButton:Disable()
	elseif state.phase == "searching" then
		row.buyButton:SetText("Searching...")
		row.buyButton:Disable()
	elseif state.phase == "quoting" then
		row.buyButton:SetText("Checking...")
		row.buyButton:Disable()
	elseif state.phase == "buying" then
		row.buyButton:SetText("Buying...")
		row.buyButton:Disable()
	elseif state.phase == "ready" and state.plan then
		row.buyButton:SetText(string.format("Buy %d", state.plan.quantity))
		row.buyButton:Enable()
	else
		row.buyButton:SetText("Search")
		row.buyButton:Enable()
	end

	row.resetButton:SetEnabled(not (ns.buyPending and ns.buyPending.rule == rule))
end

local function createRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(54)

	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.035)
	row.bg = bg

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -7)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.itemBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.itemBox:SetSize(188, 20)
	row.itemBox:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -7)
	row.itemBox:SetAutoFocus(false)
	row.itemBox:SetMaxLetters(140)
	row.itemBox:SetHyperlinksEnabled(true)
	row.itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	row.itemBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	row.maxBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.maxBox:SetSize(66, 20)
	row.maxBox:SetPoint("TOPLEFT", row, "TOPLEFT", 232, -7)
	row.maxBox:SetAutoFocus(false)
	row.maxBox:SetMaxLetters(20)
	row.maxBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	row.maxBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	row.budgetBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.budgetBox:SetSize(76, 20)
	row.budgetBox:SetPoint("TOPLEFT", row, "TOPLEFT", 308, -7)
	row.budgetBox:SetAutoFocus(false)
	row.budgetBox:SetMaxLetters(20)
	row.budgetBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	row.budgetBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	row.remaining = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.remaining:SetPoint("TOPLEFT", row, "TOPLEFT", 396, -11)
	row.remaining:SetWidth(116)
	row.remaining:SetJustifyH("LEFT")

	row.resetButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.resetButton:SetSize(48, 20)
	row.resetButton:SetPoint("TOPLEFT", row, "TOPLEFT", 514, -7)
	row.resetButton:SetText("Reset")
	row.resetButton:SetScript("OnClick", function()
		ns.ResetBuyBudget(row.rule)
	end)

	row.buyButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.buyButton:SetSize(96, 22)
	row.buyButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -30, -5)
	row.buyButton:SetScript("OnClick", function()
		ns.OnBuyRowClick(row.rule, row)
	end)

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.deleteButton:SetSize(20, 20)
	row.deleteButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
	row.deleteButton:SetText("X")
	row.deleteButton:SetScript("OnClick", function()
		ns.DeleteBuyRule(row.rule)
	end)

	row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.status:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -32)
	row.status:SetWidth(560)
	row.status:SetJustifyH("LEFT")

	local function commit() ns.CommitBuyRow(row); ns.UpdateBuyRow(row) end
	row.maxBox:HookScript("OnEditFocusLost", commit)
	row.budgetBox:HookScript("OnEditFocusLost", commit)

	row.itemBox:HookScript("OnEditFocusGained", function()
		ns.focusedBuyItemBox = row.itemBox
	end)
	row.itemBox:HookScript("OnEditFocusLost", function()
		if ns.focusedBuyItemBox == row.itemBox then ns.focusedBuyItemBox = nil end
		commit()
	end)

	row.itemBox:SetScript("OnReceiveDrag", function(self)
		local kind, _, link = GetCursorInfo()
		if kind == "item" and link then
			local itemID = ns.GetItemIDFromLink(link)
			if itemID then
				local rule = row.rule
				if rule then
					if rule.itemID ~= itemID then rule.spent = 0 end
					rule.itemID = itemID
					rule.itemName = ns.GetBuyItemDisplay(itemID)
					local state = ns.GetBuyState(rule)
					state.phase = "idle"
					state.plan = nil
					state.status = "Click to search"
					ns.UpdateBuyRow(row)
				end
			end
			ClearCursor()
		end
	end)

	row.buyButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Buy Orders")
		GameTooltip:AddLine("First click searches. When results are ready, the button shows Buy N and a second click purchases.", 1, 1, 1, true)
		GameTooltip:AddLine("Only listings at or below Max each are bought. The confirmed price is checked again before purchase.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	row.buyButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	return row
end

function ns.CreateBuyFrame(ah)
	if ns.buyFrame then return ns.buyFrame end
	ah = ah or _G.AuctionHouseFrame
	if not ah then return nil end

	local frame = CreateFrame("Frame", "OpenMarginBuyFrame", ah, "InsetFrameTemplate")
	if ah.CategoriesList then
		frame:SetPoint("TOPLEFT", ah.CategoriesList, "TOPLEFT", 0, 0)
	else
		frame:SetPoint("TOPLEFT", ah, "TOPLEFT", 4, -70)
	end
	frame:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -23, 34)
	frame:SetFrameLevel(ah:GetFrameLevel() + 5)
	frame:Hide()
	ns.buyFrame = frame

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
	title:SetText("Buy Orders")
	ns.buyTitle = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	hint:SetWidth(560)
	hint:SetJustifyH("LEFT")
	hint:SetText("Commodities only. Shift-click an item; money like 13c, 10s or 1g 5s. First click searches, then the button becomes Buy.")
	ns.buyHint = hint

	local addButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addButton:SetSize(100, 22)
	addButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -10)
	addButton:SetText("New order")
	addButton:SetScript("OnClick", function() ns.AddBuyRule() end)
	ns.buyAddButton = addButton

	local logButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	logButton:SetSize(54, 22)
	logButton:SetPoint("TOPRIGHT", addButton, "TOPLEFT", -6, 0)
	logButton:SetText("Log")
	logButton:SetScript("OnClick", function()
		if ns.ShowBuyLog then ns.ShowBuyLog() end
	end)
	ns.buyLogButton = logButton

	local headers = {
		{ text = "Item", x = 36, width = 188 },
		{ text = "Max each", x = 232, width = 66 },
		{ text = "Budget", x = 308, width = 76 },
		{ text = "Remaining", x = 396, width = 116 },
	}
	for index = 1, #headers do
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", frame, "TOPLEFT", headers[index].x, -70)
		label:SetWidth(headers[index].width)
		label:SetText(headers[index].text)
		label:SetTextColor(0.8, 0.8, 0.8)
	end

	local scroll = CreateFrame("ScrollFrame", "OpenMarginBuyScrollFrame", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -86)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 10)
	ns.buyScroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(700, 1)
	scroll:SetScrollChild(content)
	ns.buyContent = content

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("CENTER", scroll, "CENTER", 0, 20)
	empty:SetText("No buy orders yet. Click New order to add one.")
	ns.buyEmpty = empty

	ns.buyRows = {}
	frame:SetScript("OnShow", function()
		ns.RefreshBuyFrame()
	end)

	ns.RefreshBuyFrame()
	return frame
end

function ns.RefreshBuyFrame()
	if not ns.buyFrame then return end
	local orders = ns.db and ns.db.buyOrders or {}
	local content = ns.buyContent
	local scroll = ns.buyScroll
	if not content or not scroll then return end

	local width = scroll:GetWidth()
	if width and width > 100 then
		content:SetWidth(width - 26)
	end

	ns.buyRows = ns.buyRows or {}
	for index = 1, #orders do
		local rule = orders[index]
		local row = ns.buyRows[index]
		if not row then
			row = createRow(content)
			ns.buyRows[index] = row
		end
		row.rule = rule
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((index - 1) * 56))
		row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -((index - 1) * 56))
		row:Show()
		ns.GetBuyState(rule).row = row
		ns.UpdateBuyRow(row)
	end

	for index = #orders + 1, #ns.buyRows do
		ns.buyRows[index].rule = nil
		ns.buyRows[index]:Hide()
	end

	content:SetHeight(math.max(#orders * 56, 1))
	ns.buyEmpty:SetShown(#orders == 0)
end

-- ---------------------------------------------------------------------------
-- Shift-click item links into the focused name box
-- ---------------------------------------------------------------------------

function ns.InstallBuyItemHook()
	if ns.buyItemHooked then return end

	local function insert(link)
		if type(link) ~= "string" then return false end
		local itemID = ns.GetItemIDFromLink(link)
		if not itemID then return false end
		log("shift-click itemID=%s", tostring(itemID))
		local box = ns.focusedBuyItemBox
		if not box or not box:IsShown() or not box:HasFocus() then return false end
		local row = box:GetParent()
		local rule = row and row.rule
		if not rule then return false end
		if ns.buyPending and ns.buyPending.rule == rule then return false end
		if rule.itemID ~= itemID then rule.spent = 0 end
		rule.itemID = itemID
		rule.itemName = ns.GetBuyItemDisplay(itemID)
		box:SetText(rule.itemName)
		box:ClearFocus()
		local state = ns.GetBuyState(rule)
		state.phase = "idle"
		state.plan = nil
		state.status = "Click to search"
		ns.UpdateBuyRow(row)
		return true
	end

	local installed = false
	if type(_G.HandleModifiedItemClick) == "function" then
		installed = pcall(hooksecurefunc, "HandleModifiedItemClick", function(link)
			insert(link)
		end)
	elseif type(_G.ChatEdit_InsertLink) == "function" then
		installed = pcall(hooksecurefunc, "ChatEdit_InsertLink", function(link)
			insert(link)
		end)
	end
	if installed then ns.buyItemHooked = true end
end

ns.InstallBuyItemHook()

-- ---------------------------------------------------------------------------
-- Buy order events
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local buyEvents = {
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
	"GET_ITEM_INFO_RECEIVED",
}
for index = 1, #buyEvents do
	pcall(eventFrame.RegisterEvent, eventFrame, buyEvents[index])
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnBuyEvent, event, ...)
	if not ok then ns.ReportError(err) end
end)
