# LazySplit

LazySplit is a native iPhone transaction inbox for reviewing Plaid card charges, assigning shared expenses, and publishing approved splits to Splitwise.

## Repository

- `ios/` — SwiftUI iOS 17 app using SwiftData, Google Sign-In, Sign in with Apple, Plaid Link, review gestures, account coverage, local friend aliases and groups, and an export outbox.
- `server/` — Fastify/TypeScript API with PostgreSQL migrations, Plaid transaction sync, Splitwise publishing, encrypted provider tokens, and digest-device registration.

## Run the iPhone app

1. Open `ios/LazySplit.xcodeproj` in Xcode 16 or newer.
2. Set `API_BASE_URL`, the bundle identifier, signing team, and Associated Domains values in the app target configuration for your environment. `Configuration.example.xcconfig` lists the expected values.
3. Select an iPhone simulator and run the `LazySplit` scheme.

### Installing a Debug build on a personal iPhone

Debug uses `LazySplitDebug.entitlements`, which deliberately omits Associated Domains and Sign in with Apple so Xcode can create a normal personal-development provisioning profile.

1. In the LazySplit target's **Signing & Capabilities** tab, enable **Automatically manage signing** and select your Personal Team or Apple Developer team.
2. Keep the Run action on the **Debug** build configuration.
3. Use a unique bundle identifier if `com.aayushrawal.LazySplit` is not registered to your team.
4. Build to the connected phone and choose **Continue on this device**.

Release uses `LazySplit.entitlements`. Register `com.aayushrawal.LazySplit` in a paid Apple Developer team, enable Associated Domains and Sign in with Apple on that App ID, point `lazysplit.aayushrawal.com` at the API, and let Xcode regenerate the provisioning profiles. The API serves the Apple App Site Association document at `/.well-known/apple-app-site-association`. Apple Personal Team profiles do not support Associated Domains, so `LazySplitDebug.entitlements` remains capability-free for local installation; Plaid institutions that require app-to-app OAuth need a paid-team Release/TestFlight build for the supported universal-link return flow.

Debug builds can use a real backend session without Sign in with Apple. Run `pnpm development-code:set` in `server/`, then `docker compose up -d --force-recreate api worker`; the generated development access code is copied to the Mac clipboard. Paste it into the app's **Development access code** field and tap **Connect to LazySplit**. The endpoint exists only while `NODE_ENV=development` and a code is configured. Use `pnpm secrets:rotate` only for an intentional full rotation because it invalidates sessions and previously encrypted provider tokens.

To work with free Apple provisioning, Debug opens Plaid Hosted Link in `ASWebAuthenticationSession` and completes through `lazysplit://plaid-hosted-complete`; the public token is retrieved and exchanged only by the backend. Release continues to use native LinkKit and the `applinks:lazysplit.aayushrawal.com` Universal Link. Banks that force a true bank-app-to-app handoff may still require the paid-team Associated Domains entitlement, but browser-based OAuth and standard Hosted Link flows work without it.

Without a configured API, the app can still launch in a clearly labelled demo mode; live connection controls are disabled there. Live Plaid linking uses a backend-generated Link token and Plaid LinkKit 7. Real financial institutions require `PLAID_ENV=production`, an approved Plaid Production/Trial account, and its Production secret.

## Run the API

### PDF and CSV statements

In **Cards & Accounts → Import an older statement**, choose a CSV or PDF. Both monthly and yearly PDFs are supported. Monthly filenames such as `Apple Card - August 2026.pdf`, `Statement_2026-08.pdf`, or `08-2026.pdf` prefill the statement month; annual/yearly filenames prefill the year. A month name without a year uses the file's modification year and is clearly flagged for confirmation. PDFKit extracts digital text and Apple's on-device Vision text recognition handles pages without recognizable text rows. No raw PDF or page images leave the phone or are retained by LazySplit. Confirm the inferred statement type, period, card, and currency; expand extracted rows to correct dates/descriptions/amounts, mark payments/refunds, or exclude rows. Explicit review confirmation is required before import. Imported charges enter the review inbox and are never published automatically.

PDF support is conservative: numeric `MM/DD`, `MM/DD/YYYY`, `MM/DD/YY`, ISO dates, and month-name dates such as `Jan 2` or `December 31, 2025`, followed by a description and one two-decimal amount on a line. Two leading transaction/posting dates are supported (the first date is used). Missing years use the user-confirmed monthly or yearly period. Running-balance tables, wrapped transaction layouts, and other unsupported formats may require CSV. Unparsed dated lines/pages are reported, but this is not a guarantee of complete statement extraction—always compare with the original. Password-protected PDFs must be unlocked externally. Limits: 25 MB, 50 pages, and currencies with two decimal minor units (USD/CAD/EUR/GBP/AUD/INR/SGD/CHF).

Apple Card PDFs receive section-aware handling: **Transactions** rows use the final amount rather than the preceding Daily Cash value. **Payments**/ACH deposits and the entire **Apple Card Monthly Installments (ACMI)** section are excluded from purchase imports and reported as excluded rows in the preview. Users must still compare the preview with the original statement before approval. Apple also provides CSV transaction export from Wallet as a fallback for future or unsupported PDF layout changes.

Chase statements use the `Opening/Closing Date` printed inside the PDF as the confirmed-period suggestion, ahead of a filename or file-date fallback. Dated filenames such as `20250815-statements.pdf` are also recognized. American Express statements receive coordinate-aware extraction because their PDFs may store dates, descriptions, and amounts in separate text columns even though they appear as visual rows. Amex posting-date asterisks and Pay Over Time footnote markers are accepted. Its `Payments and Credits`, `New Charges`, fees, and interest sections are tracked independently so payments and adjustments cannot replace the actual purchase rows. Issuer-specific suggestions remain visible and require review before import.

Reviewed PDF rows are normalized in memory through the existing CSV statement import contract and duplicate detection (stored as statement/`csv` records), so no backend migration is needed. The statement file is not stored; only the filename and normalized transaction records are retained. Statement-to-Plaid overlap matching still depends on existing fingerprints and is not guaranteed across issuer naming differences.

Statement import supports **Upload one statement** and **Bulk upload statements** (up to 20 files, 50 MB, and 1,000 reviewed transactions per batch). Every file is staged first: choose its account, inspect all extracted rows, correct or exclude transactions, then explicitly mark the file reviewed. Only a final batch confirmation writes data. A failed or ambiguous request retains the same idempotency key for safe retry. The server validates account ownership and currency and writes the batch transactionally.

Cards without Plaid support, including Apple Card, can use **Cards & Accounts → Add account manually**. Manual accounts store only a name, optional last four digits, and currency—never a full card number—and accept PDF/CSV statement history through the same preview flow. **Upload statement to this account** preselects that card. Plaid overlap reconciliation is account-scoped so a statement cannot be merged into a different card merely because its date, amount, and merchant match.

### Split modes

Splits support **Equal**, **Amount**, and **Parts**. The current user is always included: Amount entries are what friends owe and the user pays the remainder. Parts defaults everyone to one part and allows 1–99 parts per person. Exact cents are allocated deterministically without losing or inventing money; for a $100 purchase with the user at 1 part and a friend at 2 parts, the friend owes $66.67 and the user pays $33.33. Parts are converted into exact owed shares before publishing to Splitwise.

### Choose your friends

The Friends tab starts empty, even after connecting Splitwise. Use **Add friends from Splitwise** to search and select people, then tap **Add**. Only explicitly added friends appear in LazySplit and the split editor; refreshing never adds anyone automatically. Swipe a friend to remove them from your LazySplit list without deleting their Splitwise friendship, nickname, existing groups, or past expenses. Groups with members outside your list cannot be used for a new split until those members are added again. The selection is saved per signed-in user on the backend; demo selections are separate and reset when leaving demo mode.

The migration adds `friend_preferences.selected` with a default of `false`, so existing aliases or custom order do not opt anyone in. Deploy the API/migration before installing the updated app. `GET /v1/friends` returns selected friends, `GET /v1/friends?available=true` provides the picker directory (`refresh=true` refreshes Splitwise), `POST /v1/friends` adds selected `friendIDs`, and `DELETE /v1/friends/:id` removes a selection.

### Inbox review and filters

**New** appears below the filter controls and above the grouped history. It contains newly received posted charges that still need review, including historical purchases imported now. **Mark seen** moves the matching new charges into history without changing review status or approving a split. Reviewing a new charge also moves it into history; rows are never duplicated between sections. Arrival/seen tracking is saved on this device, existing caches remain in history after upgrading, and refreshes do not mark previously seen records new again. Pending transactions enter New once posted. Search and filters apply to both sections; New is ordered by arrival batch, then purchase date.

Inbox shows charges only: credits, refunds, and nonpositive amounts are excluded without deleting stored records. Personal charges remain visible by default. Mark a charge **Personal** using its swipe action, detail screen, or bulk selection to exclude it from splitting. Turn on **Filters → Hide personal transactions** only when you want to hide those entries; reset filters restores all charges. Single and bulk review actions support Undo, and offline review changes retry when refreshed.

Choose **View → Group by → Month / Year / Card / account** to organize history; the choice is remembered on this device. Tap a group header to collapse or expand it, or use **View → Collapse all groups / Expand all groups**. Headers summarize matching charges and remaining review count; posted-charge totals exclude pending items and remain separate by currency. Date groups follow newest/oldest ordering; account groups sort by name and retain stable account identity through renames. Search, filter, and grouping changes expand history groups and clear selection to prevent accidental bulk edits. Collapsing a group clears its selected transactions.

Charge and review counts use small legend-style pills matching **Cards & accounts**. Both legends stay pinned below the Inbox title while scrolling; swipe horizontally for additional items. Counts reflect active filters across New and history. Group headers and rows keep compact spacing while allowing larger accessibility text to grow. Turn on **View → Color by card / account** to tint transaction icons. The toggle and color assignments are remembered on this device; filtering or renaming a synced account does not change its color. Card names and last four digits remain visible with or without color. The ten-color palette repeats for larger account collections.

Filter by amount range, currency, date range, card/account, merchant, category, bank-provided location, payment channel, status, source, or possible duplicates. Amount sorting applies within each history group and keeps currencies separate without conversion. Categories prefer Plaid data and label merchant-name fallbacks as suggestions in details. The compact rows show merchant, amount, card, date, review status, and city when supplied; full category/location metadata remains in transaction details. The app does not infer your location or use GPS.

The app refreshes its transaction cache after connecting a card, when returning to the foreground, and when pulling to refresh Inbox or Accounts. It follows all transaction pages, including histories larger than 500 entries, and preserves local review decisions during refresh. Accounts → **Rename card** sets a private LazySplit nickname when the bank supplies a generic/rewards-program name instead of the card product.

```sh
cd server
cp .env.example .env
docker compose up --build -d
curl http://localhost:3000/health
curl https://lazysplit.aayushrawal.com/health
```

This starts PostgreSQL, the compiled Fastify API, a one-minute digest worker, and the persistent Cloudflare Tunnel. The API waits for PostgreSQL, applies the schema migration, and then listens on port 3000. For development without Docker, run `pnpm install`, `pnpm db:migrate`, and `pnpm dev` instead.

If Cloudflare was initially configured with a standalone connector, run `pnpm tunnel:adopt` once. It securely copies the connector token into the ignored `.env` file so Compose can manage all three services. Never commit `server/.env`.

## Integration configuration

Copy `server/.env.example` to `server/.env` and fill in:

- **Plaid:** Client ID, environment-specific secret, and environment. In the Plaid dashboard register `https://lazysplit.aayushrawal.com/plaid/callback` as the redirect URI and `https://lazysplit.aayushrawal.com/v1/plaid/webhook` as the webhook. The endpoint verifies Plaid's signed JWT before processing Transactions updates and Hosted Link completion events.
- **Google:** Create one iOS OAuth client for `com.aayushrawal.LazySplit` and one Web OAuth client in the same Google Auth Platform project. Set the Web client ID as `GOOGLE_CLIENT_ID` on the server, and set the iOS client ID, Web client ID, and reversed iOS client ID in the app build settings described by `Configuration.example.xcconfig`.
- **Splitwise:** OAuth consumer key and secret, with the exact callback `https://lazysplit.aayushrawal.com/v1/splitwise/callback`.
- **Apple:** Services/App identifier and Team ID. Production Sign in with Apple, Associated Domains, and APNs require an active Apple Developer Program membership.
- **APNs:** Team ID, key ID, `.p8` private key contents, and the app bundle identifier as the topic.
- **Cloudflare:** Tunnel token for the public hostname `lazysplit.aayushrawal.com`, routed to `http://api:3000` inside Compose.

After editing configuration, apply it with `docker compose up --build -d`. Confirm `docker compose ps`, both health URLs above, and `docker compose logs --tail=100 api cloudflared`.

## Small VPS sizing

For a personal or invite-only beta, start with **1 shared vCPU, 2 GB RAM, and 20 GB SSD**. The API and tunnel use little storage; PostgreSQL transaction history and Docker logs are the main growth areas. A 1 GB machine may work with swap but leaves little headroom for builds and PostgreSQL. Use 4 GB RAM if building images on the VPS or serving several active testers, and back up the Docker volume before upgrades.

## Safety defaults

- Provider access tokens remain encrypted on the server.
- Plaid and Splitwise can be disconnected independently; account deletion removes all local user data and attempts to revoke every Plaid item first.
- Pending transactions cannot be published.
- Every Splitwise export carries a `LazySplit:<UUID>` marker and is checked before retrying.
- No expense is published without explicit approval.
