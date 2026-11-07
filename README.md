# OpenMargin

OpenMargin shows the cost and profit of every profession recipe inside the
default WoW Forever profession window.

This is an original, two-team clean-room implementation. A separate read-only
reference agent analysed the reference addon and produced behavioural notes;
the implementation agent did not read the original source. No code, assets, or
internal strings were copied from the reference addon.

## Requirements

- World of Warcraft: Forever, interface `16001`
- **Auctionator** installed and enabled

OpenMargin does not scan the Auction House itself. It reads the last price
Auctionator has stored. Run Auctionator's own scan to refresh prices; an open
profession window updates automatically when the scan finishes.

## What it does

- Profit, margin, or both on every recipe row.
- Sort by profit inside each profession category, from the profession Filter
  menu or `/om sort`.
- Line totals and unit prices under each reagent.
- Breakdown panel with craft cost, sale price, vendor net, and net profit after
  the Auction House cut. Hover it for a per-reagent breakdown.
- **Vendor net (vendor mats)** uses the scan-free flip definition: vendor sell
  value of the output minus the vendor purchase cost of **vendor-bought
  reagents only**. Gathered or crafted reagents count as free, so this can be
  positive even when the full craft cost is higher than the vendor price.
- **Vendor after full cost** subtracts the full craft cost instead and is the
  number to compare with the vendor sell price. `/om vendor scanfree|full`
  selects which one the panel row and recipe tags use.
- **Vendor-bought reagent costs use real vendor buy prices**, cached per
  character whenever a vendor is open. Blizzard only exposes the price a vendor
  pays you, not the price a vendor charges; visit a vendor once to populate the
  cache. Before that, a vendor-sold reagent is priced from the Auction House or
  shown as partial.
- Craftable reagents are priced at their own craft cost when that is cheaper
  than buying them, including cross-profession chains.
- Profit tags at profession trainers, plus material cost, Auction House sale and
  vendor sale on each trainer row, and how many crafts repay the training cost.
- Auctionator price and age on item tooltips.
- **Buy Orders tab in the Auction House.** Set a commodity, a maximum unit
  price and a budget, then click once to search and again to buy. The budget is
  remaining spend and can be reset per order.
- **Vendor Flip tab in the Auction House.** Scan for auctions that vendor for
  more than their buyout, ranked by percent margin, with a per-scan spending
  cap. Commodities are bought through the secure Auction House Buy button;
  non-commodity deals open in the native Buy tab for the final Buyout click.
- Account-wide recipe data and settings. Learned recipes are tracked per
  character.

## Trainer rows

Each trainer recipe carries a compact line beside its profit tag:

- **Mat** — material cost for one craft at current prices. A leading `~` means
  at least one reagent has no price yet, so the total is a lower bound.
- **AH** — what the crafted output sells for on the Auction House before the
  cut.
- **Vendor** — what a vendor pays for the output.

Hover the recipe for the full breakdown, including sale, net profit and the
training payback. Values are per craft; recipes that produce several items use
the average output quantity. Trainer rows are priced for recipes you have not
learned yet as well; if a row is still blank, open that profession's window
once so its full recipe list is captured.

## Buy orders

Open the Auction House and select the **Buy Orders** tab (or run `/om buy`).

1. **New order**, then shift-click an item from your bags or chat to put its
   name in the Item box.
2. Set **Max each** (for example `13c`) and **Budget** (for example `10s`).
   Accepted input includes `13c`, `10s`, `1g 5s`; bare numbers are copper.
3. Click the row button. It changes from **Search** to **Searching...** and
   then to **Buy N** when results are in.
4. Click the same button again to buy. Clicks made while searching or buying
   are ignored, so it is safe to spam the same spot.

The purchase is quantity-based and always takes the cheapest units first. Only
units at or below **Max each** are included, and the confirmed unit price and
total are checked again; if the market moved above your limit, the purchase is
cancelled and the row goes back to Search. **Remaining** is the budget minus
what this order has spent; **Reset** gives it a fresh budget.

Purchases go to your mailbox, as with a normal Auction House purchase.

## Vendor Flip

The **Vendor Flip** tab (or `/om vendor`) scans the Auction House for auctions
whose buyout is below what a vendor pays for the item.

1. Set a **Spend cap** (blank = no cap). The cap resets on every new scan.
2. Click **Scan**. OpenMargin reads the Auction House summary, then searches
   each item that could possibly vendor for a profit.
3. Deals are ranked by **percent profit margin**. You do not have to wait for
   the scan to finish: as soon as a deal is found the button is live and buys
   the best deal found so far. The scan pauses while a purchase or native
   Buyout is in progress and resumes after. For a commodity it buys all
   affordable units below vendor price in one purchase. For a non-commodity
   auction it opens the item in the native Buy tab; click the listing and
   **Buyout** there (Blizzard requires that final click).
4. As you spend, deals beyond the remaining cap or money are skipped. Clicking
   the same button continues down the list.

The scan is a snapshot, not a live feed. Commodity purchases use the same
secure Auction House Buy button as Buy Orders; the purchase quote is checked
against the vendor value before confirming. Items with no cached vendor sell
price are skipped until their item data loads.

## Buy order diagnostics

If a buy order misbehaves, turn on capture and reproduce it:

1. `/om buydebug` (or tick **Capture auction responses and buy actions** in the
   Log window).
2. Reproduce the problem.
3. `/om buylog` opens the log. Click **Copy**, then press Ctrl+C.
4. The last 400 lines are also saved in `OpenMarginDB.buyDebugLog` inside
   `WTF/.../SavedVariables/OpenMargin.lua`.

The log records search events, returned price tiers, plans, purchase quotes,
buy actions, the raw text of the item/max/budget fields, and any action-blocked
event with its stack trace.

The purchase uses the Auction House's own buy dialog and normally confirms it
automatically. If the client blocks the automatic confirmation, the dialog
stays open with **Buy Now**; clicking that button performs the confirmation.

## Why "OpenMargin"?

It is a play on profit margin and open source: the addon is open, and it exposes
the margin on every craft. "Open" also reflects that the project is developed in
the open on GitHub.

## Limitations

- No built-in Auction House scan and no TSM support in this build.
- **Buy orders support commodities only** (cloth, ore, herbs, enchanting
  materials, and similar trade goods). Non-commodity items have to be bought one
  auction at a time and need a click per auction.
- Buy orders do not run in the background: the first click searches and the
  second confirms, and nothing is bought without a click.
- **Vendor Flip uses a snapshot.** It scans the summary and searches candidate
  items once; prices can move before you buy. Items with no cached vendor sell
  price are skipped. Non-commodity deals require the native Buyout click.
- **Estimated sales per day is not available.** Auctionator's public API
  exposes prices, not auction quantity or sale history. The panel shows `—`
  for that row rather than inventing a number.
- Price age is shown only when Auctionator exposes its age API.
- Margin uses net profit ÷ expected sale price. The hover tooltip also shows the
  cost-basis margin.
- Most Enchanting recipes have no sellable item output, so they show cost only
  and no profit tag.

## Install with WowUp

1. Open WowUp and go to **Get Addons → Install from URL**.
2. Paste this repository URL:

   ```
   https://github.com/iamangus/addon-openmargin
   ```

3. Click **Import**, then **Install**.
4. Make sure Auctionator is installed and run its own Auction House scan.

WowUp reads the packaged zip from the latest tagged GitHub release, so future
releases update automatically.

## Manual install

Download the latest `OpenMargin-*.zip` from
[Releases](https://github.com/iamangus/addon-openmargin/releases), then extract
the `OpenMargin` folder into:

```
World of Warcraft/_forever_/Interface/AddOns/
```

Make sure Auctionator is installed. Log in and open a profession once so its
recipes are captured.

## Commands

`/om` or the long alias `/openmargin`:

| Command | Action |
| --- | --- |
| `/om status` | Show source, recipe counts and settings |
| `/om options` | Open the settings panel |
| `/om buy` | Open the Buy Orders tab in the Auction House |
| `/om vendor` | Open the Vendor Flip tab in the Auction House |
| `/om sort` | Toggle sort by profit |
| `/om tag profit\|margin\|both` | Choose the recipe tag |
| `/om net ah\|vendor` | Choose Auction House or vendor net |
| `/om trainer` | Toggle trainer profit tags |
| `/om craft` | Toggle craft-cost reagent pricing |
| `/om panel` | Toggle the breakdown panel |
| `/om tooltips` | Toggle item tooltip prices |
| `/om cut <percent>` | Set the Auction House cut (default 5) |
| `/om margin sale\|cost` | Margin basis (default: sale price) |
| `/om vendor scanfree\|full` | Vendor net basis (default: scan-free flip) |
| `/om refresh` | Clear the price cache and redraw |
| `/om recapture` | Rebuild the open profession's recipe data |
| `/om selftest` | Run the built-in calculation checks |
| `/om reset confirm` | Wipe all OpenMargin data |

## Development

The addon files live at the repository root. The release workflow packages them
into a zip whose root contains a single `OpenMargin/` folder, which is the layout
WowUp expects.

Build the zip locally:

```sh
./scripts/package.sh
```

## Releases

Pushing a version tag builds the zip and creates the GitHub release:

```sh
git tag v0.1.0
git push origin main --tags
```

The workflow uploads `OpenMargin-<version>.zip` as a release asset. WowUp uses
that asset for installation and automatic updates.

## Offline verification

The Lua files pass `luac5.1 -p`, and the costing engine has a self-test covering
recursive reagent chains, cycles, vendor net, margins and formatting. The full
addon also loads against a mocked WoW API for offline smoke testing.

The live client is not available before launch, so layout and a few
client-specific API paths still need an in-game pass.
