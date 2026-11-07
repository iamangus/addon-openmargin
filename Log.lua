local addonName, ns = ...

-- Buy Orders diagnostic log. Off by default; /om buydebug turns it on.
-- The last few hundred lines are kept in memory and in
-- OpenMarginDB.buyDebugLog so they survive a /reload.

local MAX_LINES = 400

ns.buyLogLines = ns.buyLogLines or {}
ns.buyLogEnabled = false

local function timestamp()
	if type(_G.date) == "function" then
		local ok, stamp = pcall(_G.date, "%H:%M:%S")
		if ok and stamp then return stamp end
	end
	if type(_G.GetTime) == "function" then
		return string.format("%.3f", _G.GetTime())
	end
	return "?"
end

function ns.LoadBuyLog()
	if ns.buyLogLoaded then return end
	ns.buyLogLoaded = true
	ns.buyLogLines = ns.buyLogLines or {}
	if ns.db and type(ns.db.buyDebugLog) == "table" and #ns.db.buyDebugLog > 0 then
		for index = 1, #ns.db.buyDebugLog do
			ns.buyLogLines[index] = tostring(ns.db.buyDebugLog[index])
		end
		while #ns.buyLogLines > MAX_LINES do table.remove(ns.buyLogLines, 1) end
	end
end

function ns.IsBuyLogEnabled()
	if ns.buyLogEnabled then return true end
	return ns.db and ns.db.settings and ns.db.settings.buyDebug == true or false
end

function ns.SetBuyDebug(enabled)
	ns.buyLogEnabled = enabled == true
	if ns.db and ns.db.settings then
		ns.db.settings.buyDebug = ns.buyLogEnabled
	end
	ns.LoadBuyLog()
	ns.Print("Buy debug logging " .. (ns.buyLogEnabled and "ON." or "OFF."))
	if ns.buyLogEnabled then
		local version = "?"
		if _G.C_AddOns and type(_G.C_AddOns.GetAddOnMetadata) == "function" then
			local ok, value = pcall(_G.C_AddOns.GetAddOnMetadata, addonName, "Version")
			if ok and value then version = value end
		end
		ns.BuyLog("---- capture enabled (OpenMargin %s) ----", version)
	end
	if ns.buyLogCheck then ns.buyLogCheck:SetChecked(ns.buyLogEnabled) end
end

function ns.ToggleBuyDebug()
	ns.SetBuyDebug(not ns.IsBuyLogEnabled())
end

function ns.BuyLog(fmt, ...)
	if not ns.IsBuyLogEnabled() then return end
	ns.LoadBuyLog()

	local line
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		line = ok and formatted or tostring(fmt)
	else
		line = tostring(fmt)
	end
	line = tostring(line):gsub("[\r\n]+", " ")

	local entry = timestamp() .. "  " .. line
	ns.buyLogLines[#ns.buyLogLines + 1] = entry
	while #ns.buyLogLines > MAX_LINES do table.remove(ns.buyLogLines, 1) end

	if ns.db then
		ns.db.buyDebugLog = ns.db.buyDebugLog or {}
		ns.db.buyDebugLog[#ns.db.buyDebugLog + 1] = entry
		while #ns.db.buyDebugLog > MAX_LINES do table.remove(ns.db.buyDebugLog, 1) end
	end

	if ns.buyLogFrame and ns.buyLogFrame:IsShown() and ns.buyLogEdit and not ns.buyLogEdit:HasFocus() then
		ns.RefreshBuyLogFrame()
	end
end

function ns.GetBuyLogText()
	ns.LoadBuyLog()
	if #ns.buyLogLines == 0 then
		return "No log entries yet. Turn capture on, reproduce the issue, then Copy."
	end
	return table.concat(ns.buyLogLines, "\n")
end

function ns.ClearBuyLog()
	ns.buyLogLines = {}
	ns.buyLogLoaded = true
	if ns.db then ns.db.buyDebugLog = {} end
	if ns.buyLogFrame and ns.buyLogFrame:IsShown() then ns.RefreshBuyLogFrame() end
end

function ns.RefreshBuyLogFrame()
	if not ns.buyLogEdit then return end
	local text = ns.GetBuyLogText()
	ns.buyLogEdit:SetText(text)
	local lines = 1
	for _ in text:gmatch("\n") do lines = lines + 1 end
	ns.buyLogEdit:SetHeight(math.max(380, lines * 16 + 20))
	if ns.buyLogScroll then ns.buyLogScroll:UpdateScrollChildRect() end
	if ns.buyLogCheck then ns.buyLogCheck:SetChecked(ns.IsBuyLogEnabled()) end
end

function ns.ShowBuyLog()
	if not ns.buyLogFrame then
		local created, frame = pcall(CreateFrame, "Frame", "OpenMarginBuyLogFrame", _G.UIParent, "BasicFrameTemplateWithInset")
		if not created or not frame then
			frame = CreateFrame("Frame", "OpenMarginBuyLogFrame", _G.UIParent, "BasicFrameTemplate")
		end
		frame:SetSize(760, 520)
		frame:SetPoint("CENTER")
		frame:SetFrameStrata("DIALOG")
		frame:SetMovable(true)
		frame:EnableMouse(true)
		frame:SetClampedToScreen(true)
		frame:RegisterForDrag("LeftButton")
		frame:SetScript("OnDragStart", frame.StartMoving)
		frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
		if frame.TitleText then frame.TitleText:SetText("OpenMargin buy log") end
		ns.buyLogFrame = frame

		local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -34)
		hint:SetWidth(700)
		hint:SetJustifyH("LEFT")
		hint:SetText("Enable capture, reproduce the issue, then click Copy and press Ctrl+C. The log is also saved in OpenMarginDB.buyDebugLog.")

		local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -54)
		scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 64)
		ns.buyLogScroll = scroll

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("ChatFontNormal")
		edit:SetWidth(680)
		edit:SetHeight(380)
		edit:SetTextInsets(4, 4, 4, 4)
		edit:EnableMouse(true)
		edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		edit:SetScript("OnMouseDown", function(self) self:SetFocus() end)
		scroll:SetScrollChild(edit)
		ns.buyLogEdit = edit

		local copy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		copy:SetSize(80, 22)
		copy:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
		copy:SetText("Copy")
		copy:SetScript("OnClick", function()
			edit:SetFocus()
			edit:HighlightText()
			ns.Print("Buy log selected. Press Ctrl+C to copy.")
		end)

		local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		clear:SetSize(80, 22)
		clear:SetPoint("LEFT", copy, "RIGHT", 6, 0)
		clear:SetText("Clear")
		clear:SetScript("OnClick", function()
			ns.ClearBuyLog()
			ns.RefreshBuyLogFrame()
		end)

		local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		refresh:SetSize(80, 22)
		refresh:SetPoint("LEFT", clear, "RIGHT", 6, 0)
		refresh:SetText("Refresh")
		refresh:SetScript("OnClick", function() ns.RefreshBuyLogFrame() end)

		local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		close:SetSize(80, 22)
		close:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 16)
		close:SetText("Close")
		close:SetScript("OnClick", function() frame:Hide() end)

		local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 42)
		check:SetScript("OnClick", function(self) ns.SetBuyDebug(self:GetChecked() == true) end)
		ns.buyLogCheck = check

		local checkLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		checkLabel:SetPoint("LEFT", check, "RIGHT", 2, 0)
		checkLabel:SetText("Capture auction responses and buy actions")

		frame:SetScript("OnShow", function()
			ns.RefreshBuyLogFrame()
		end)
		frame:Hide()
	end

	ns.RefreshBuyLogFrame()
	ns.buyLogFrame:Show()
end
