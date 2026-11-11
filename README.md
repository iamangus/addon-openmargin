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
- For **Disenchant Flip**, either Auctionator's disenchant price API or the
  **Disenchant Value** addon (its `DisenchantValueAPI`)

Crafting prices come from Auctionator's last stored scan. Run Auctionator's own
scan to refresh them; an open profession window updates automatically when the
scan finishes. The **Buy Orders**, **Vendor Flip**, and **Disenchant Flip** tabs
query the Auction House themselves when you click Scan.

## What it does

- Profit, margin, or both on every recipe row.
- Sort by profit inside each profession category, from the profession Filter
  menu or `/om sort`.
- Line totals and unit prices under each reagent.
- Breakdown panel with craft cost, both sell prices, and profit. Hover it for a
  per-reagent breakdown. The tooltip splits the craft cost into its **Auction
  House** and **vendor** halves, then shows AH sell and vendor sell each with
  money and percent profit against the full craft cost. The **Tag %** checkbox
  switches recipe-row tags between money and percent.
- Vendor profit uses the full craft cost by default. `/om vendor scanfree`
  switches the panel row and recipe tags to the scan-free flip definition
  (vendor sell minus vendor-bought reagents only); `/om vendor full` restores
  full cost.
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
- Recipe items anywhere — Auction House, vendors, bags, chat — show the
  **cost of buying every reagent on the Auction House**, plus the crafted
  item's **vendor sell** and **Auctionator price** (and AH profit) on hover.
  This works from the item itself and does not require opening the profession.
  If the client refuses to expose the recipe schematic, the reagent links in
  the item tooltip are used instead.
- **Buy Orders tab in the Auction House.** Set a commodity, a maximum unit
  price, a budget and a quantity per purchase, then click **Buy**. It starts a
  blind commodity purchase, checks the live quote against your limits, and
  confirms only if the price is acceptable. The budget is remaining spend and
  can be reset per order.
- **Vendor Flip tab in the Auction House.** Scan for auctions that vendor for
  more than their buyout, ranked by percent margin, with a per-scan spending
  cap. Commodities are bought through the Auction House purchase API;
  non-commodity deals open in the native Buy tab for the final Buyout click.
- **Disenchant Flip tab in the Auction House.** Scan armor and weapons whose
  buyout is below the value of the enchanting materials they disenchant into.
  The best deal opens in the native Buy tab; buy it and disenchant it manually.
- **Sniper tab in the Auction House.** Watch a short list of high-volume cloth,
  herb and ore commodities and alert when a listing is at or below vendor sell
  plus a spread. One click buys the top deal; Blizzard throttles searches.
- **Crafting Paths window.** Ranks every profitable craft the account can see,
  including the intermediate crafts that make it cheaper: buy copper ore, smelt
  it into bars, craft wands. Recipes learned by any character count, and
  recipes you have not learned are shown with their skill gap or unlock cost.
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

1. **New order**, then fill the Item box one of three ways: shift-click an item
   from your bags or chat, paste an item link, or type the item's exact name.
   Typed names are looked up through the Auction House, so open it first and
   the row fills in when the search returns.
2. Set **Max each** (for example `13c`), **Budget** (blank = use your available
   money) and **Qty** (how many units to request per purchase; default 20).
   Accepted money input includes `13c`, `10s`, `1g 5s`; bare numbers are copper.
3. Click **Buy**. There is no search step: OpenMargin asks the Auction House
   for a live quote for that quantity and confirms only if the quoted unit
   price is at or below **Max each** and the total fits the remaining budget
   and your money.
4. Spam **Buy** to keep buying. The button stays armed for the next purchase;
   when a quote is above your limit or stock is unavailable, the purchase is
   cancelled and the row reports why.

This is a **blind buy**: the addon does not search first. That removes a query
round trip, but the quote is for the whole requested quantity, so a large
**Qty** can include higher price tiers. If the quoted average is above **Max
each**, the purchase is cancelled. Use a smaller Qty for tighter price control.

One click is still required per purchase, and the AH holds one commodity
purchase at a time. **Remaining** is the budget minus what this order has spent;
**Reset** gives it a fresh budget.

Set **Buy key** (for example `F8`) to bind a keyboard key to the checked Buy
rows while the Buy Orders tab is open. Check **Key** on one or more rows; the
key cycles through them in list order. After a successful purchase the same
order keeps the key for 4 more attempts, so a restock is chased before moving
on. The line under the key field shows the order the key will use next, plus
how many attempts remain. Use a key you do not type into the fields; the
binding is cleared when the tab closes.

**Remaining** also shows the lowest unit quote that order has received
(`· low 12c`). **Reset** clears it along with the spent budget.

Purchases go to your mailbox, as with a normal Auction House purchase.

## Vendor Flip

The **Vendor Flip** tab (or `/om vendor`) scans the Auction House for
commodities priced at or below what a vendor pays, plus an optional tolerance.

1. Set a **Spend cap** (blank = no cap). The cap resets on every new scan.
   **Max over vendor** lets you include units priced up to that much above the
   vendor price. Leave it blank or `0` to include only units at or below vendor;
   enter `5c` to include units within 5 copper above vendor.
   **Commodities only** is on by default. Uncheck it to include non-commodity
   auctions too.
2. Click **Scan**. OpenMargin reads the Auction House summary, then searches
   each item that could possibly qualify.
3. Deals are ranked by **percent profit margin**. The **Over** column shows how
   far the unit price is above or below the vendor price. You do not have to
   wait for the scan to finish: as soon as a deal is found the button is live.
4. Click the buy button repeatedly to work down the list and buy every eligible
   commodity. Each click buys all affordable units of the current commodity in
   one purchase. The scan pauses while a purchase is in progress and resumes
   after. If you uncheck **Commodities only**, non-commodity auctions open in
   the native Buy tab; click the listing and **Buyout** there.
5. As you spend, deals beyond the remaining cap or money are skipped.

The scan is a snapshot, not a live feed. Commodity purchases use the same
Auction House quote path as Buy Orders; the quote is checked against your
vendor limit before confirming. Items with no cached vendor sell
price are skipped until their item data loads.

## Disenchant Flip

The **Disenchant Flip** tab (or `/om de`) scans the Auction House for armor and
weapons whose **buyout is below the estimated value of their disenchant
materials**.

1. Click **Scan**. OpenMargin reads the Auction House summary and filters it to
   armor and weapons.
2. Each candidate item is valued through Auctionator's disenchant API. If
   Auctionator does not provide a value, OpenMargin falls back to
   `DisenchantValueAPI` from the Disenchant Value addon.
3. Deals are ranked by percent margin. The button opens the best deal in the
   native **Buy** tab; click the listing and **Buyout** there, then disenchant
   the item normally.
4. Items with no disenchant value, no price, or a buyout above their material
   value are skipped.

Blizzard does not expose disenchant loot tables. Addons that show disenchant
results either bundle a table of quality/class/item-level rules or record your
own disenchants. OpenMargin reads a public API when one is available rather than
shipping its own table.

## Sniper

The **Sniper** tab (or `/om snipe`) watches a short list of high-volume
commodities for cheap listings. It is built for near-vendor sniping, not for
full Auction House scans.

- **Max over vendor** sets the buy limit: vendor sell price + this spread.
  Linen Cloth vendors for 13c, so `2c` means buy at 15c or less.
- **Max per buy** caps how much one snipe purchase may spend. Blank means no
  separate cap.
- The default watchlist is cloth, herbs and ore, with skinning/leather excluded.
  Add or remove items in the tab, or use `/om snipe add <item>` and
  `/om snipe remove <item>`.
- **Start** cycles through the watchlist one item at a time.
- **Buy** stays visible but greyed out. When a listing is at or below the limit,
  it lights up, plays a sound, and prints a chat line. Spam **Buy** to work
  through every matching deal; after each purchase the next deal is armed. The
  purchase is re-quoted and cancelled if the price moved.

Blizzard limits searches to roughly 100 per minute and often spaces them out
further. Keep the watchlist to a few items for the fastest cycle; a long list
means each item is checked less often. Each purchase needs a click so you stay
in control of the rate. Other players and snipers are competing for the same
listings, so this is a fast manual alert, not a guaranteed catch.

## Crafting Paths

Open **Crafting Paths** with `/om paths`. It is a standalone window, so the
Auction House does not need to be open to read the ranking.

The window has two tabs:

- **My recipes** — paths for professions a character on the account has. This
  includes recipes you know and recipes you can learn in those professions.
- **All professions** — everything the addon knows, including recipe items
  discovered on the Auction House for professions nobody on the account has.

The survey looks at every recipe the addon has captured for every character and
values each reagent at the cheaper of:

- the Auction House price,
- a vendor,
- **crafting it yourself** through another recipe.

That is how `Copper Ore → Copper Bar → Copper Wand` beats buying bars. Each row
shows the chosen exit (**AH**, **DE** or **Vendor**), cost, profit and margin,
and expanding it shows the full step-by-step chain with the profession and
character needed at each step.

Each row also shows the profession level the recipe needs and where it comes
from: **Trainer**, **Recipe item**, vendor, drop or quest. Trainer levels are
captured when that trainer is open. Recipe-item levels are read from the
recipe item's tooltip. A row that has neither says the level was not captured
yet.

**Availability**

- **Known** — a character on the account has learned the recipe.
- **Recipe / Not learned** — the recipe is not learned, but its requirements
  are met. If a recipe item was found on the Auction House, the row shows its
  price and how many crafts pay it back.
- **Skill gap** — a requirement is not met yet. The row shows the requirement
  and the best character's current profession skill. These are the paths that
  are not available yet but could be soon.
- **No profession** — the recipe item was discovered on the Auction House, but
  no character has that profession.

**Filling the catalog**

- Opening a profession on each character records its professions, learned
  recipes and unlearned recipes. Do this once per character after installing or
  updating. Requirement and skill-gap data refreshes the next time you open
  that profession or its trainer; `/om recapture` forces it for the open
  profession.
- **Scan recipe items** (Auction House open) browses the Recipe item class,
  matches each item to its recipe with `C_Item.GetItemSpell`, and records its
  price. This is how recipes for professions nobody on the account has are
  discovered. It is one browse query, not per-item searches, so it does not
  use Auctionator's search budget.
- Recipe items in your bags are picked up automatically when the window opens.

The list is ranked by profit by default; the button cycles to margin and return
on investment. Vendor paths are real but second class: the money is instant, so
they always appear below AH and disenchant paths. The exit button switches
between **All** and **AH + DE** if you want to hide them.

Auctionator still supplies the prices. It cannot enumerate items or map recipe
items to recipes, so the recipe catalog comes from the addon's own capture and
browse scan.

Hover any recipe item — Auction House, vendor, bags or chat — to see what it
costs to buy all of its reagents on the Auction House, what the crafted item
vendors for, and what it auctions for.

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

- No full Auction House scan and no TSM support in this build. Crafting Paths
  only browses the Recipe item class to find recipe items.
- **Buy orders support commodities only** (cloth, ore, herbs, enchanting
  materials, and similar trade goods). Non-commodity items have to be bought one
  auction at a time and need a click per auction.
- Buy orders do not run in the background: the first click searches and the
  second confirms, and nothing is bought without a click.
- **Vendor Flip uses a snapshot.** It scans the summary and searches candidate
  items once; prices can move before you buy. Items with no cached vendor sell
  price are skipped. Non-commodity deals require the native Buyout click.
- Crafting Paths can only use recipes the addon has captured, plus recipe
  items discovered on the Auction House. A trainer-only recipe in a profession
  no character has, and not listed on the Auction House, cannot be discovered
  without a bundled recipe catalog. Prices are Auctionator's last scan, so a
  stale scan produces stale paths.
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
| `/om de` | Open the Disenchant Flip tab in the Auction House |
| `/om snipe` | Open the Sniper tab in the Auction House |
| `/om paths` | Open the Crafting Paths survey |
| `/om snipe start\|stop` | Start or stop the sniper loop |
| `/om snipe add\|remove <item>` | Edit the snipe watchlist |
| `/om sort` | Toggle sort by profit |
| `/om tag profit\|margin\|both` | Choose the recipe tag |
| `/om net ah\|vendor` | Choose Auction House or vendor net |
| `/om trainer` | Toggle trainer profit tags |
| `/om craft` | Toggle craft-cost reagent pricing |
| `/om panel` | Toggle the breakdown panel |
| `/om tooltips` | Toggle item tooltip prices |
| `/om cut <percent>` | Set the Auction House cut (default 5) |
| `/om margin sale\|cost` | Margin basis (default: sale price) |
| `/om vendor scanfree\|full` | Vendor net basis (default: full craft cost) |
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
recursive reagent chains, cycles, vendor net, margins and formatting. The
crafting-path suite covers account-wide known recipes, ore -> bar -> wand
chains, the smelting fallback, recipe-item discovery, unlock payback, skill
gaps, vendor tiering and path filtering. The full addon also loads against a
mocked WoW API for offline smoke testing.

The live client is not available before launch, so layout and a few
client-specific API paths still need an in-game pass.
