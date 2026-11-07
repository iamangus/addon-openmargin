local addonName, ns = ...

-- Disenchant Flip: scan the Auction House for armor and weapons whose buyout is
-- below the estimated value of the enchanting materials they disenchant into.
-- The disenchant value comes from Auctionator's public API, or from Disenchant
-- Value's public API when that addon is installed. Disenchantable items are
-- non-commodity auctions, so the best deal is opened in the native Buy tab for
-- the final Buyout click.

local SUMMARY_TIMEOUT = 20
local ROW_HEIGHT = 30

local SORTS = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

local function inCombat()
	return _G.InCombatLockdown and _G.InCombatLockdown() or false
end

local function itemName(itemID)
	local info = ns.GetItemInfo(itemID)
	if info and info.name then return info.name end
	return "item:" .. tostring(itemID)
end

function ns.GetDisenchantProvider()
	local api = ns.GetAuctionatorAPI()
	if api and type(api.GetDisenchantPriceByItemID) == "function" then
		return "Auctionator"
	end
	local dv = _G.DisenchantValueAPI
	if dv and type(dv.GetValue) == "function" then
		return "Disenchant Value"
	end
	return nil
end

function ns.DisenchantDeals()
	local state = ns.dis
	local money = ns.GetBuyMoney()
	local list = {}
	for index = 1, #state.deals do
		local deal = state.deals[index]
		if not deal.opened and (not money or deal.minPrice <= money) then
			list[#list + 1] = deal
		end
	end
	table.sort(list, function(lhs, rhs)
		local left = lhs.margin or 0
		local right = rhs.margin or 0
		if left ~= right then return left > right end
		return (lhs.profit or 0) > (rhs.profit or 0)
	end)
	state.currentDeals = list
	return list
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function refreshDisenchantFrame()
	local state = ns.dis
	local frame = ns.disFrame
	if not frame then return end
	if not frame:IsShown() then return end

	local deals = ns.DisenchantDeals()
	local money = ns.GetBuyMoney()
	local provider = ns.GetDisenchantProvider()

	if state.status then
		ns.disStatus:SetText(state.status)
	end

	local summary
	if state.scanState == "scanning" then
		summary = string.format("Scanning...   Deals: %d   Money: %s", #deals, ns.FormatMoneyInput(money or 0))
	elseif state.scanState == "ready" then
		local top = deals[1]
		summary = string.format("Deals: %d   Money: %s", #deals, ns.FormatMoneyInput(money or 0))
		if top then
			summary = summary .. "   Best: " .. ns.FormatMoneyInput(top.profit) .. " (" .. ns.FormatPercent(top.margin, true) .. ")"
		end
	else
		summary = "Provider: " .. tostring(provider or "none")
	end
	ns.disSummary:SetText(summary .. "   Source: " .. tostring(provider or "none"))

	local top = deals[1]
	local action = ns.disActionButton
	if state.scanState == "scanning" then
		if top then
			action:SetText(string.format("Open next +%d%%", math.floor((top.margin or 0) * 100 + 0.5)))
			action:Enable()
		else
			action:SetText("Scanning...")
			action:Disable()
		end
	elseif state.scanState == "ready" then
		if top then
			action:SetText(string.format("Open next +%d%%", math.floor((top.margin or 0) * 100 + 0.5)))
			action:Enable()
		else
			action:SetText("Scan")
			action:Enable()
		end
	else
		action:SetText("Scan")
		action:Enable()
	end
	ns.disStopButton:SetShown(state.scanState == "scanning")

	local rows = ns.disRows or {}
	for index = 1, #deals do
		local row = rows[index]
		if not row then
			row = ns.CreateDisenchantRow(ns.disContent)
			rows[index] = row
		end
		row.deal = deals[index]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", ns.disContent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
		row:SetPoint("TOPRIGHT", ns.disContent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))
		row:Show()
		ns.UpdateDisenchantRow(row, index == 1)
	end
	for index = #deals + 1, #rows do
		rows[index]:Hide()
	end
	ns.disContent:SetHeight(math.max(#deals * ROW_HEIGHT, 1))
	ns.disEmpty:SetShown(#deals == 0)
end

function ns.RefreshDisenchantFrame()
	refreshDisenchantFrame()
end

function ns.CreateDisenchantRow(parent)
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

	row.itemText = label(14, 190)
	row.levelText = label(210, 40)
	row.buyText = label(255, 80)
	row.deText = label(340, 80)
	row.profitText = label(425, 80)
	row.marginText = label(510, 70)
	return row
end

function ns.UpdateDisenchantRow(row, isTop)
	local deal = row.deal
	if not deal then return end
	row.itemText:SetText(deal.name or itemName(deal.itemID))
	row.levelText:SetText(deal.itemLevel and tostring(deal.itemLevel) or "?")
	row.buyText:SetText(ns.FormatMoneyInput(deal.minPrice or 0))
	row.deText:SetText(ns.FormatMoneyInput(deal.deValue or 0))
	row.profitText:SetText(ns.FormatMoneyInput(deal.profit or 0))
	row.marginText:SetText(deal.margin and string.format("+%d%%", math.floor(deal.margin * 100 + 0.5)) or "—")
	row.bg:SetColorTexture(1, 1, 1, isTop and 0.10 or 0.035)
end

-- ---------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------

local function resetScan()
	local state = ns.dis
	state.scanState = "scanning"
	state.deals = {}
	state.currentDeals = {}
	state.seenItems = {}
	state.scanToken = (state.scanToken or 0) + 1
	state.summaryComplete = false
	state.browseRequests = 0
	state.summaryStarted = GetTime()
	state.status = "Requesting auction summary..."
	state.provider = ns.GetDisenchantProvider()
end

function ns.StartDisenchantScan()
	if ns.dis.scanState == "scanning" then return end
	if not ns.GetDisenchantProvider() then
		ns.dis.status = "No disenchant price source. Update Auctionator or install Disenchant Value."
		ns.RefreshDisenchantFrame()
		return
	end

	resetScan()
	ns.RefreshDisenchantFrame()

	local api = _G.C_AuctionHouse
	if not api or type(api.SendBrowseQuery) ~= "function" then
		ns.dis.scanState = "idle"
		ns.dis.status = "Auction house browse API unavailable"
		ns.RefreshDisenchantFrame()
		return
	end

	local query = {
		searchString = "",
		filters = {},
		itemClassFilters = {},
		sorts = SORTS,
	}
	local ok = pcall(api.SendBrowseQuery, query)
	log("disenchant scan browse query ok=%s", tostring(ok))
	if not ok then
		ns.dis.scanState = "idle"
		ns.dis.status = "Auction house browse query failed"
		ns.RefreshDisenchantFrame()
		return
	end

	local token = ns.dis.scanToken
	ns.After(1, function()
		if token == ns.dis.scanToken then ns.ProcessDisenchantBrowseResults(token) end
	end)
end

function ns.StopDisenchantScan()
	if ns.dis.scanState ~= "scanning" then return end
	ns.dis.scanToken = (ns.dis.scanToken or 0) + 1
	ns.dis.scanState = "ready"
	ns.dis.status = "Scan stopped"
	ns.RefreshDisenchantFrame()
end

function ns.ProcessDisenchantBrowseResults(token)
	local state = ns.dis
	if token ~= state.scanToken or state.scanState ~= "scanning" or state.summaryComplete then return end

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
		if itemID and not state.seenItems[itemID] then
			state.seenItems[itemID] = true
			local minPrice = tonumber(result.minPrice)
			local classID = ns.GetItemClassID(itemID)
			if minPrice and minPrice > 0 and (classID == 2 or classID == 4) then
				local deValue, provider = ns.GetDisenchantValue(itemID)
				if deValue and deValue > minPrice then
					local info = ns.GetItemInfo(itemID)
					local profit = deValue - minPrice
					state.deals[#state.deals + 1] = {
						itemID = itemID,
						itemKey = itemKey,
						minPrice = minPrice,
						deValue = deValue,
						profit = profit,
						margin = profit / minPrice,
						name = (info and info.name) or itemName(itemID),
						itemLevel = info and info.itemLevel,
						quality = info and info.quality,
						provider = provider,
					}
					log("disenchant deal itemID=%s buyout=%d de=%d profit=%d margin=%s",
						tostring(itemID), minPrice, deValue, profit, tostring(profit / minPrice))
				end
			end
		end
	end

	local full = true
	if api and type(api.HasFullBrowseResults) == "function" then
		local ok, value = pcall(api.HasFullBrowseResults)
		if ok then full = value == true end
	end

	if not full and state.browseRequests < 20 then
		state.browseRequests = state.browseRequests + 1
		if api.RequestMoreBrowseResults then pcall(api.RequestMoreBrowseResults) end
		ns.After(0.7, function()
			if token == state.scanToken then ns.ProcessDisenchantBrowseResults(token) end
		end)
		return
	end

	if not full and (GetTime() - (state.summaryStarted or 0)) < SUMMARY_TIMEOUT then
		ns.After(0.7, function()
			if token == state.scanToken then ns.ProcessDisenchantBrowseResults(token) end
		end)
		return
	end

	state.summaryComplete = true
	state.scanState = "ready"
	state.status = string.format("Ready: %d deals", #ns.DisenchantDeals())
	log("disenchant scan complete deals=%d", #state.deals)
	ns.RefreshDisenchantFrame()
end

-- ---------------------------------------------------------------------------
-- Action
-- ---------------------------------------------------------------------------

local function topDeal()
	local deals = ns.DisenchantDeals()
	return deals[1]
end

function ns.OpenDisenchantItem(deal)
	if not deal then return end
	local api = _G.C_AuctionHouse
	local ah = _G.AuctionHouseFrame
	deal.opened = true
	-- Opening the native item search replaces the browse results; do not let
	-- the summary scanner read those results as more auction pages.
	ns.dis.scanState = "ready"
	ns.dis.summaryComplete = true
	ns.dis.status = string.format("Open %s: %s buyout in the native Buy tab",
		deal.name or itemName(deal.itemID), ns.FormatMoneyInput(deal.minPrice or 0))
	ns.RefreshDisenchantFrame()

	local itemKey = deal.itemKey
	if not itemKey and api and api.MakeItemKey then
		local ok, value = pcall(api.MakeItemKey, deal.itemID)
		if ok then itemKey = value end
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

function ns.OnDisenchantAction()
	local state = ns.dis
	if state.scanState == "idle" then
		ns.StartDisenchantScan()
		return
	end
	if state.scanState ~= "scanning" and state.scanState ~= "ready" then return end

	local deal = topDeal()
	if not deal then
		if state.scanState == "ready" then ns.StartDisenchantScan() end
		return
	end
	ns.OpenDisenchantItem(deal)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function ns.OnDisenchantEvent(event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		ns.SetupDisenchantTab()
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ns.IsAuctionHouseOpen() then ns.SetupDisenchantTab() end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ns.dis.scanState = "idle"
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		if ns.dis.scanState == "scanning" and not ns.dis.summaryComplete then
			ns.ProcessDisenchantBrowseResults(ns.dis.scanToken)
		end
	elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
		local code = tonumber((...)) or ...
		if ns.dis.scanState == "scanning" then
			ns.dis.status = code == 10 and "Auction house busy - click again" or "Scan error - click again"
			ns.RefreshDisenchantFrame()
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

function ns.SelectDisenchantTab()
	local ah = _G.AuctionHouseFrame
	if not ah or not ns.disFrame then return false end
	if ns.disTabLib then
		local ok = pcall(ns.disTabLib.SetSelected, ns.disTabLib, "OpenMarginDisenchantFlip")
		return ok
	end

	ah:SetDisplayMode({})
	ah.displayMode = nil
	local tabs = ah.Tabs or {}
	for index = 1, #tabs do PanelTemplates_DeselectTab(tabs[index]) end
	if ns.ahTab then PanelTemplates_DeselectTab(ns.ahTab) end
	if ns.vendorAhTab then PanelTemplates_DeselectTab(ns.vendorAhTab) end
	if ns.snipeAhTab then PanelTemplates_DeselectTab(ns.snipeAhTab) end
	if ns.snipeFrame then ns.snipeFrame:Hide() end
	if ns.disAhTab then PanelTemplates_SelectTab(ns.disAhTab) end
	ah:SetTitle("Disenchant Flip")
	if ns.buyFrame then ns.buyFrame:Hide() end
	if ns.vendorFrame then ns.vendorFrame:Hide() end
	ns.disFrame:Show()
	ns.RefreshDisenchantFrame()
	return true
end

function ns.SetupDisenchantTab()
	local ah = _G.AuctionHouseFrame
	if not ah then return false end
	if not ns.disFrame then ns.CreateDisenchantFrame(ah) end
	if ns.disTabCreated then return true end

	local lib = getLibAHTab()
	if lib then
		local ok = pcall(lib.CreateTab, lib, "OpenMarginDisenchantFlip", ns.disFrame, "Disenchant", "Disenchant Flip")
		if ok then
			ns.disTabLib = lib
			ns.disTabCreated = true
			return true
		end
	end

	if not ah.Tabs or #ah.Tabs == 0 then return false end

	local root = CreateFrame("Frame", nil, ah)
	root:SetSize(10, 10)
	local anchor = ns.vendorAhTab or ns.ahTab or ah.Tabs[#ah.Tabs]
	root:SetPoint("TOPLEFT", anchor, "TOPRIGHT")

	local created, tab = pcall(CreateFrame, "Button", "OpenMarginDisenchantFlipTab", root, "AuctionHouseFrameDisplayModeTabTemplate")
	if not created or not tab then return false end
	tab:SetText("Disenchant")
	PanelTemplates_TabResize(tab, 20, nil, 70)
	tab:SetPoint("TOPLEFT", root, "TOPLEFT", 3, 0)
	PanelTemplates_DeselectTab(tab)
	tab.frameRef = ns.disFrame
	tab.tabHeader = "Disenchant Flip"
	tab:SetScript("OnClick", ns.SelectDisenchantTab)
	ns.disAhTab = tab
	ns.disTabRoot = root

	hooksecurefunc(ah, "SetDisplayMode", function(_, mode)
		if mode ~= nil and #mode > 0 then
			if ns.disFrame then ns.disFrame:Hide() end
			if ns.disAhTab then PanelTemplates_DeselectTab(ns.disAhTab) end
		end
	end)

	ns.disTabCreated = true
	return true
end

function ns.OpenDisenchantFlip()
	if not ns.IsAuctionHouseOpen() then
		ns.Print("Open the Auction House first; Disenchant Flip is a tab there.")
		return
	end
	if ns.SetupDisenchantTab() then ns.SelectDisenchantTab() end
end

function ns.CreateDisenchantFrame(ah)
	if ns.disFrame then return ns.disFrame end
	ah = ah or _G.AuctionHouseFrame
	if not ah then return nil end

	local frame = CreateFrame("Frame", "OpenMarginDisenchantFrame", ah, "InsetFrameTemplate")
	if ah.CategoriesList then
		frame:SetPoint("TOPLEFT", ah.CategoriesList, "TOPLEFT", 0, 0)
	else
		frame:SetPoint("TOPLEFT", ah, "TOPLEFT", 4, -70)
	end
	frame:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -23, 34)
	frame:SetFrameLevel(ah:GetFrameLevel() + 5)
	frame:Hide()
	ns.disFrame = frame
	ns.dis = ns.dis or {
		scanState = "idle",
		deals = {},
		status = "Scan the Auction House to find disenchant deals.",
	}
	ns.dis.deals = ns.dis.deals or {}
	ns.disRows = {}

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
	title:SetText("Disenchant Flip")
	ns.disTitle = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	hint:SetWidth(600)
	hint:SetJustifyH("LEFT")
	hint:SetText("Finds armor and weapons whose buyout is below the value of their disenchant materials. Open the best deal in the native Buy tab, buy it, then disenchant it.")

	local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	status:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -70)
	status:SetWidth(640)
	status:SetJustifyH("LEFT")
	ns.disStatus = status

	local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	summary:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -86)
	summary:SetWidth(740)
	summary:SetJustifyH("LEFT")
	summary:SetTextColor(0.75, 0.75, 0.75)
	ns.disSummary = summary

	local action = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	action:SetSize(110, 24)
	action:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -10)
	action:SetText("Scan")
	action:SetScript("OnClick", function() ns.OnDisenchantAction() end)
	ns.disActionButton = action

	local stop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	stop:SetSize(54, 24)
	stop:SetPoint("TOPRIGHT", action, "TOPLEFT", -6, 0)
	stop:SetText("Stop")
	stop:SetScript("OnClick", function() ns.StopDisenchantScan() end)
	stop:Hide()
	ns.disStopButton = stop

	local headers = {
		{ text = "Item", x = 14, width = 190 },
		{ text = "iLvl", x = 210, width = 40 },
		{ text = "Buyout", x = 255, width = 80 },
		{ text = "DE value", x = 340, width = 80 },
		{ text = "Profit", x = 425, width = 80 },
		{ text = "Margin", x = 510, width = 70 },
	}
	for index = 1, #headers do
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", frame, "TOPLEFT", headers[index].x, -108)
		label:SetWidth(headers[index].width)
		label:SetText(headers[index].text)
		label:SetTextColor(0.8, 0.8, 0.8)
	end

	local scroll = CreateFrame("ScrollFrame", "OpenMarginDisenchantScrollFrame", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -124)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 10)
	ns.disScroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(700, 1)
	scroll:SetScrollChild(content)
	ns.disContent = content

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("CENTER", scroll, "CENTER", 0, 20)
	empty:SetText("No disenchant deals yet. Click Scan.")
	ns.disEmpty = empty

	frame:SetScript("OnShow", function() ns.RefreshDisenchantFrame() end)
	frame:SetScript("OnHide", function() end)

	ns.RefreshDisenchantFrame()
	return frame
end

local disenchantEventFrame = CreateFrame("Frame")
local disenchantEvents = {
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"PLAYER_ENTERING_WORLD",
	"AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"AUCTION_HOUSE_SHOW_ERROR",
}
for index = 1, #disenchantEvents do
	pcall(disenchantEventFrame.RegisterEvent, disenchantEventFrame, disenchantEvents[index])
end
disenchantEventFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnDisenchantEvent, event, ...)
	if not ok then ns.ReportError(err) end
end)
