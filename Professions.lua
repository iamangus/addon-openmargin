local addonName, ns = ...

local TAG_WIDTHS = {
	profit = 46,
	margin = 40,
	both = 84,
}

local function safeHook(target, method, fn)
	if target and type(target[method]) == "function" then
		local ok = pcall(hooksecurefunc, target, method, fn)
		return ok
	end
	return false
end

function ns.GetSchematicForm()
	local frame = _G.ProfessionsFrame
	local page = frame and frame.CraftingPage
	return page and page.SchematicForm or nil
end

function ns.GetCraftingPage()
	local frame = _G.ProfessionsFrame
	return frame and frame.CraftingPage or nil
end

function ns.GetRecipeListProvider()
	local page = ns.GetCraftingPage()
	local list = page and page.RecipeList
	local scrollBox = list and list.ScrollBox
	if scrollBox and type(scrollBox.GetDataProvider) == "function" then
		local ok, provider = pcall(scrollBox.GetDataProvider, scrollBox)
		if ok then return provider end
	end
	return nil
end

local function compareCategoryEntries(lhs, rhs, original, ctx)
	local leftData = lhs:GetData()
	local rightData = rhs:GetData()
	local leftRecipe = leftData and leftData.recipeInfo
	local rightRecipe = rightData and rightData.recipeInfo

	if leftRecipe and rightRecipe then
		local leftValue = ns.GetSortValue(leftRecipe.recipeID, ctx)
		local rightValue = ns.GetSortValue(rightRecipe.recipeID, ctx)

		if leftValue == nil and rightValue == nil then
			return original(lhs, rhs)
		elseif leftValue == nil then
			return false
		elseif rightValue == nil then
			return true
		elseif leftValue ~= rightValue then
			return leftValue > rightValue
		end
	end

	return original(lhs, rhs)
end

local function applyNode(node, ctx)
	if not node then return end

	local data = node.GetData and node:GetData()
	if data and data.categoryInfo then
		if not node.cpSortPatched then
			node.cpSortPatched = true
			node.cpOriginalComparator = node.sortComparator
		end
		local original = node.cpOriginalComparator
		if type(original) ~= "function" then
			original = function(a, b) return false end
		end
		node:SetSortComparator(function(lhs, rhs)
			return compareCategoryEntries(lhs, rhs, original, ctx)
		end, false, false)
	end

	local children = node.nodes
	if children then
		for index = 1, #children do
			applyNode(children[index], ctx)
		end
	end
end

local function restoreNode(node)
	if not node then return end

	if node.cpSortPatched then
		if type(node.cpOriginalComparator) == "function" then
			node:SetSortComparator(node.cpOriginalComparator, false, false)
		else
			node.sortComparator = nil
		end
		node.cpOriginalComparator = nil
		node.cpSortPatched = nil
	end

	local children = node.nodes
	if children then
		for index = 1, #children do
			restoreNode(children[index])
		end
	end
end

function ns.ApplyProfitSort(provider)
	provider = provider or ns.GetRecipeListProvider()
	if not provider or not provider.node then return end

	local enabled = ns.db and ns.db.settings and ns.db.settings.sort
	local ctx = ns.NewCostContext()
	ns.sortContext = ctx

	if enabled then
		applyNode(provider.node, ctx)
	else
		restoreNode(provider.node)
	end

	if type(provider.Invalidate) == "function" then
		pcall(provider.Invalidate, provider)
	end

	ns.sortContext = nil
end

function ns.RefreshSort()
	ns.ApplyProfitSort()
end

function ns.InstallSort()
	ns.sortReady = true
	if ns.db and ns.db.settings.sort then
		ns.ApplyProfitSort()
	end
end

function ns.RefreshVisibleRecipeTags()
	local page = ns.GetCraftingPage()
	local list = page and page.RecipeList
	local scrollBox = list and list.ScrollBox
	if not scrollBox or type(scrollBox.EnumerateFrames) ~= "function" then return end

	local ok = pcall(function()
		for button in scrollBox:EnumerateFrames() do
			local elementData = button.GetElementData and button:GetElementData()
			local recipeInfo = elementData
				and ((elementData.data and elementData.data.recipeInfo) or elementData.recipeInfo)
			if recipeInfo then
				ns.UpdateRecipeRowTag(button, recipeInfo)
			end
		end
	end)
	if not ok then
		-- A partially constructed scroll frame can be ignored.
	end
end

function ns.RefreshProfessionUI()
	if ns.InstallProfessionHooks then ns.InstallProfessionHooks() end
	ns.RefreshVisibleRecipeTags()
	if ns.RefreshBreakdown then ns.RefreshBreakdown() end
end

-- The profession frame can finish building its recipe list just after
-- TRADE_SKILL_SHOW. Refresh once the layout settles as well.
function ns.ScheduleProfessionRefresh()
	if not ns.professionDelayedRefresh then
		ns.professionDelayedRefresh = true
		ns.After(1.2, function()
			ns.professionDelayedRefresh = false
			ns.RefreshProfessionUI()
		end)
	end
	if ns.professionRefreshScheduled then return end
	ns.professionRefreshScheduled = true
	ns.After(0.3, function()
		ns.professionRefreshScheduled = false
		ns.RefreshProfessionUI()
	end)
end

function ns.RefreshProfessionList()
	local frame = _G.ProfessionsFrame
	if not frame then return end
	if type(frame.IsShown) == "function" and not frame:IsShown() then return end
	ns.ApplyProfitSort()
	ns.RefreshVisibleRecipeTags()
	ns.RefreshBreakdown()
end

function ns.AddFilterMenuItems(rootDescription)
	if not rootDescription or not ns.db then return end

	rootDescription:CreateSpacer()
	rootDescription:CreateCheckbox("Sort by profit", function()
		return ns.db.settings.sort == true
	end, function()
		ns.db.settings.sort = not ns.db.settings.sort
		ns.OnSettingChanged()
	end)
	rootDescription:CreateCheckbox("Vendor net", function()
		return ns.db.settings.net == "vendor"
	end, function()
		ns.db.settings.net = ns.db.settings.net == "vendor" and "ah" or "vendor"
		ns.OnSettingChanged()
	end)
end

function ns.UpdateRecipeRowTag(button, recipeInfo)
	if not button or not ns.db then return end

	local tag = button.OpenMarginTag
	if not tag then
		tag = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		tag:SetJustifyH("RIGHT")
		tag:SetWordWrap(false)
		button.OpenMarginTag = tag
	end

	local mode = ns.db.settings.tag or "profit"
	tag:ClearAllPoints()
	if button.LockedIcon and button.LockedIcon:IsShown() then
		tag:SetPoint("RIGHT", button.LockedIcon, "LEFT", -2, 0)
	else
		tag:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	end

	-- Show a neutral tag first. If anything below fails, the row still gets a
	-- visible "—" instead of silently losing the whole tag.
	tag:SetText("—")
	tag:SetTextColor(0.55, 0.55, 0.55)
	tag:Show()

	if not recipeInfo then return end

	if _G.Professions and type(_G.Professions.GetHighestLearnedRecipe) == "function" then
		local ok, highest = pcall(_G.Professions.GetHighestLearnedRecipe, recipeInfo)
		if ok and highest then recipeInfo = highest end
	end
	if not recipeInfo.recipeID then return end

	local existing = ns.GetRecipe(recipeInfo.recipeID)
	if not existing or not existing.schemaLoaded then
		local ok, err = pcall(ns.EnsureRecipe, recipeInfo.recipeID)
		if not ok then ns.ReportError(err) end
	end

	local econOk, econ = pcall(ns.GetCachedEconomics, recipeInfo.recipeID)
	if not econOk then
		ns.ReportError(econ)
		econ = nil
	end
	local text, r, g, b = ns.GetTag(econ)
	tag:SetText(text)
	tag:SetTextColor(r, g, b)
	tag:Show()

	local tagWidth = 0
	if type(tag.GetStringWidth) == "function" then
		local ok, width = pcall(tag.GetStringWidth, tag)
		if ok and type(width) == "number" and width > 0 then tagWidth = width end
	end
	if tagWidth <= 0 then
		tagWidth = TAG_WIDTHS[mode] or TAG_WIDTHS.profit
	end
	tagWidth = math.ceil(tagWidth)
	tag:SetWidth(math.max(1, tagWidth))

	if button.Label then
		-- Start from the row width rather than the label's current width: the
		-- current width may already have been reduced by a previous tag update.
		local rowWidth = button.GetWidth and button:GetWidth() or 0
		if rowWidth and rowWidth > 0 then
			local rightFramesWidth = 0
			if button.LockedIcon and button.LockedIcon:IsShown() then
				rightFramesWidth = button.LockedIcon:GetWidth() or 0
			end
			local countWidth = 0
			if button.Count and button.Count:IsShown() then
				countWidth = button.Count:GetStringWidth() or 0
			end
			local skillWidth = button.SkillUps and button.SkillUps:GetWidth() or 26
			local available = rowWidth - (rightFramesWidth + countWidth + 10 + skillWidth + tagWidth + 4)
			button.Label:SetWidth(rowWidth)
			button.Label:SetWidth(math.max(24, math.min(available, button.Label:GetStringWidth())))
		end
	end
end

function ns.OnRecipeRowInit(button, node)
	if not button or not node or not ns.db then return end
	local elementData = node:GetData()
	local recipeInfo = elementData
		and ((elementData.data and elementData.data.recipeInfo) or elementData.recipeInfo)
	if not recipeInfo then return end
	ns.UpdateRecipeRowTag(button, recipeInfo)
end

local function addPanelRow(panel, key, label, y, emphasized)
	local left = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	left:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
	left:SetText(label)

	local right = panel:CreateFontString(nil, "OVERLAY", emphasized and "GameFontHighlightSmall" or "GameFontNormalSmall")
	right:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, y)
	right:SetJustifyH("RIGHT")
	right:SetText("—")

	panel.rows[key] = { left = left, right = right }
	return right
end

function ns.CreateBreakdownPanel(form)
	if ns.breakdownPanel then
		if ns.breakdownPanel:GetParent() ~= form then
			ns.breakdownPanel:SetParent(form)
			ns.breakdownPanel:ClearAllPoints()
			ns.breakdownPanel:SetPoint("BOTTOM", form, "BOTTOM", 0, 48)
		end
		return ns.breakdownPanel
	end

	local ok, created = pcall(CreateFrame, "Frame", nil, form, "BackdropTemplate")
	panel = ok and created or CreateFrame("Frame", nil, form)
	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 8,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		panel:SetBackdropColor(0, 0, 0, 0.55)
	end

	panel:SetSize(340, 151)
	panel:SetPoint("BOTTOM", form, "BOTTOM", 0, 48)
	panel:SetFrameStrata("HIGH")
	panel:EnableMouse(true)
	if type(panel.SetMouseClickEnabled) == "function" then
		panel:SetMouseClickEnabled(false)
	end
	panel.rows = {}

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -8)
	title:SetText("OpenMargin")
	panel.title = title

	local age = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	age:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -8)
	age:SetJustifyH("RIGHT")
	age:SetText("Auctionator")
	panel.age = age

	addPanelRow(panel, "cost", "Craft cost", -26)
	addPanelRow(panel, "sale", "Sale price", -41)
	addPanelRow(panel, "vendor", "Vendor net", -56)
	addPanelRow(panel, "sales", "Sales / day", -71)

	local divider = panel:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.15)
	divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -90)
	divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -90)
	divider:SetHeight(1)

	addPanelRow(panel, "net", "Net profit", -97, true)
	panel.rows.net.right:SetFontObject("GameFontHighlight")

	local sortCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	sortCheck:SetSize(20, 20)
	sortCheck:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 6)
	sortCheck:SetScript("OnClick", function()
		ns.db.settings.sort = not ns.db.settings.sort
		ns.OnSettingChanged()
	end)
	panel.sortCheck = sortCheck

	local sortLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sortLabel:SetPoint("LEFT", sortCheck, "RIGHT", 2, 0)
	sortLabel:SetText("Sort")

	local vendorCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	vendorCheck:SetSize(20, 20)
	vendorCheck:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 88, 6)
	vendorCheck:SetScript("OnClick", function()
		ns.db.settings.net = ns.db.settings.net == "vendor" and "ah" or "vendor"
		ns.OnSettingChanged()
	end)
	panel.vendorCheck = vendorCheck

	local vendorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	vendorLabel:SetPoint("LEFT", vendorCheck, "RIGHT", 2, 0)
	vendorLabel:SetText("Vendor net")

	panel:SetScript("OnEnter", function() ns.ShowBreakdownTooltip(panel) end)
	panel:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)

	ns.breakdownPanel = panel
	return panel
end

local function setRowValue(row, text, r, g, b)
	if not row then return end
	row.right:SetText(text or "—")
	if r then
		row.right:SetTextColor(r, g, b)
	else
		row.right:SetTextColor(0.9, 0.9, 0.9)
	end
end

function ns.UpdateBreakdownPanel(form)
	if not ns.db then return end
	form = form or ns.GetSchematicForm()
	if not form then return end
	if not ns.db.settings.panel then
		if ns.breakdownPanel then ns.breakdownPanel:Hide() end
		return
	end

	local panel = ns.CreateBreakdownPanel(form)
	local recipeInfo = form.GetRecipeInfo and form:GetRecipeInfo()
	if not recipeInfo then
		panel:Hide()
		return
	end

	local existing = ns.GetRecipe(recipeInfo.recipeID)
	if not existing or not existing.schemaLoaded then
		ns.EnsureRecipe(recipeInfo.recipeID)
	end
	local econ = ns.GetCachedEconomics(recipeInfo.recipeID)
	panel.recipeID = recipeInfo.recipeID
	panel.econ = econ
	panel:Show()

	local hasAuctionator = ns.GetAuctionatorAPI() ~= nil
	if econ and econ.recipe then
		local title = econ.recipe.name or "OpenMargin"
		if _G.issecretvalue and _G.issecretvalue(title) then title = "OpenMargin" end
		panel.title:SetText(title)
		local age = econ.sale and econ.recipe.outputItemID and ns.GetAuctionatorAge(econ.recipe.outputItemID)
		if not hasAuctionator then
			panel.age:SetText("Auctionator unavailable")
		elseif age then
			panel.age:SetText("Auctionator · " .. (ns.FormatAge(age) or "age unknown"))
		else
			panel.age:SetText("Auctionator")
		end
	else
		panel.title:SetText("OpenMargin")
		panel.age:SetText(hasAuctionator and "Auctionator" or "Auctionator unavailable")
	end

	if not econ then
		setRowValue(panel.rows.cost, "no recipe data")
		setRowValue(panel.rows.sale, "—")
		setRowValue(panel.rows.vendor, "—")
		setRowValue(panel.rows.sales, "—")
		setRowValue(panel.rows.net, "—")
		panel.sortCheck:SetChecked(ns.db.settings.sort == true)
		panel.vendorCheck:SetChecked(ns.db.settings.net == "vendor")
		return
	end

	if econ.costComplete then
		setRowValue(panel.rows.cost, ns.FormatMoneyFull(econ.cost))
	else
		setRowValue(panel.rows.cost, "partial")
	end

	if econ.sale then
		setRowValue(panel.rows.sale, ns.FormatMoneyFull(econ.sale))
	else
		setRowValue(panel.rows.sale, econ.recipe and econ.recipe.outputItemID and "no price" or "no item output")
	end

	local vendorValue = ns.GetVendorMetric(econ, ns.db.settings)
	if vendorValue then
		setRowValue(panel.rows.vendor, ns.FormatMoney(vendorValue, true))
	else
		setRowValue(panel.rows.vendor, "—")
	end

	setRowValue(panel.rows.sales, "—")

	local netText = econ.net and ns.FormatMoney(econ.net, true) or "—"
	if econ.marginSale then
		netText = netText .. "  (" .. ns.FormatPercent(econ.marginSale, true) .. ")"
	end
	local r, g, b = 0.85, 0.85, 0.85
	if econ.net and econ.net > 0 then
		r, g, b = 0.25, 1, 0.25
	elseif econ.net and econ.net < 0 then
		r, g, b = 1, 0.3, 0.3
	end
	setRowValue(panel.rows.net, netText, r, g, b)

	panel.sortCheck:SetChecked(ns.db.settings.sort == true)
	panel.vendorCheck:SetChecked(ns.db.settings.net == "vendor")
end

function ns.ShowBreakdownTooltip(panel)
	if not panel or not panel.econ then return end
	local econ = panel.econ
	local tooltip = _G.GameTooltip
	if not tooltip then return end

	local title = econ.recipe and econ.recipe.name or "OpenMargin"
	if _G.issecretvalue and _G.issecretvalue(title) then title = "OpenMargin" end
	tooltip:SetOwner(panel, "ANCHOR_LEFT")
	tooltip:AddLine(title, 1, 0.82, 0)
	tooltip:AddLine("Reagents:", 0.8, 0.8, 0.8)

	local details = econ.details or {}
	for index = 1, #details do
		local detail = details[index]
		local name = detail.itemID and ns.GetItemName(detail.itemID) or "unpriced reagent"
		local value
		if detail.unit then
			value = string.format("%d × %s = %s", detail.qty, ns.FormatMoneyFull(detail.unit), ns.FormatMoneyFull(detail.line))
			if detail.source == "craft" then
				value = value .. " (crafted)"
			elseif detail.source == "vendor" then
				value = value .. " (vendor)"
			end
		else
			value = string.format("%d × no price", detail.qty or 0)
		end
		tooltip:AddDoubleLine(name, value, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9)
	end

	tooltip:AddLine(" ")
	tooltip:AddDoubleLine("Craft cost", econ.costComplete and ns.FormatMoneyFull(econ.cost) or "partial", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("Sale price", econ.sale and ns.FormatMoneyFull(econ.sale) or "no price", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("AH cut", econ.ahCut and ("-" .. ns.FormatMoneyFull(econ.ahCut)) or "—", 0.8, 0.8, 0.8, 1, 0.5, 0.5)
	tooltip:AddDoubleLine("Net profit", econ.net and ns.FormatMoney(econ.net, true) or "—", 0.8, 0.8, 0.8, econ.net and econ.net > 0 and 0.25 or 1, econ.net and econ.net > 0 and 1 or 0.3, econ.net and econ.net > 0 and 0.25 or 0.3)
	tooltip:AddDoubleLine("Vendor net", econ.vendorNet and ns.FormatMoney(econ.vendorNet, true) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	if econ.vendorNetFull then
		tooltip:AddDoubleLine("Vendor after full cost", ns.FormatMoney(econ.vendorNetFull, true), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
	end
	if econ.marginCost then
		tooltip:AddDoubleLine("Margin (cost basis)", ns.FormatPercent(econ.marginCost, true), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
	end
	tooltip:AddLine("Sales/day needs a price-history scan; Auctionator exposes prices only.", 0.6, 0.6, 0.6, true)
	tooltip:Show()
end

function ns.UpdateReagentLabel(slot)
	if not slot then return end
	local schematic = slot.GetReagentSlotSchematic and slot:GetReagentSlotSchematic()
	if not schematic then
		if slot.OpenMarginPrice then slot.OpenMarginPrice:Hide() end
		return
	end

	local reagent = slot.GetReagent and slot:GetReagent()
	local itemID = reagent and reagent.itemID
	if not itemID then
		local reagents = schematic.reagents or {}
		itemID = reagents[1] and reagents[1].itemID
	end
	if not itemID then
		if slot.OpenMarginPrice then slot.OpenMarginPrice:Hide() end
		return
	end

	local price = slot.OpenMarginPrice
	if not price then
		price = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		price:SetPoint("TOPLEFT", slot, "TOPLEFT", 46, -39)
		price:SetWidth(132)
		price:SetJustifyH("LEFT")
		price:SetWordWrap(false)
		slot.OpenMarginPrice = price
	end

	local quantity = schematic.quantityRequired or 1
	local unit, source = ns.GetReagentUnitPrice(itemID)
	if unit then
		local line = unit * quantity
		price:SetText(string.format("%d × %s = %s", quantity, ns.FormatMoney(unit), ns.FormatMoney(line)))
		if source == "craft" then
			price:SetTextColor(0.40, 1.00, 0.40)
		elseif source == "vendor" then
			price:SetTextColor(1.00, 0.82, 0.00)
		else
			price:SetTextColor(0.85, 0.85, 0.85)
		end
	else
		price:SetText("no price")
		price:SetTextColor(0.55, 0.55, 0.55)
	end
	price:Show()
end

function ns.UpdateReagentLabels(form)
	form = form or ns.GetSchematicForm()
	if not form then return end

	local pool = form.reagentSlotPool
	if pool and type(pool.EnumerateActive) == "function" then
		local ok = pcall(function()
			for slot in pool:EnumerateActive() do
				ns.UpdateReagentLabel(slot)
			end
		end)
		if ok then return end
	end

	local slotsByType = form.reagentSlots
	if slotsByType then
		for _, slots in pairs(slotsByType) do
			for index = 1, #slots do
				ns.UpdateReagentLabel(slots[index])
			end
		end
	end
end

function ns.RefreshBreakdown()
	local form = ns.GetSchematicForm()
	if not form then return end
	ns.UpdateBreakdownPanel(form)
	ns.UpdateReagentLabels(form)
end

function ns.InstallProfessionHooks()
	if not ns.profHooks then ns.profHooks = {} end
	if not ns.profHooks.recipeList and _G.ProfessionsRecipeListRecipeMixin then
		ns.profHooks.recipeList = safeHook(_G.ProfessionsRecipeListRecipeMixin, "Init", function(button, node)
			local ok, err = pcall(ns.OnRecipeRowInit, button, node)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.profHooks.schematic and _G.ProfessionsRecipeSchematicFormMixin then
		ns.profHooks.schematic = safeHook(_G.ProfessionsRecipeSchematicFormMixin, "Init", function()
			local ok, err = pcall(ns.RefreshBreakdown)
			if not ok then ns.ReportError(err) end
		end)
		ns.profHooks.schematicRefresh = safeHook(_G.ProfessionsRecipeSchematicFormMixin, "Refresh", function()
			local ok, err = pcall(ns.RefreshBreakdown)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.profHooks.reagent and _G.ProfessionsReagentSlotMixin then
		ns.profHooks.reagent = safeHook(_G.ProfessionsReagentSlotMixin, "Update", function(slot)
			local ok, err = pcall(ns.UpdateReagentLabel, slot)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.profHooks.craftingPage and _G.ProfessionsCraftingPageMixin then
		ns.profHooks.craftingPage = safeHook(_G.ProfessionsCraftingPageMixin, "Init", function()
			local ok, err = pcall(function()
				ns.ApplyProfitSort()
				if ns.ScheduleCapture then ns.ScheduleCapture(false) end
				ns.RefreshBreakdown()

				local page = ns.GetCraftingPage()
				local dropdown = page and page.RecipeList and page.RecipeList.FilterDropdown
				if dropdown and type(dropdown.SetupMenu) == "function" and not dropdown.cpFilterPatched and _G.Professions then
					dropdown.cpFilterPatched = true
					pcall(dropdown.SetupMenu, dropdown, _G.Professions.SetupFilterMenu)
				end
			end)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.profHooks.filterMenu and _G.Professions and type(_G.Professions.SetupFilterMenu) == "function" then
		ns.profHooks.filterMenu = pcall(hooksecurefunc, _G.Professions, "SetupFilterMenu", function(_, rootDescription)
			local ok, err = pcall(ns.AddFilterMenuItems, rootDescription)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.profHooks.initFilterMenu and _G.Professions and type(_G.Professions.InitFilterMenu) == "function" then
		ns.profHooks.initFilterMenu = pcall(hooksecurefunc, _G.Professions, "InitFilterMenu", function(dropdown)
			if dropdown and type(dropdown.SetupMenu) == "function" and _G.Professions then
				dropdown.cpFilterPatched = true
				pcall(dropdown.SetupMenu, dropdown, _G.Professions.SetupFilterMenu)
			end
		end)
	end

	ns.InstallSort()
end
