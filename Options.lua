local addonName, ns = ...

local function makeCheck(panel, text, getter, setter, x, y)
	local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	check.getter = getter
	check.setter = setter
	check:SetScript("OnClick", function(self)
		self.setter(self:GetChecked() == true)
		ns.OnSettingChanged()
		ns.RefreshOptions()
	end)

	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", check, "RIGHT", 4, 0)
	label:SetText(text)
	return check
end

local function makeButton(panel, text, width, x, y, onClick)
	local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	button:SetSize(width, 24)
	button:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

function ns.CreateOptions()
	if ns.optionsPanel then return ns.optionsPanel end

	local panel = CreateFrame("Frame", "OpenMarginOptionsPanel", _G.UIParent)
	panel.name = "OpenMargin"
	panel:SetSize(640, 520)
	ns.optionsPanel = panel

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
	title:SetText("OpenMargin")

	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	subtitle:SetText("Auctionator price source · WoW Forever")

	local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
	status:SetWidth(600)
	status:SetHeight(110)
	status:SetJustifyH("LEFT")
	status:SetJustifyV("TOP")
	panel.status = status

	local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -175)
	heading:SetText("Display")

	panel.tagButton = makeButton(panel, "Recipe tag: Profit", 190, 16, -198, function()
		ns.CycleTag()
		ns.RefreshOptions()
	end)

	panel.netButton = makeButton(panel, "Profit type: Auction House", 190, 16, -228, function()
		ns.CycleNet()
		ns.RefreshOptions()
	end)

	panel.sortCheck = makeCheck(panel, "Sort recipes by profit", function()
		return ns.db.settings.sort == true
	end, function(value)
		ns.db.settings.sort = value
	end, 16, -260)

	panel.panelCheck = makeCheck(panel, "Show breakdown panel", function()
		return ns.db.settings.panel == true
	end, function(value)
		ns.db.settings.panel = value
	end, 16, -288)

	panel.craftCheck = makeCheck(panel, "Price craftable reagents at their own craft cost", function()
		return ns.db.settings.craftReagents == true
	end, function(value)
		ns.db.settings.craftReagents = value
	end, 16, -316)

	panel.trainerCheck = makeCheck(panel, "Show profit at profession trainers", function()
		return ns.db.settings.trainer == true
	end, function(value)
		ns.db.settings.trainer = value
	end, 16, -344)

	panel.tooltipCheck = makeCheck(panel, "Show Auctionator price on item tooltips", function()
		return ns.db.settings.tooltips == true
	end, function(value)
		ns.db.settings.tooltips = value
	end, 16, -372)

	local pricingHeading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	pricingHeading:SetPoint("TOPLEFT", panel, "TOPLEFT", 330, -175)
	pricingHeading:SetText("Pricing")

	local cutLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	cutLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 330, -202)
	cutLabel:SetText("Auction House cut (%)")

	panel.cutBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	panel.cutBox:SetSize(60, 20)
	panel.cutBox:SetPoint("LEFT", cutLabel, "RIGHT", 10, 0)
	panel.cutBox:SetAutoFocus(false)
	panel.cutBox:SetNumeric(true)
	panel.cutBox:SetMaxLetters(4)
	panel.cutBox:SetScript("OnEnterPressed", function(self)
		ns.SetAHcut(self:GetText())
		self:ClearFocus()
		ns.RefreshOptions()
	end)
	panel.cutBox:SetScript("OnEditFocusLost", function(self)
		ns.SetAHcut(self:GetText())
		ns.RefreshOptions()
	end)

	local cutHint = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	cutHint:SetPoint("TOPLEFT", cutLabel, "BOTTOMLEFT", 0, -8)
	cutHint:SetWidth(270)
	cutHint:SetJustifyH("LEFT")
	cutHint:SetText("Applied to expected Auction House sale price. Vendor net does not use a cut.")

	panel.refreshButton = makeButton(panel, "Refresh prices", 150, 330, -260, function()
		ns.InvalidatePrices()
		ns.RefreshAll()
		ns.RefreshOptions()
	end)

	panel.recaptureButton = makeButton(panel, "Recapture profession", 150, 330, -290, function()
		if ns.ScheduleCapture then ns.ScheduleCapture(true) end
		ns.Print("Recipe capture queued for the open profession.")
	end)

	panel.resetButton = makeButton(panel, "Reset all data", 150, 330, -320, function()
		if _G.StaticPopup_Show then
			_G.StaticPopup_Show("OPENMARGIN_RESET_ALL")
		end
	end)

	local footer = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
	footer:SetText("Type /om for the full command list. Prices are read from Auctionator; run Auctionator's own scan to update them.")

	if _G.StaticPopupDialogs then
		_G.StaticPopupDialogs["OPENMARGIN_RESET_ALL"] = {
			text = "Reset all OpenMargin settings, recipes and cached data?",
			button1 = _G.YES or "Yes",
			button2 = _G.NO or "No",
			OnAccept = function()
				ns.ResetAll()
				ns.Print("All OpenMargin data reset.")
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
	end

	ns.RegisterOptionsPanel()
	ns.RefreshOptions()
	return panel
end

function ns.RegisterOptionsPanel()
	if ns.optionsRegistered or not ns.optionsPanel then return end

	if _G.Settings and type(_G.Settings.RegisterCanvasLayoutCategory) == "function" then
		local ok, category = pcall(_G.Settings.RegisterCanvasLayoutCategory, ns.optionsPanel, "OpenMargin")
		if ok and category then
			local categoryOk = pcall(_G.Settings.RegisterAddOnCategory, category)
			if categoryOk then
				ns.optionsCategory = category
				ns.optionsRegistered = true
				return
			end
		end
	end

	if _G.InterfaceOptions_AddCategory then
		local ok = pcall(_G.InterfaceOptions_AddCategory, ns.optionsPanel)
		if ok then
			ns.optionsRegistered = true
		end
	end
end

function ns.RefreshOptions()
	local panel = ns.optionsPanel
	if not panel or not ns.db then return end

	panel.status:SetText(table.concat(ns.GetStatusLines(), "\n"))
	panel.tagButton:SetText("Recipe tag: " .. (ns.db.settings.tag == "profit" and "Profit" or ns.db.settings.tag == "margin" and "Margin" or "Profit + margin"))
	panel.netButton:SetText("Profit type: " .. (ns.db.settings.net == "vendor" and "Vendor net" or "Auction House"))

	if panel.sortCheck then panel.sortCheck:SetChecked(ns.db.settings.sort == true) end
	if panel.panelCheck then panel.panelCheck:SetChecked(ns.db.settings.panel == true) end
	if panel.craftCheck then panel.craftCheck:SetChecked(ns.db.settings.craftReagents == true) end
	if panel.trainerCheck then panel.trainerCheck:SetChecked(ns.db.settings.trainer == true) end
	if panel.tooltipCheck then panel.tooltipCheck:SetChecked(ns.db.settings.tooltips == true) end

	if panel.cutBox and not panel.cutBox:HasFocus() then
		panel.cutBox:SetText(tostring(ns.db.settings.ahCut or 5))
	end
end

function ns.OpenOptions()
	if _G.Settings and ns.optionsCategory and type(_G.Settings.OpenToCategory) == "function" then
		local id = ns.optionsCategory.GetID and ns.optionsCategory:GetID() or "OpenMargin"
		local ok = pcall(_G.Settings.OpenToCategory, id)
		if ok then return end
		ok = pcall(_G.Settings.OpenToCategory, "OpenMargin")
		if ok then return end
	end
	if _G.InterfaceOptionsFrame_OpenToCategory and ns.optionsPanel then
		_G.InterfaceOptionsFrame_OpenToCategory(ns.optionsPanel)
	end
end
