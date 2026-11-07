local addonName, ns = ...

local function printLines(lines)
	for index = 1, #lines do
		ns.Print(lines[index])
	end
end

local function printHelp()
	printLines({
		"/om status — price source, scan data and settings",
		"/om options — open the settings panel",
		"/om sort — toggle sort by profit",
		"/om tag profit|margin|both — choose what recipe rows show",
		"/om net ah|vendor — choose Auction House net or vendor net",
		"/om trainer — toggle profit tags at profession trainers",
		"/om craft — toggle pricing reagents at their own craft cost",
		"/om panel — toggle the breakdown panel",
		"/om tooltips — toggle item tooltip prices",
		"/om cut <percent> — set the Auction House cut (default 5)",
		"/om margin sale|cost — margin basis",
		"/om vendor scanfree|full — vendor net basis",
		"/om refresh — clear the price cache and redraw",
		"/om buy — open the Buy Orders tab in the Auction House",
		"/om buydebug — toggle Auction House buy logging",
		"/om buylog — show/copy the buy log",
		"/om recapture — rebuild the open profession's recipe data",
		"/om selftest — run the built-in calculation checks",
		"/om reset confirm — wipe all OpenMargin data",
		"/om source — show the configured price source",
	})
end

local function handleCommand(message)
	message = tostring(message or "")
	local command, rest = message:match("^(%S*)%s*(.-)$")
	command = (command or ""):lower()
	rest = ns.Trim(rest or "")

	if command == "" or command == "help" then
		printHelp()

	elseif command == "status" or command == "diagnose" then
		printLines(ns.GetStatusLines())

	elseif command == "options" then
		if ns.OpenOptions then ns.OpenOptions() end

	elseif command == "sort" then
		ns.ToggleSetting("sort")
		ns.Print("Sort by profit: " .. (ns.db.settings.sort and "on" or "off"))

	elseif command == "tag" then
		local mode = rest:lower()
		if mode == "profit" or mode == "margin" or mode == "both" then
			ns.db.settings.tag = mode
			ns.OnSettingChanged()
			ns.Print("Recipe tag: " .. mode)
		else
			ns.Print("Usage: /om tag profit|margin|both")
		end

	elseif command == "net" then
		local mode = rest:lower()
		if mode == "ah" or mode == "vendor" then
			ns.db.settings.net = mode
			ns.OnSettingChanged()
			ns.Print("Profit type: " .. (mode == "vendor" and "vendor net" or "Auction House net"))
		else
			ns.Print("Usage: /om net ah|vendor")
		end

	elseif command == "trainer" then
		ns.ToggleSetting("trainer")
		ns.Print("Trainer profit tags: " .. (ns.db.settings.trainer and "on" or "off"))

	elseif command == "craft" then
		ns.ToggleSetting("craftReagents")
		ns.Print("Craftable reagent pricing: " .. (ns.db.settings.craftReagents and "on" or "off"))

	elseif command == "panel" then
		ns.ToggleSetting("panel")
		ns.Print("Breakdown panel: " .. (ns.db.settings.panel and "on" or "off"))

	elseif command == "tooltips" then
		ns.ToggleSetting("tooltips")
		ns.Print("Item tooltips: " .. (ns.db.settings.tooltips and "on" or "off"))

	elseif command == "cut" then
		local value = tonumber(rest)
		if value and ns.SetAHcut(value) then
			ns.Print("Auction House cut: " .. tostring(ns.db.settings.ahCut) .. "%")
		else
			ns.Print("Usage: /om cut <0-25>")
		end

	elseif command == "margin" then
		local basis = rest:lower()
		if basis == "sale" or basis == "cost" then
			ns.db.settings.marginBasis = basis
			ns.OnSettingChanged()
			ns.Print("Margin basis: " .. basis)
		else
			ns.Print("Usage: /om margin sale|cost")
		end

	elseif command == "vendor" then
		local basis = rest:lower()
		if basis == "scanfree" or basis == "full" then
			ns.db.settings.vendorBasis = basis
			ns.OnSettingChanged()
			ns.Print("Vendor net basis: " .. basis)
		else
			ns.Print("Usage: /om vendor scanfree|full")
		end

	elseif command == "source" then
		if ns.GetAuctionatorAPI() then
			ns.Print("Price source: Auctionator.")
		else
			ns.Print("Price source: Auctionator is not available. Install and enable Auctionator.")
		end

	elseif command == "scan" then
		ns.Print("This build reads Auctionator prices. Use Auctionator's own scan; OpenMargin does not scan the Auction House itself.")

	elseif command == "refresh" then
		ns.InvalidatePrices()
		ns.RefreshAll()
		ns.Print("Price cache cleared.")

	elseif command == "buy" then
		if ns.OpenBuyOrders then ns.OpenBuyOrders() end

	elseif command == "buydebug" then
		if ns.ToggleBuyDebug then ns.ToggleBuyDebug() end

	elseif command == "buylog" then
		if rest:lower() == "clear" then
			if ns.ClearBuyLog then
				ns.ClearBuyLog()
				ns.Print("Buy log cleared.")
			end
		elseif rest:lower() == "on" then
			if ns.SetBuyDebug then ns.SetBuyDebug(true) end
		elseif rest:lower() == "off" then
			if ns.SetBuyDebug then ns.SetBuyDebug(false) end
		elseif ns.ShowBuyLog then
			ns.ShowBuyLog()
		end

	elseif command == "recapture" then
		if ns.ScheduleCapture then
			ns.ScheduleCapture(true)
			ns.Print("Recipe capture queued for the open profession.")
		end

	elseif command == "selftest" then
		ns.Print(ns.RunSelfTest())

	elseif command == "reset" then
		if rest:lower() == "confirm" then
			ns.ResetAll()
			ns.Print("All OpenMargin data reset.")
		else
			ns.Print("This deletes all settings, recipe data and cached prices. Use /om reset confirm.")
		end

	else
		ns.Print("Unknown command: " .. command)
		printHelp()
	end
end

_G.SLASH_OPENMARGIN1 = "/om"
_G.SLASH_OPENMARGIN2 = "/openmargin"
_G.SlashCmdList["OPENMARGIN"] = handleCommand
