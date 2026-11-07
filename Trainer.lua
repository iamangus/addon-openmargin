local addonName, ns = ...

local function safeHookGlobal(name, fn)
	if type(_G[name]) ~= "function" then return false end
	local ok = pcall(hooksecurefunc, name, fn)
	return ok
end

local function ensureTrainerTag(button)
	local tag = button.OpenMarginTag
	if not tag then
		tag = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		tag:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -6, 4)
		tag:SetWidth(84)
		tag:SetJustifyH("RIGHT")
		tag:SetWordWrap(false)
		button.OpenMarginTag = tag
	end
	return tag
end

function ns.OnTrainerServiceButton(button, elementData)
	if not button or not ns.db then return end

	local tag = button.OpenMarginTag
	if not ns.db.settings.trainer or not _G.IsTradeskillTrainer or not _G.IsTradeskillTrainer() then
		if tag then tag:Hide() end
		button.OpenMarginRecipeID = nil
		return
	end

	elementData = elementData and (elementData.data or elementData)
	local skillIndex = elementData and elementData.skillIndex
	if not skillIndex then
		if tag then tag:Hide() end
		return
	end

	local serviceName = _G.GetTrainerServiceInfo and _G.GetTrainerServiceInfo(skillIndex)
	local professionName = _G.GetTrainerServiceSkillLine and _G.GetTrainerServiceSkillLine(skillIndex)
	if not serviceName or not professionName then
		if tag then tag:Hide() end
		return
	end

	if not button.OpenMarginTooltipHooked then
		button.OpenMarginTooltipHooked = true
		button:HookScript("OnEnter", function(self)
			ns.ShowTrainerTooltip(self)
		end)
	end

	local recipeID = ns.FindTrainerRecipe(professionName, serviceName)
	if not recipeID then
		if tag then tag:Hide() end
		button.OpenMarginRecipeID = nil
		return
	end

	ns.EnsureRecipe(recipeID)
	local econ = ns.GetCachedEconomics(recipeID)
	if not econ then
		if tag then tag:Hide() end
		return
	end

	tag = ensureTrainerTag(button)
	local text, r, g, b = ns.GetTag(econ)
	tag:SetText(text)
	tag:SetTextColor(r, g, b)
	tag:Show()

	local moneyCost = _G.GetTrainerServiceCost and _G.GetTrainerServiceCost(skillIndex)
	local payback
	if moneyCost and moneyCost > 0 and econ.net and econ.net > 0 then
		payback = math.ceil(moneyCost / econ.net)
	end

	button.OpenMarginRecipeID = recipeID
	button.OpenMarginTrainingCost = moneyCost
	button.OpenMarginPayback = payback
end

function ns.TryTrainerSpellID(button)
	local tooltip = _G.GameTooltip
	if not tooltip or type(tooltip.GetSpell) ~= "function" then return end

	local results = { pcall(tooltip.GetSpell, tooltip) }
	if not results[1] then return end

	for index = 2, #results do
		local value = results[index]
		if type(value) == "number" and ns.db.recipes[value] then
			if button.OpenMarginRecipeID ~= value then
				button.OpenMarginRecipeID = value
				local econ = ns.GetCachedEconomics(value)
				if econ then
					local tag = ensureTrainerTag(button)
					local text, r, g, b = ns.GetTag(econ)
					tag:SetText(text)
					tag:SetTextColor(r, g, b)
					tag:Show()
				end
			end
			return
		end
	end
end

function ns.ShowTrainerTooltip(button)
	if not button then return end
	local tooltip = _G.GameTooltip
	if not tooltip or not tooltip:IsShown() then return end

	ns.TryTrainerSpellID(button)

	if not button.OpenMarginRecipeID then return end
	local econ = ns.GetCachedEconomics(button.OpenMarginRecipeID)
	if not econ then return end

	tooltip:AddLine(" ")
	tooltip:AddLine("OpenMargin", 0.2, 1, 0.6)
	tooltip:AddDoubleLine("Craft cost", econ.costComplete and ns.FormatMoneyFull(econ.cost) or "partial", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("AH net", econ.net and ns.FormatMoney(econ.net, true) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("Vendor net", econ.vendorNet and ns.FormatMoney(econ.vendorNet, true) or "—", 0.8, 0.8, 0.8, 1, 1, 1)

	if button.OpenMarginTrainingCost then
		tooltip:AddDoubleLine("Training cost", ns.FormatMoneyFull(button.OpenMarginTrainingCost), 0.8, 0.8, 0.8, 1, 1, 1)
	end

	if button.OpenMarginPayback then
		tooltip:AddLine(string.format("Pays back training in %d craft%s.", button.OpenMarginPayback, button.OpenMarginPayback == 1 and "" or "s"), 0.2, 1, 0.6)
	elseif econ.net and econ.net <= 0 then
		tooltip:AddLine("This recipe does not pay back its training cost at current prices.", 1, 0.5, 0.5, true)
	end

	tooltip:Show()
end

function ns.UpdateTrainerSummary()
	local frame = _G.ClassTrainerFrame
	if not frame or not ns.db then return end

	local summary = frame.OpenMarginSummary
	if not summary then
		summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		summary:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 160, 10)
		summary:SetWidth(120)
		summary:SetHeight(30)
		summary:SetJustifyH("LEFT")
		summary:SetJustifyV("MIDDLE")
		frame.OpenMarginSummary = summary
	end

	if not ns.db.settings.trainer or not frame:IsShown() or not _G.IsTradeskillTrainer or not _G.IsTradeskillTrainer() then
		summary:Hide()
		return
	end

	local total, mapped, profitable, paybackCount = 0, 0, 0, 0
	local numServices = _G.GetNumTrainerServices and _G.GetNumTrainerServices() or 0
	for skillIndex = 1, numServices do
		total = total + 1
		local serviceName = _G.GetTrainerServiceInfo and _G.GetTrainerServiceInfo(skillIndex)
		local professionName = _G.GetTrainerServiceSkillLine and _G.GetTrainerServiceSkillLine(skillIndex)
		if serviceName and professionName then
			local recipeID = ns.FindTrainerRecipe(professionName, serviceName)
			if recipeID then
				mapped = mapped + 1
				ns.EnsureRecipe(recipeID)
				local econ = ns.GetCachedEconomics(recipeID)
				local moneyCost = _G.GetTrainerServiceCost and _G.GetTrainerServiceCost(skillIndex)
				if econ and econ.net and econ.net > 0 then
					profitable = profitable + 1
					if moneyCost and moneyCost > 0 and math.ceil(moneyCost / econ.net) <= 20 then
						paybackCount = paybackCount + 1
					end
				end
			end
		end
	end

	if mapped == 0 then
		summary:SetText("OpenMargin: open this profession once to load its recipes.")
		summary:SetTextColor(0.6, 0.6, 0.6)
	else
		summary:SetText(string.format("OpenMargin: %d of %d recipes repay training within 20 crafts.", paybackCount, mapped))
		if paybackCount > 0 then
			summary:SetTextColor(0.25, 1, 0.25)
		else
			summary:SetTextColor(0.8, 0.8, 0.8)
		end
	end
	summary:Show()
end

function ns.RefreshTrainer()
	local frame = _G.ClassTrainerFrame
	if not frame then return end
	if frame:IsShown() and type(_G.ClassTrainerFrame_Update) == "function" then
		pcall(_G.ClassTrainerFrame_Update, true)
	end
	ns.UpdateTrainerSummary()
end

function ns.InstallTrainerHooks()
	if not ns.trainerHooks then ns.trainerHooks = {} end

	if not ns.trainerHooks.service then
		ns.trainerHooks.service = safeHookGlobal("ClassTrainerFrame_InitServiceButton", function(button, elementData)
			local ok, err = pcall(ns.OnTrainerServiceButton, button, elementData)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.trainerHooks.update then
		ns.trainerHooks.update = safeHookGlobal("ClassTrainerFrame_Update", function()
			local ok, err = pcall(ns.UpdateTrainerSummary)
			if not ok then ns.ReportError(err) end
		end)
	end
end
