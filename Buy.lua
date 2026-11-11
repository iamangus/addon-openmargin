local addonName, ns = ...

-- Auction House buy orders.
--
-- Rows are blind commodity purchases: item, Max each, budget and a quantity
-- per purchase. Clicking Buy starts the native commodity purchase for that
-- quantity without a search; the live quote is checked against Max each and
-- the remaining budget before it is confirmed.

local SEARCH_TIMEOUT = 4
local QUOTE_TIMEOUT = 5
local PURCHASE_TIMEOUT = 10
local AUTO_SEARCH_DELAY = 0.8

local SORTS = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

local function isSecret(value)
	return _G.issecretvalue and _G.issecretvalue(value) or false
end

local function inCombat()
	return _G.InCombatLockdown and _G.InCombatLockdown() or false
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
	local limit = tonumber(rule and rule.budgetLimit)
	if not limit or limit <= 0 then
		-- No explicit budget: the live quote is still capped by GetMoney().
		return math.huge
	end
	local spent = tonumber(rule and rule.spent) or 0
	local remaining = limit - spent
	if remaining < 0 then remaining = 0 end
	return remaining
end

function ns.GetBuyQuantity(rule)
	local quantity = math.floor(tonumber(rule and rule.buyQuantity) or 20)
	if quantity < 1 then quantity = 1 end
	return quantity
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

-- Item name lookup for typed names. The client has no item-name index, so the
-- Auction House browse query does the search ("Copper Ore" also finds the
-- exact name when a multi-word name is trimmed word by word).
function ns.NormalizeItemName(text)
	return ns.Normalize(text):gsub("%s+", " ")
end

-- Resolve a typed item name to one or (when ambiguous) several candidates.
-- Returns a list of { itemID, name } and the query tried.
function ns.FindBuyItemCandidates(text)
	text = ns.Trim(text)
	if text == "" then return {}, nil end

	-- Whole-string matches first: the item cache and our own names.
	local wanted = ns.NormalizeItemName(text)
	local map = ns.BuildItemNameMap and ns.BuildItemNameMap()
	local results = {}
	local seen = {}
	local function push(itemID)
		itemID = tonumber(itemID)
		if itemID and itemID > 0 and not seen[itemID] then
			seen[itemID] = true
			results[#results + 1] = { itemID = itemID, name = ns.GetBuyItemDisplay(itemID) }
		end
	end
	if map and map[wanted] then push(map[wanted]) end

	-- Name search over the player's cached item data.
	if _G.ItemSearch_AddItem and type(_G.ItemSearch_AddItem) == "function" then
		local tokens = {}
		for word in wanted:gmatch("%S+") do tokens[#tokens + 1] = word end
		local ok = pcall(function()
			ClearItemSearch()
			for index = 1, #tokens do ItemSearch_AddItem(tokens[index]) end
			local count = GetNumItemSearchResults()
			for index = 1, math.min(count or 0, 50) do
				local link = GetItemSearchResult(index)
				local itemID = link and ns.GetItemIDFromLink(link)
				if itemID then push(itemID) end
			end
		end)
		if not ok and _G.ClearItemSearch then pcall(_G.ClearItemSearch) end
	end

	return results, text
end

-- Auction House browse search used when the item is not in the local cache.
function ns.StartBuyItemLookup(row, text)
	local api = _G.C_AuctionHouse
	if not api or type(api.SendBrowseQuery) ~= "function" then
		if row.rule then ns.GetBuyState(row.rule).status = "Unknown item" end
		ns.UpdateBuyRow(row)
		return false
	end
	if not _G.AuctionHouseFrame or not _G.AuctionHouseFrame:IsShown() then
		if row.rule then
			ns.GetBuyState(row.rule).status = "Open the Auction House to look up that name"
		end
		ns.UpdateBuyRow(row)
		return false
	end

	ns.buyLookup = {
		row = row,
		query = text,
		startedAt = GetTime(),
	}
	local ok = pcall(api.SendBrowseQuery, {
		searchString = text,
		filters = {},
		itemClassFilters = {},
		sorts = SORTS,
	})
	if not ok then
		ns.buyLookup = nil
		if row.rule then ns.GetBuyState(row.rule).status = "Item lookup failed" end
		ns.UpdateBuyRow(row)
		return false
	end
	if row.rule then ns.GetBuyState(row.rule).status = "Looking up item..." end
	ns.UpdateBuyRow(row)
	return true
end

local function applyPurchasableItem(row, itemID)
	local rule = row and row.rule
	if not rule or not itemID then return end
	local status = ns.GetCommodityStatus(itemID)
	local purchaseStatus = ns.GetCommodityPurchaseStatus(itemID)
	if status and status ~= itemEnum() then
		ns.GetBuyState(rule).status = "Only commodities can be blind bought"
		return
	end
	if purchaseStatus and ns.purchaseStatusEnum and purchaseStatus ~= ns.purchaseStatusEnum() then
		ns.GetBuyState(rule).status = "Nothing listed for that item right now"
		return
	end
	if rule.itemID ~= itemID then rule.spent = 0 end
	rule.itemID = itemID
	rule.itemName = ns.GetBuyItemDisplay(itemID)
	local state = ns.GetBuyState(rule)
	state.phase = "idle"
	state.plan = nil
	state.status = "Click Buy"
end

function ns.FinishBuyItemLookup()
	local lookup = ns.buyLookup
	if not lookup then return end
	local api = _G.C_AuctionHouse
	if not api or type(api.GetBrowseResults) ~= "function" then return end

	local ok, results = pcall(api.GetBrowseResults)
	if not ok or type(results) ~= "table" then results = {} end
	if #results == 0 and (GetTime() - (lookup.startedAt or 0)) < 2 then
		ns.After(0.5, ns.FinishBuyItemLookup)
		return
	end

	ns.buyLookup = nil
	local row = lookup.row
	if not row or not row.rule then return end

	local wanted = ns.NormalizeItemName(lookup.query)
	local exact, partial, seen = nil, {}, {}
	for index = 1, #results do
		local itemKey = results[index].itemKey
		local itemID = itemKey and tonumber(itemKey.itemID)
		if itemID and itemID > 0 and not seen[itemID] then
			seen[itemID] = true
			local name = ns.GetBuyItemDisplay(itemID)
			local normalized = ns.NormalizeItemName(name)
			if normalized == wanted then
				exact = itemID
				break
			elseif normalized:sub(1, #wanted) == wanted then
				partial[#partial + 1] = { itemID = itemID, name = name }
			end
		end
	end

	if not exact and #partial == 1 then exact = partial[1].itemID end
	if exact then
		applyPurchasableItem(row, exact)
	elseif #partial > 1 then
		ns.Print("Buy Orders: several items match \"" .. lookup.query .. "\": "
			.. partial[1].name .. ", " .. partial[2].name .. ". Shift-click the one you want.")
		ns.GetBuyState(row.rule).status = "Several items match - shift-click one"
	else
		ns.GetBuyState(row.rule).status = "No listed auction matches that name"
	end
	ns.UpdateBuyRow(row)
end

function ns.GetCommodityPurchaseStatus(itemID)
	if not itemID or not _G.C_AuctionHouse or type(_G.C_AuctionHouse.GetItemCommodityPurchaseStatus) ~= "function" then
		return nil
	end
	if not _G.ItemLocation or type(_G.ItemLocation.CreateFromItemID) ~= "function" then return nil end
	local ok, location = pcall(_G.ItemLocation.CreateFromItemID, _G.ItemLocation, itemID)
	if not ok or not location then return nil end
	local statusOk, status = pcall(_G.C_AuctionHouse.GetItemCommodityPurchaseStatus, location)
	if not statusOk then return nil end
	return status
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

function ns.purchaseStatusEnum()
	return _G.Enum and _G.Enum.CommodityPurchaseStatus and _G.Enum.CommodityPurchaseStatus.Purchasable or 1
end

-- Quotes arrive as averages and can be fractional. Copper is whole units, so
-- round down to the price the sale actually charges.
function ns.WholeCopper(value)
	value = tonumber(value)
	if not value then return nil end
	if value < 0 then value = 0 end
	return math.floor(value)
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
			rule.buyQuantity = math.floor(tonumber(rule.buyQuantity) or 20)
			if rule.buyQuantity < 1 then rule.buyQuantity = 1 end
			if rule.maxUnit and rule.maxUnit <= 0 then rule.maxUnit = nil end
			if rule.budgetLimit and rule.budgetLimit <= 0 then rule.budgetLimit = nil end
			if rule.itemID and not rule.itemName then
				rule.itemName = ns.GetBuyItemDisplay(rule.itemID)
			end
		end
	end
	local selected = false
	for index = 1, #orders do
		local rule = orders[index]
		if rule.keyTarget then
			if selected then
				rule.keyTarget = nil
			else
				selected = true
			end
		end
	end
	if not selected and #orders > 0 then
		orders[1].keyTarget = true
	end
end

function ns.IsAuctionHouseOpen()
	local frame = _G.AuctionHouseFrame
	return frame and type(frame.IsShown) == "function" and frame:IsShown() or false
end

local function refreshRule(rule)
	if not ns.buyFrame or not ns.buyFrame:IsShown() then return end
	if rule then
		local state = ns.GetBuyState(rule)
		if state and state.row then
			ns.UpdateBuyRow(state.row)
			return
		end
	end
	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		local state = ns.buyRuntime and ns.buyRuntime[orders[index]]
		if state and state.row then
			ns.UpdateBuyRow(state.row)
		end
	end
end

-- Light the secure Buy button immediately after a plan is ready, before the
-- rest of the row redraw.
function ns.ArmBuyRowSecure(rule)
	local state = rule and ns.GetBuyState(rule)
	local row = state and state.row
	local secure = row and row.secureBuyButton
	if not secure or not state.plan or inCombat() then return end
	if not ns.IsBuyFrameShown() then return end
	state.armedPlan = state.plan
	ns.armedBuyRule = rule
	secure:SetAttribute("clickbutton", nil)
	secure:SetText(string.format("Buy %d", state.plan.quantity))
	secure:Enable()
	secure:SetAlpha(1)
	if ns.IsBuyRowVisible(row) then
		secure:Show()
	end
end

function ns.ArmBlindBuy(rule, plan)
	local state = ns.GetBuyState(rule)
	local row = state and state.row
	local secure = row and row.secureBuyButton
	if not secure or not plan or inCombat() or not ns.IsBuyFrameShown() then return false end
	state.phase = "ready"
	state.plan = plan
	state.armedPlan = plan
	ns.armedBuyRule = rule
	state.blindKey = string.format("%s|%s|%s", tostring(plan.itemID), tostring(plan.quantity), tostring(plan.maxUnit))
	secure:SetAttribute("clickbutton", nil)
	secure:SetText(string.format("Buy %d", plan.quantity))
	secure:Enable()
	secure:SetAlpha(1)
	if ns.IsBuyRowVisible(row) then
		secure:Show()
	end
	return true
end

function ns.StopBuyLoop(rule)
	local state = ns.GetBuyState(rule)
	state.loop = false
	if ns.buyLoopRule == rule then ns.buyLoopRule = nil end
	if state.phase == "searching" then
		state.phase = "idle"
		state.plan = nil
		state.status = "Stopped"
	end
	refreshRule(rule)
end

function ns.ScheduleBuyLoop(rule, delay)
	local state = ns.GetBuyState(rule)
	if not state.loop or ns.buyLoopRule ~= rule or ns.buyPending then return end
	if ns.buyLoopScheduled then return end
	ns.buyLoopScheduled = true
	ns.After(delay or 1.0, function()
		ns.buyLoopScheduled = false
		local current = ns.GetBuyState(rule)
		if ns.buyLoopRule == rule and current.loop and not ns.buyPending then
			ns.SearchBuyRule(rule)
		end
	end)
end

function ns.ToggleBuyLoop(rule, row)
	local state = ns.GetBuyState(rule)
	if state.loop then
		ns.StopBuyLoop(rule)
		return
	end
	if ns.buyLoopRule and ns.buyLoopRule ~= rule then
		ns.StopBuyLoop(ns.buyLoopRule)
	end
	if ns.StopSnipe then ns.StopSnipe("Buy Orders search started") end
	if ns.StopVendorScan then ns.StopVendorScan() end
	if ns.StopDisenchantScan then ns.StopDisenchantScan() end
	ns.buyLoopRule = rule
	state.loop = true
	if state.phase == "ready" and state.plan then
		refreshRule(rule)
	else
		ns.SearchBuyRule(rule, row)
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

	if not hasFull then
		log("plan using partial results itemID=%s", tostring(itemID))
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
		ns.ScheduleBuyLoop(rule)
		return
	end

	local tiers = {}
	local debug = ns.IsBuyLogEnabled and ns.IsBuyLogEnabled()
	for index = 1, num do
		local infoOk, info = pcall(api.GetCommoditySearchResultInfo, itemID, index)
		if infoOk and type(info) == "table" then
			local unitPrice = info.unitPrice
			local quantity = info.quantity
			local own = info.numOwnerItems or 0
			if isNumber(unitPrice) and unitPrice > 0 and isNumber(quantity) then
				local available = quantity - (isNumber(own) and own or 0)
				if debug then
					log("plan tier itemID=%s index=%s price=%s qty=%s own=%s available=%s", tostring(itemID), tostring(index), tostring(unitPrice), tostring(quantity), tostring(own), tostring(available))
				end
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
		ns.ScheduleBuyLoop(rule)
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
		if state.loop then ns.StopBuyLoop(rule) else refreshRule(rule) end
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
		ns.ScheduleBuyLoop(rule)
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
	ns.ArmBuyRowSecure(rule)
	refreshRule(rule)

end

function ns.SearchBuyRule(rule, row)
	if not rule then return end
	if ns.buyPending then return end

	local state = ns.GetBuyState(rule)
	if state.phase == "searching" or state.phase == "quoting" or state.phase == "buying" then
		return
	end
	local uiRow = row or state.row
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("search request itemID=%s max=%s budget=%s spent=%s remaining=%s phase=%s", tostring(rule.itemID), tostring(rule.maxUnit), tostring(rule.budgetLimit), tostring(rule.spent), tostring(ns.GetBuyRemaining(rule)), tostring(state.phase))
	end
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
		if state.loop then ns.StopBuyLoop(rule) else refreshRule(rule) end
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
	if state.armedPlan then
		state.armedPlan = nil
		ns.DisableNativeBuy()
	end
	state.moreRequested = nil
	state.planSeq = (state.planSeq or 0) + 1
	state.searchSeq = (state.searchSeq or 0) + 1
	state.status = "Searching..."
	local seq = state.searchSeq
	if uiRow and uiRow.buyButton then
		uiRow.buyButton:SetText(state.loop and "Stop" or "Searching...")
		uiRow.buyButton:Enable()
	end

	local sent = pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, SORTS, false)
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("search sent itemID=%s ok=%s", tostring(rule.itemID), tostring(sent))
	end
	if not sent then
		state.phase = "idle"
		state.status = "Search failed"
		refreshRule(rule)
		ns.ScheduleBuyLoop(rule, 1)
		return
	end

	ns.After(SEARCH_TIMEOUT, function()
		if state.phase == "searching" and state.searchSeq == seq then
			state.phase = "idle"
			state.plan = nil
			state.status = "Search timed out - retrying"
			refreshRule(rule)
			ns.ScheduleBuyLoop(rule)
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

function ns.HideBuyDialog()
	local ah = _G.AuctionHouseFrame
	if ah and ah.BuyDialog and type(ah.BuyDialog.IsShown) == "function" and ah.BuyDialog:IsShown() then
		ah.BuyDialog:Hide()
	end
end

local function throttleReady()
	if _G.C_AuctionHouse and type(_G.C_AuctionHouse.IsThrottledMessageSystemReady) == "function" then
		local ok, ready = pcall(_G.C_AuctionHouse.IsThrottledMessageSystemReady)
		if ok then return ready == true end
	end
	return nil
end

function ns.GetNativeBuyTarget()
	local ah = _G.AuctionHouseFrame
	local frame = ah and ah.CommoditiesBuyFrame
	local display = type(frame) == "table" and frame.BuyDisplay or nil
	local target = type(display) == "table" and display.BuyButton or nil
	if display and target then return target, display end
	return nil
end

function ns.DisableNativeBuy()
	local target, display = ns.GetNativeBuyTarget()
	if not target or not display then return end
	pcall(function()
		if display.QuantityInput then display.QuantityInput:SetQuantity(0) end
		if display.SetPrice then display:SetPrice(0, 0) end
		target:Disable()
	end)
	ns.armedBuyRule = nil
end

-- Ask the auction house for a price quote. Blizzard now marks the native Buy
-- button as forbidden scripted input, so a secure proxy cannot press it. The
-- C_AuctionHouse entry point itself still accepts plain addon values, which is
-- also how other auction addons buy commodities.
function ns.StartCommodityQuote(plan)
	if not plan then return false, "no purchase plan" end
	local itemID = tonumber(plan.itemID)
	local quantity = tonumber(plan.quantity)
	if not itemID or not quantity or quantity <= 0 then
		return false, "invalid purchase plan"
	end
	local api = _G.C_AuctionHouse
	if not api or type(api.StartCommoditiesPurchase) ~= "function" then
		return false, "auction house purchase API unavailable"
	end
	local unitPrice = math.floor((tonumber(plan.cost) or 0) / quantity + 0.5)
	local ok, err = pcall(api.StartCommoditiesPurchase, itemID, quantity, unitPrice)
	if not ok then return false, tostring(err) end
	return true
end

function ns.StartBuy(rule)
	local state = ns.GetBuyState(rule)
	local plan = state.plan
	if not plan or state.phase ~= "ready" then return end
	if ns.buyPending then return end

	local remaining = ns.GetBuyRemaining(rule)
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("start itemID=%s quantity=%s planCost=%s remaining=%s money=%s", tostring(plan.itemID), tostring(plan.quantity), tostring(plan.cost), tostring(remaining), tostring(ns.GetBuyMoney()))
	end
	local row = state.row
	local pending = {
		rule = rule,
		plan = plan,
		phase = "quote",
		startedAt = GetTime(),
		secure = row and row.secureBuyButton,
	}
	ns.buyPending = pending
	state.phase = "quoting"
	state.status = "Checking price..."
	state.armedPlan = nil

	local started, startError = ns.StartCommodityQuote(plan)
	if not started then
		ns.buyPending = nil
		state.phase = "idle"
		state.status = "Could not start the purchase: " .. tostring(startError or "?")
		ns.Print("Buy Orders: could not start the purchase (" .. tostring(startError or "?") .. ").")
		refreshRule(rule)
		return
	end

	-- Do not hide the secure button here: it was just pressed and its OnClick
	-- still has to run. Refresh on the next frame, after the click.
	if row and row.secureBuyButton then
		row.secureBuyButton:SetAttribute("clickbutton", nil)
		row.secureBuyButton:SetText("Buying...")
	end
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("quote start itemID=%s quantity=%s unitPrice=%s total=%s ok=%s err=%s", tostring(plan.itemID), tostring(plan.quantity), tostring(math.floor(plan.cost / math.max(1, plan.quantity) + 0.5)), tostring(plan.cost), tostring(started), tostring(startError))
	end

	ns.After(QUOTE_TIMEOUT, function()
		if ns.buyPending == pending and pending.phase == "quote" then
			local blocked = ns.lastBlockedAction and tostring(ns.lastBlockedAction) or "none"
			log("quote timeout itemID=%s throttleReady=%s blocked=%s", tostring(pending.plan.itemID), tostring(throttleReady()), blocked)
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			ns.HideBuyDialog()
			ns.buyPending = nil
			state.phase = "idle"
			state.status = "No response from the auction house"
			ns.Print("Buy Orders: the Auction House did not return a purchase quote. Run /om buylog for details.")
			refreshRule(rule)
			ns.ScheduleBuyLoop(rule)
		end
	end)

	ns.After(PURCHASE_TIMEOUT, function()
		if ns.buyPending == pending then
			ns.HideBuyDialog()
			ns.buyPending = nil
			state.phase = "idle"
			state.status = "Purchase result unknown"
			refreshRule(rule)
			ns.ScheduleBuyLoop(rule)
		end
	end)
end

function ns.BeginSecureBuy(row)
	if not row or not row.rule then return end
	if ns.vendor and ns.vendor.pending then return end
	if ns.snipe and ns.snipe.pending then return end
	if ns.buyPending then
		-- A second click while a purchase is pending must not click the native
		-- Buy button again.
		if row.secureBuyButton then row.secureBuyButton:SetAttribute("clickbutton", nil) end
		return
	end
	if row.itemBox or row.quantityBox then
		ns.CommitBuyRow(row)
		ns.UpdateBuyRow(row)
	end
	local state = ns.GetBuyState(row.rule)
	if state.phase ~= "ready" or not state.plan then return end
	ns.StartBuy(row.rule)
end

function ns.HandleCommodityPrice(unitPrice, totalPrice)
	local pending = ns.buyPending
	if not pending or pending.phase ~= "quote" then return end
	if not isNumber(unitPrice) or not isNumber(totalPrice) then return end

	local plan = pending.plan
	local rule = pending.rule
	local state = ns.GetBuyState(rule)

	-- Remember the cheapest quote this order has seen. The quote is an average
	-- that can be fractional, so store whole copper: a 2s53c quote must not be
	-- remembered as 254c and shown as 3s. It is cleared by Reset.
	local quoteUnit = ns.WholeCopper(unitPrice)
	local quoteTotal = ns.WholeCopper(totalPrice)
	if not rule.lowQuote or quoteUnit < rule.lowQuote then
		rule.lowQuote = quoteUnit
		rule.lowQuoteAt = time()
		rule.lowQuoteQuantity = plan.quantity
		rule.lowQuoteTotal = quoteTotal
	end

	local remaining = ns.GetBuyRemaining(rule)
	local money = ns.GetBuyMoney()

	-- plan.cost is only the preview. The live quote is allowed to spend more
	-- than the preview as long as it stays under Max each and the real budget.
	-- Compare whole copper so a 252.6c average is treated as 252c, matching
	-- what the purchase charges and what the row shows.
	local withinLimits =
		quoteUnit <= plan.maxUnit and
		quoteTotal <= remaining and
		(not money or quoteTotal <= money)
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("quote unit=%s total=%s max=%s planCost=%s remaining=%s money=%s within=%s", tostring(unitPrice), tostring(totalPrice), tostring(plan.maxUnit), tostring(plan.cost), tostring(remaining), tostring(money), tostring(withinLimits))
	end

	if not withinLimits then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		ns.HideBuyDialog()
		ns.DisableNativeBuy()
		ns.buyPending = nil
		state.phase = "idle"
		state.plan = nil
		state.armedPlan = nil
		state.messageUntil = GetTime() + 10
		local reason
		if quoteUnit > plan.maxUnit then
			reason = string.format("quote %s each is above Max each %s", ns.FormatMoneyFull(quoteUnit), ns.FormatMoneyFull(plan.maxUnit))
		elseif quoteTotal > remaining then
			reason = string.format("quote total %s exceeds budget remaining %s", ns.FormatMoneyFull(quoteTotal), ns.FormatMoneyFull(remaining))
		else
			reason = string.format("quote total %s exceeds your money", ns.FormatMoneyFull(quoteTotal))
		end
		state.status = reason .. " - click Buy to try again"
		ns.Print("Buy Orders: " .. reason .. ".")
		refreshRule(rule)
		ns.ScheduleBuyLoop(rule)
		return
	end

	pending.phase = "buy"
	pending.actualCost = quoteTotal
	pending.unitPrice = quoteUnit
	state.phase = "buying"
	state.status = "Buying..."

	-- Confirm before touching the row UI: this is the race-winning call.
	local confirmed, confirmError = pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, plan.itemID, plan.quantity)
	if ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		log("confirm sent ok=%s err=%s", tostring(confirmed), tostring(confirmError))
	end
	if not confirmed then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		ns.HideBuyDialog()
		ns.buyPending = nil
		state.phase = "idle"
		state.status = "Purchase could not be confirmed"
	end
	refreshRule(rule)
	ns.ScheduleBuyLoop(rule)
end

function ns.HandleCommodityUnavailable()
	local pending = ns.buyPending
	if not pending or pending.phase ~= "quote" then return end
	if ns.ConsumeBuyKeySticky then ns.ConsumeBuyKeySticky(pending.rule) end
	log("commodity price unavailable itemID=%s", tostring(pending.rule.itemID))
	if _G.C_AuctionHouse and type(_G.C_AuctionHouse.CancelCommoditiesPurchase) == "function" then
		pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
	end
	ns.HideBuyDialog()
	ns.DisableNativeBuy()
	ns.buyPending = nil
	local state = ns.GetBuyState(pending.rule)
	state.phase = "idle"
	state.plan = nil
	state.armedPlan = nil
	state.messageUntil = GetTime() + 10
	state.status = "No stock at your price - lower Qty or click Buy again"
	ns.Print("Buy Orders: no stock at or below your Max each for that quantity.")
	refreshRule(pending.rule)
	ns.ScheduleBuyLoop(pending.rule)
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
	if ns.AdvanceBuyKeyCycle then ns.AdvanceBuyKeyCycle(rule) end
	state.phase = "idle"
	state.plan = nil
	state.armedPlan = nil
	ns.armedBuyRule = nil
	state.messageUntil = GetTime() + 2.5
	state.status = string.format("Bought %d for %s", quantity, ns.FormatMoneyFull(cost))
	refreshRule(rule)
	ns.Print(string.format("Bought %d x %s for %s.", quantity, rule.itemName or ns.GetBuyItemDisplay(rule.itemID), ns.FormatMoneyFull(cost)))

	if state.loop then
		ns.After(AUTO_SEARCH_DELAY, function()
			if ns.buyPending then return end
			if not ns.IsAuctionHouseOpen() or not ns.IsBuyFrameShown() then return end
			if not rule.removed and ns.GetBuyRemaining(rule) > 0 then
				ns.SearchBuyRule(rule)
			end
		end)
	end
end

function ns.HandlePurchaseFailed()
	local pending = ns.buyPending
	if not pending then return end
	-- A failed buy is an attempt on this order; use up one sticky slot so the
	-- key moves on after a few misses.
	if ns.ConsumeBuyKeySticky then ns.ConsumeBuyKeySticky(pending.rule) end
	if ns.buyKeySticky and ns.buyKeySticky.rule == pending.rule then
		ns.buyKeySticky.remaining = 0
	end
	local rule = pending.rule
	log("purchase failed itemID=%s", tostring(rule.itemID))
	local state = ns.GetBuyState(rule)
	ns.buyPending = nil
	ns.HideBuyDialog()
	ns.DisableNativeBuy()
	state.phase = "idle"
	state.plan = nil
	state.armedPlan = nil
	state.messageUntil = GetTime() + 10
	state.status = "Purchase failed - click to try again"
	ns.Print("Buy Orders: purchase failed.")
	refreshRule(rule)
	ns.ScheduleBuyLoop(rule)
end

function ns.HandleAuctionClosed()
	log("auction house closed")
	ns.HideSecureBuyButtons()
	if not inCombat() then ns.DisableNativeBuy() end
	local pending = ns.buyPending
	if pending and pending.phase == "quote" then
		if _G.C_AuctionHouse and type(_G.C_AuctionHouse.CancelCommoditiesPurchase) == "function" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
		end
		ns.HideBuyDialog()
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
		ns.HideBuyDialog()
		local state = ns.GetBuyState(pending.rule)
		state.phase = "idle"
		state.plan = nil
		state.armedPlan = nil
		ns.DisableNativeBuy()
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
			state.armedPlan = nil
			ns.DisableNativeBuy()
			state.status = errorCode == 10 and "Auction house is busy - backing off" or "Search failed - retrying"
			refreshRule(rule)
			ns.ScheduleBuyLoop(rule, errorCode == 10 and 2 or 1)
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
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		local blockedAddon, blockedFunction = ...
		local stack = ""
		if type(_G.debugstack) == "function" then
			local ok, value = pcall(_G.debugstack, 2, 20, 20)
			if ok and value then stack = tostring(value) end
		end
		ns.lastBlockedAction = tostring(blockedFunction or blockedAddon or "?")
		log("ACTION %s addon=%s function=%s stack=%s", tostring(event), tostring(blockedAddon), tostring(blockedFunction), stack)
		if not ns.actionBlockedReported then
			ns.actionBlockedReported = true
			ns.Print("An action was blocked (" .. tostring(blockedFunction or blockedAddon or "?") .. "). Run /om buylog and send the log.")
		end
	elseif type(event) == "string" and event:find("^AUCTION_HOUSE_THROTTLED_") then
		local pending = ns.buyPending
		log("throttle event=%s pending=%s phase=%s ready=%s", tostring(event), tostring(pending ~= nil), tostring(pending and pending.phase or nil), tostring(throttleReady()))
		if event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and pending and pending.phase == "quote" then
			pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
			ns.HideBuyDialog()
			ns.buyPending = nil
			local state = ns.GetBuyState(pending.rule)
			state.phase = "idle"
			state.plan = nil
			state.status = "The auction house dropped the request - click again"
			refreshRule(pending.rule)
		end
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
	elseif event == "PLAYER_REGEN_ENABLED" then
		if ns.secureHidePending then
			ns.secureHidePending = false
			ns.HideSecureBuyButtons()
		end
		if ns.IsBuyFrameShown() then ns.UpdateSecureButtonVisibility() end
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
	if ns.vendorAhTab then PanelTemplates_DeselectTab(ns.vendorAhTab) end
	if ns.vendorFrame then ns.vendorFrame:Hide() end
	if ns.disAhTab then PanelTemplates_DeselectTab(ns.disAhTab) end
	if ns.disFrame then ns.disFrame:Hide() end
	if ns.snipeAhTab then PanelTemplates_DeselectTab(ns.snipeAhTab) end
	if ns.snipeFrame then ns.snipeFrame:Hide() end
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
	if ns.vendorAhTab then
		anchor = ns.vendorAhTab
	else
		local auctionatorTabs = _G.Auctionator and _G.Auctionator.State and _G.Auctionator.State.TabFrameRef
			and _G.Auctionator.State.TabFrameRef.Tabs
		if type(auctionatorTabs) == "table" and #auctionatorTabs > 0 then
			anchor = auctionatorTabs[#auctionatorTabs]
		end
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

function ns.HideSecureBuyButtons()
	if inCombat() then
		ns.secureHidePending = true
		return
	end
	local buttons = ns.secureBuyButtons or {}
	for index = 1, #buttons do
		buttons[index]:Hide()
	end
end

function ns.IsBuyRowVisible(row)
	local scroll = ns.buyScroll
	if not row or not scroll then return false end
	local top, bottom = row:GetTop(), row:GetBottom()
	local scrollTop, scrollBottom = scroll:GetTop(), scroll:GetBottom()
	if type(top) ~= "number" or type(bottom) ~= "number"
		or type(scrollTop) ~= "number" or type(scrollBottom) ~= "number" then
		return true
	end
	return top <= scrollTop and bottom >= scrollBottom
end

function ns.UpdateSecureButtonVisibility()
	if inCombat() then return end
	if not ns.buyFrame or not ns.buyFrame:IsShown() then
		ns.HideSecureBuyButtons()
		return
	end
	local rows = ns.buyRows or {}
	for index = 1, #rows do
		local row = rows[index]
		local secure = row.secureBuyButton
		if secure then
			local rule = row.rule
			local state = type(rule) == "table" and ns.buyRuntime and ns.buyRuntime[rule] or nil
			local otherPending = ns.buyPending and ns.buyPending.rule ~= rule
			local show = rule and state and not otherPending and ns.IsBuyRowVisible(row)
			secure:SetShown(show and true or false)
		end
	end
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
		buyQuantity = 20,
		spent = 0,
	}
	ns.db.buyOrders[#ns.db.buyOrders + 1] = rule
	for index = 1, #ns.db.buyOrders - 1 do
		if ns.db.buyOrders[index].keyTarget then rule.keyTarget = false break end
	end
	if rule.keyTarget == nil then rule.keyTarget = true end
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
	local wasKey = rule.keyTarget
	if ns.buyLoopRule == rule then ns.buyLoopRule = nil end
	if state.armedPlan then
		state.armedPlan = nil
		ns.DisableNativeBuy()
	end
	ns.buyRuntime[rule] = nil
	local orders = ns.db.buyOrders
	for index = #orders, 1, -1 do
		if orders[index] == rule then table.remove(orders, index) end
	end
	if wasKey and #orders > 0 then
		orders[1].keyTarget = true
	end
	ns.RefreshBuyFrame()
	ns.UpdateBuyKeyButton()
end

function ns.ResetBuyBudget(rule)
	if not rule then return end
	log("reset budget itemID=%s", tostring(rule.itemID))
	local state = ns.GetBuyState(rule)
	if ns.buyPending and ns.buyPending.rule == rule then return end
	rule.spent = 0
	rule.lowQuote = nil
	rule.lowQuoteAt = nil
	rule.lowQuoteQuantity = nil
	state.phase = "idle"
	state.plan = nil
	if state.armedPlan then
		state.armedPlan = nil
		ns.DisableNativeBuy()
	end
	state.status = "Budget reset - click Buy"
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
		state.status = "Ready to buy with the new limit"
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
		if text == (rule.itemName or "") then rule.itemTyped = nil end
		log("commit item raw=%q ruleName=%q ruleID=%s typed=%s focus=%s", tostring(text), tostring(rule.itemName), tostring(rule.itemID), tostring(rule.itemTyped), tostring(row.itemBox:HasFocus()))
		-- Only a name the player actually typed is looked up. Once it resolves
		-- to an item the field shows the real name, and Buy presses never
		-- search again.
		if rule.itemTyped and text ~= "" then
			local itemID = ns.ResolveBuyItemID(text)
			if itemID then
				applyPurchasableItem(row, itemID)
				if not row.itemBox:HasFocus() then row.itemBox:SetText(rule.itemName) end
			else
				local candidates = ns.FindBuyItemCandidates(text)
				if #candidates == 1 then
					applyPurchasableItem(row, candidates[1].itemID)
					rule.itemTyped = nil
					if not row.itemBox:HasFocus() then row.itemBox:SetText(rule.itemName) end
				elseif #candidates > 1 then
					rule.itemID = nil
					rule.itemName = text ~= "" and text or nil
					rule.itemTyped = nil
					state.phase = "idle"
					state.plan = nil
					state.status = "Several items match - shift-click one"
				elseif text ~= "" then
					-- Keep the typed text so the row can resolve it once the
					-- Auction House search comes back.
					rule.itemID = nil
					rule.itemName = text
					rule.itemTyped = nil
					state.phase = "idle"
					state.plan = nil
					if not ns.StartBuyItemLookup(row, text) and not state.status then
						state.status = "Unknown item"
					end
				else
					rule.itemID = nil
					rule.itemName = nil
					rule.itemTyped = nil
					state.phase = "idle"
					state.plan = nil
					state.status = "Set an item"
				end
			end
		end
	end

	commitMoney(rule, row.maxBox, "maxUnit")
	commitMoney(rule, row.budgetBox, "budgetLimit")
	if row.quantityBox then
		local quantity = math.floor(tonumber(row.quantityBox:GetText()) or 0)
		if quantity >= 1 and quantity ~= ns.GetBuyQuantity(rule) then
			rule.buyQuantity = quantity
			state.plan = nil
			state.armedPlan = nil
			state.blindKey = nil
			if ns.armedBuyRule == rule then ns.DisableNativeBuy() end
		end
		if not row.quantityBox:HasFocus() then
			row.quantityBox:SetText(tostring(ns.GetBuyQuantity(rule)))
		end
	end
	log("commit done itemID=%s max=%s budget=%s qty=%s spent=%s phase=%s", tostring(rule.itemID), tostring(rule.maxUnit), tostring(rule.budgetLimit), tostring(ns.GetBuyQuantity(rule)), tostring(rule.spent), tostring(state.phase))
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
	if not row or not row.rule or not row.itemBox then return end
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
	local remainingText = rule.budgetLimit and (ns.FormatMoneyFull(remaining) .. " left") or "no budget"
	if rule.lowQuote then
		remainingText = remainingText .. " · low " .. ns.FormatMoneyFull(rule.lowQuote)
	end
	row.remaining:SetText(remainingText)
	if not row.quantityBox:HasFocus() then
		local quantityText = tostring(ns.GetBuyQuantity(rule))
		if row.quantityBox:GetText() ~= quantityText then row.quantityBox:SetText(quantityText) end
	end

	local info = rule.itemID and ns.GetItemInfo(rule.itemID) or nil
	row.icon:SetTexture(info and info.texture or nil)
	if row.keyCheck then
		row.keyCheck:SetChecked(rule.keyTarget == true)
	end

	local busyOther = ns.buyPending and ns.buyPending.rule ~= rule
	local busySelf = ns.buyPending and ns.buyPending.rule == rule
	local secure = row.secureBuyButton
	local quantity = ns.GetBuyQuantity(rule)
	local valid = rule.itemID and rule.maxUnit and rule.maxUnit > 0 and quantity > 0

	if not busySelf then
		if not valid then
			state.phase = "idle"
			state.plan = nil
			state.armedPlan = nil
			if ns.armedBuyRule == rule then ns.DisableNativeBuy() end
			state.status = "Set item, max each and qty"
		elseif remaining <= 0 then
			state.phase = "idle"
			state.plan = nil
			state.armedPlan = nil
			if ns.armedBuyRule == rule then ns.DisableNativeBuy() end
			state.status = "Budget used - reset to buy again"
		end
	end

	if not busySelf and not busyOther and valid and remaining > 0 and ns.IsBuyFrameShown() then
		local key = string.format("%s|%s|%s", tostring(rule.itemID), tostring(quantity), tostring(rule.maxUnit))
		if not state.plan or state.blindKey ~= key or state.armedPlan ~= state.plan then
			local plan = {
				itemID = rule.itemID,
				quantity = quantity,
				cost = quantity * rule.maxUnit,
				maxUnit = rule.maxUnit,
			}
			state.phase = "ready"
			state.plan = plan
			state.blindKey = key
			ns.ArmBlindBuy(rule, plan)
		end
	end

	if not busySelf and state.phase == "ready" and state.plan then
		if not (state.messageUntil and GetTime() < state.messageUntil) then
			state.status = string.format("Buy %d at <= %s each", state.plan.quantity, ns.FormatMoneyFull(state.plan.maxUnit))
		end
	end

	row.status:SetText(state.status or "")
	setStatusColor(row, state)
	row.buyButton:Hide()

	if not inCombat() then
		if busySelf then
			secure:SetAttribute("clickbutton", nil)
			secure:SetText("Buying...")
			secure:Disable()
			secure:SetAlpha(0.5)
		elseif not busyOther and state.phase == "ready" and state.plan then
			secure:SetAttribute("clickbutton", nil)
			secure:SetText(string.format("Buy %d", state.plan.quantity))
			secure:Enable()
			secure:SetAlpha(1)
		else
			-- Keep the button clickable even before a plan is armed. The
			-- mouse-down handler commits the edit boxes and can arm the buy.
			secure:SetAttribute("clickbutton", nil)
			secure:SetText("Buy")
			secure:Enable()
			secure:SetAlpha(0.5)
		end
		if ns.IsBuyRowVisible(row) then secure:Show() else secure:Hide() end
	end

	row.resetButton:SetEnabled(not busySelf)
	ns.UpdateBuyKeyButton()
end

-- The Buy key can target several orders. They cycle in list order; after a
-- successful purchase the same order keeps the key for the next few attempts
-- so a restock is chased before moving on.
local KEY_STICKY_ATTEMPTS = 4

function ns.GetKeyTargetRules()
	local rules = {}
	local orders = ns.db and ns.db.buyOrders or {}
	for index = 1, #orders do
		if orders[index].keyTarget == true then rules[#rules + 1] = orders[index] end
	end
	return rules
end

function ns.SetBuyKeyRule(rule, selected)
	if not ns.db then return end
	if selected == nil then selected = true end
	if rule then rule.keyTarget = selected == true end
	ns.RefreshBuyFrame()
	ns.UpdateBuyKeyButton()
end

local function isBuyRuleReady(rule)
	if type(rule) ~= "table" or rule.removed then return false end
	local state = ns.GetBuyState(rule)
	return state and state.phase == "ready" and state.plan ~= nil
end

function ns.GetBuyKeyRow()
	local targets = ns.GetKeyTargetRules()
	if #targets == 0 then return nil end

	local sticky = ns.buyKeySticky
	if sticky and sticky.rule and sticky.remaining > 0 and isBuyRuleReady(sticky.rule) then
		for index = 1, #targets do
			if targets[index] == sticky.rule then
				ns.buyKeyCycleIndex = index
				break
			end
		end
		local state = ns.GetBuyState(sticky.rule)
		return state.row
	end

	local startIndex = (ns.buyKeyCycleIndex or 0) % #targets + 1
	for offset = 0, #targets - 1 do
		local index = (startIndex - 1 + offset) % #targets + 1
		local rule = targets[index]
		if isBuyRuleReady(rule) then
			ns.buyKeyCycleIndex = index
			local state = ns.GetBuyState(rule)
			return state.row
		end
	end
	return nil
end

-- After a successful purchase the same order keeps the key for the next few
-- attempts, so a restock is chased before the key moves on.
function ns.AdvanceBuyKeyCycle(successfulRule)
	local targets = ns.GetKeyTargetRules()
	if #targets == 0 then return end

	local index
	for lookup = 1, #targets do
		if targets[lookup] == successfulRule then
			index = lookup
			break
		end
	end
	if not index then return end

	successfulRule.keyStickyLeft = KEY_STICKY_ATTEMPTS
	ns.buyKeySticky = {
		rule = successfulRule,
		remaining = KEY_STICKY_ATTEMPTS,
		position = index,
	}
	ns.buyKeyCycleIndex = index
end

function ns.ConsumeBuyKeySticky(rule)
	local sticky = ns.buyKeySticky
	if not sticky or sticky.rule ~= rule then return end
	sticky.remaining = sticky.remaining - 1
	if rule.keyStickyLeft then rule.keyStickyLeft = rule.keyStickyLeft - 1 end
	if sticky.remaining > 0 then return end

	-- Stickiness is spent: move the key to the next checked order.
	ns.buyKeySticky = nil
	local targets = ns.GetKeyTargetRules()
	if #targets == 0 then return end
	local position = sticky.position or ns.buyKeyCycleIndex or 1
	ns.buyKeyCycleIndex = position % #targets + 1
end

function ns.GetBuyKeyLabel()
	local targets = ns.GetKeyTargetRules()
	if #targets == 0 then return "no key target" end
	local row = ns.buyKeyRow
	local name = row and row.rule and (ns.GetBuyItemDisplay(row.rule.itemID) or row.rule.itemName)
	if targets and #targets > 1 then
		local sticky = ns.buyKeySticky
		if sticky and sticky.remaining > 0 then
			return string.format("%s (+%d)", tostring(name or "?"), sticky.remaining)
		end
		return string.format("%s (1/%d)", tostring(name or "?"), #targets)
	end
	return tostring(name or "?")
end

function ns.UpdateBuyKeyButton()
	local button = ns.buyKeyButton
	if not button then return end
	if ns.buyPending then
		button:SetAttribute("clickbutton", nil)
		button:Disable()
		ns.UpdateBuyKeyStatus()
		return
	end
	local row = ns.GetBuyKeyRow()
	ns.buyKeyRow = row
	local state = row and type(row.rule) == "table" and ns.GetBuyState(row.rule) or nil
	if not row or not state or state.phase ~= "ready" or not state.plan then
		button:SetAttribute("clickbutton", nil)
		button:Disable()
		ns.UpdateBuyKeyStatus()
		return
	end
	if ns.armedBuyRule ~= row.rule or state.armedPlan ~= state.plan then
		ns.ArmBlindBuy(row.rule, state.plan)
	end
	button:SetAttribute("clickbutton", nil)
	button:Enable()
	ns.UpdateBuyKeyStatus()
end

function ns.UpdateBuyKeyStatus()
	local label = ns.buyKeyStatus
	if not label then return end
	local targets = ns.GetKeyTargetRules()
	if #targets == 0 then
		label:SetText("")
		return
	end
	local row = ns.buyKeyRow
	local name = row and row.rule and (ns.GetBuyItemDisplay(row.rule.itemID) or row.rule.itemName) or "nothing ready"
	local sticky = ns.buyKeySticky
	if sticky and sticky.remaining > 0 then
		label:SetText(string.format("Key: %s x%d", tostring(name), sticky.remaining + 1))
		return
	end
	local position
	if ns.buyKeyCycleIndex and #targets > 0 then
		position = ns.buyKeyCycleIndex
	end
	label:SetText(string.format("Key: %s%s", tostring(name), position and string.format(" (%d/%d)", position, #targets) or ""))
end

function ns.ClearBuyKeyBinding()
	if ns.buyFrame then pcall(ClearOverrideBindings, ns.buyFrame) end
end

function ns.ApplyBuyKeyBinding()
	local frame = ns.buyFrame
	if not frame then return end
	ns.ClearBuyKeyBinding()
	if not frame:IsShown() then return end
	local key = ns.db and ns.db.settings and ns.db.settings.buyKey
	if not key or key == "" then return end
	if not ns.buyKeyButton then return end
	local ok = pcall(SetOverrideBindingClick, frame, true, key, "OpenMarginBuyKeyButton", "LeftButton")
	if not ok then ns.Print("Buy Orders: that is not a valid key binding.") end
end

function ns.BeginKeyBuy()
	local row = ns.buyKeyRow or ns.GetBuyKeyRow()
	if row then ns.BeginSecureBuy(row) end
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

	row.keyCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.keyCheck:SetSize(18, 18)
	row.keyCheck:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 4)
	row.keyCheck:SetScript("OnClick", function(self)
		ns.SetBuyKeyRule(row.rule, self:GetChecked() == true)
	end)
	row.keyCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Use for Buy key")
		GameTooltip:AddLine("Checked orders are triggered by the Buy key, one after another.", 1, 1, 1, true)
		GameTooltip:AddLine("After a successful buy the same order keeps the key for 4 more attempts.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	row.keyCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row.itemBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.itemBox:SetSize(188, 20)
	row.itemBox:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -7)
	row.itemBox:SetAutoFocus(false)
	row.itemBox:SetMaxLetters(140)
	row.itemBox:SetHyperlinksEnabled(true)
	row.itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	row.itemBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	-- Typing a name marks the field for a lookup. Any later change (including
	-- the resolved name being written back) clears the mark, so the search
	-- runs once per typed name.
	row.itemBox:HookScript("OnTextChanged", function(self, userInput)
		if userInput and row.rule then row.rule.itemTyped = true end
	end)

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

	row.quantityBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.quantityBox:SetSize(50, 20)
	row.quantityBox:SetPoint("TOPLEFT", row, "TOPLEFT", 392, -7)
	row.quantityBox:SetAutoFocus(false)
	row.quantityBox:SetMaxLetters(7)
	row.quantityBox:SetNumeric(true)
	row.quantityBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	row.quantityBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	row.remaining = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.remaining:SetPoint("TOPLEFT", row, "TOPLEFT", 450, -11)
	row.remaining:SetWidth(86)
	row.remaining:SetJustifyH("LEFT")

	row.resetButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.resetButton:SetSize(48, 20)
	row.resetButton:SetPoint("TOPLEFT", row, "TOPLEFT", 544, -7)
	row.resetButton:SetText("Reset")
	row.resetButton:SetScript("OnClick", function()
		ns.ResetBuyBudget(row.rule)
	end)

	row.buyButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.buyButton:SetSize(76, 22)
	row.buyButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -30, -5)
	row.buyButton:SetText("Buy")
	row.buyButton:Hide()

	-- Secure proxy for the native Buy button. Blizzard blocks
	-- StartCommoditiesPurchase when addon code calls it, so the purchase must
	-- be initiated by clicking the Auction House's own button from a secure
	-- action button. Keep it parented to UIParent so the secure template does
	-- not mark the Auction House frame protected.
	row.secureBuyButton = CreateFrame("Button", nil, _G.UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
	row.secureBuyButton:SetSize(76, 22)
	row.secureBuyButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -30, -5)
	row.secureBuyButton:SetFrameStrata("DIALOG")
	row.secureBuyButton:SetFrameLevel(100)
	row.secureBuyButton:SetAttribute("type", "click")
	row.secureBuyButton:RegisterForClicks("AnyDown")
	row.secureBuyButton:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then ns.BeginSecureBuy(row) end
	end)
	row.secureBuyButton:HookScript("PostClick", function()
		ns.After(0, function()
			if row.rule then ns.UpdateBuyRow(row) end
		end)
	end)
	row.secureBuyButton:Hide()
	ns.secureBuyButtons = ns.secureBuyButtons or {}
	ns.secureBuyButtons[#ns.secureBuyButtons + 1] = row.secureBuyButton

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.deleteButton:SetSize(20, 20)
	row.deleteButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
	row.deleteButton:SetText("X")
	row.deleteButton:SetScript("OnClick", function()
		ns.DeleteBuyRule(row.rule)
	end)

	row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.status:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -32)
	row.status:SetWidth(540)
	row.status:SetJustifyH("LEFT")

	local function commit() ns.CommitBuyRow(row); ns.UpdateBuyRow(row) end
	row.maxBox:HookScript("OnEditFocusLost", commit)
	row.budgetBox:HookScript("OnEditFocusLost", commit)
	row.quantityBox:HookScript("OnEditFocusLost", commit)

	row.itemBox:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Item")
		GameTooltip:AddLine("Shift-click an item, type its exact name, or paste an item link.", 1, 1, 1, true)
		GameTooltip:AddLine("Typed names are looked up in the Auction House, so open it first.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	row.itemBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
					state.status = "Click Buy"
					ns.UpdateBuyRow(row)
				end
			end
			ClearCursor()
		end
	end)

	row.buyButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Buy Orders")
		GameTooltip:AddLine("Blind buy: requests Qty units, then checks the live quote against Max each and the budget.", 1, 1, 1, true)
		GameTooltip:AddLine("Only listings at or below Max each are bought. The confirmed price is checked again before purchase.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	row.buyButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	row.secureBuyButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Buy Orders")
		GameTooltip:AddLine("Starts a blind purchase for Qty units. The live Auction House quote is checked against Max each and the remaining budget before confirming.", 1, 1, 1, true)
		GameTooltip:AddLine("A larger Qty can include higher price tiers; lower it for tighter control.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	row.secureBuyButton:SetScript("OnLeave", function()
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

	local keyButton = CreateFrame("Button", "OpenMarginBuyKeyButton", _G.UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
	keyButton:SetSize(1, 1)
	keyButton:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 0, 0)
	keyButton:SetAlpha(0)
	keyButton:SetAttribute("type", "click")
	keyButton:RegisterForClicks("AnyDown")
	keyButton:SetScript("OnClick", function() ns.BeginKeyBuy() end)
	keyButton:Show()
	ns.buyKeyButton = keyButton

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
	title:SetText("Buy Orders")
	ns.buyTitle = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	hint:SetWidth(560)
	hint:SetJustifyH("LEFT")
	hint:SetText("Blind buy: shift-click an item, set Max each, Budget and Qty, then click Buy. The live quote is checked before confirming.")
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

	local keyBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	keyBox:SetSize(60, 20)
	keyBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -38)
	keyBox:SetAutoFocus(false)
	keyBox:SetMaxLetters(20)
	keyBox:SetText(ns.db and ns.db.settings and ns.db.settings.buyKey or "")
	keyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	keyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	keyBox:SetScript("OnEditFocusLost", function(self)
		local text = ns.Trim(self:GetText()):upper()
		ns.db.settings.buyKey = text
		self:SetText(text)
		ns.ApplyBuyKeyBinding()
	end)
	keyBox:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Buy key")
		GameTooltip:AddLine("While the Buy Orders tab is open, this key clicks the first ready Buy row.", 1, 1, 1, true)
		GameTooltip:AddLine("Use a key you do not type in the fields, such as F8.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	keyBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ns.buyKeyBox = keyBox

	local keyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	keyLabel:SetPoint("RIGHT", keyBox, "LEFT", -6, 0)
	keyLabel:SetText("Buy key:")
	ns.buyKeyLabel = keyLabel

	local keyStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	keyStatus:SetPoint("LEFT", keyLabel, "LEFT", 0, -14)
	keyStatus:SetTextColor(0.75, 0.75, 0.75)
	ns.buyKeyStatus = keyStatus

	local headers = {
		{ text = "Key", x = 6, width = 24 },
		{ text = "Item", x = 36, width = 188 },
		{ text = "Max each", x = 232, width = 66 },
		{ text = "Budget", x = 308, width = 76 },
		{ text = "Qty", x = 392, width = 50 },
		{ text = "Remaining", x = 450, width = 86 },
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
	scroll:HookScript("OnVerticalScroll", function() ns.UpdateSecureButtonVisibility() end)
	scroll:HookScript("OnScrollRangeChanged", function() ns.UpdateSecureButtonVisibility() end)
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
		ns.UpdateBuyKeyButton()
		ns.ApplyBuyKeyBinding()
	end)
	frame:SetScript("OnHide", function()
		ns.ClearBuyKeyBinding()
		ns.HideSecureBuyButtons()
		if ns.buyLoopRule and ns.StopBuyLoop then
			ns.StopBuyLoop(ns.buyLoopRule)
		end
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
		local row = ns.buyRows[index]
		row.rule = nil
		if row.secureBuyButton then row.secureBuyButton:Hide() end
		row:Hide()
	end

	content:SetHeight(math.max(#orders * 56, 1))
	ns.buyEmpty:SetShown(#orders == 0)
	ns.UpdateSecureButtonVisibility()
	ns.UpdateBuyKeyButton()
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
		state.status = "Click Buy"
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
	"PLAYER_REGEN_ENABLED",
	"COMMODITY_SEARCH_RESULTS_ADDED",
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_ADDED",
	"ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED",
	"COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED",
	"COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_SHOW_ERROR",
	"AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
	"ADDON_ACTION_BLOCKED",
	"ADDON_ACTION_FORBIDDEN",
	"GET_ITEM_INFO_RECEIVED",
}
for index = 1, #buyEvents do
	pcall(eventFrame.RegisterEvent, eventFrame, buyEvents[index])
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnBuyEvent, event, ...)
	if not ok then ns.ReportError(err) end
end)
