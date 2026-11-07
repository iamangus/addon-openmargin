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
- Vendor net uses the scan-free definition: vendor sell value of the output
  minus the vendor purchase cost of vendor-bought reagents. Non-vendor reagents
  are treated as free/gathered.
- Craftable reagents are priced at their own craft cost when that is cheaper
  than buying them, including cross-profession chains.
- Profit tags at profession trainers, plus how many crafts repay the training
  cost.
- Auctionator price and age on item tooltips.
- Account-wide recipe data and settings. Learned recipes are tracked per
  character.

## Why "OpenMargin"?

It is a play on profit margin and open source: the addon is open, and it exposes
the margin on every craft. "Open" also reflects that the project is developed in
the open on GitHub.

## Limitations

- No built-in Auction House scan and no TSM support in this build.
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
