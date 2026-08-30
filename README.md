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

### Inbox review and filters

Inbox shows charges only: credits, refunds, and nonpositive amounts are excluded without deleting stored records. Personal charges remain visible by default. Mark a charge **Personal** using its swipe action, detail screen, or bulk selection to exclude it from splitting. Turn on **Filters → Hide personal transactions** only when you want to hide those entries; reset filters restores all charges. Single and bulk review actions support Undo, and offline review changes retry when refreshed.

Transactions appear in inset, rounded monthly groups. Tap a month header to collapse or expand it, or use **View → Collapse all months / Expand all months**. Headers summarize the matching charges and remaining review count; posted-charge totals exclude pending items and remain separate by currency. Search and filter changes expand groups so matches are not concealed. Collapsing a month clears its selected transactions to prevent accidental bulk edits.

The compact summary shows charge and review counts in one strip. Month headers and rows use tighter spacing while allowing larger accessibility text to grow. The **Cards & accounts** color legend is always visible below the Inbox title and stays pinned while scrolling; swipe it horizontally for additional accounts. Turn on **View → Color by card / account** to also tint transaction icons. The toggle and color assignments are remembered on this device; filtering or renaming a synced account does not change its color. Card names and last four digits remain visible with or without color. The ten-color palette repeats for larger account collections.

Filter by amount range, currency, date range, card/account, merchant, category, bank-provided location, payment channel, status, source, or possible duplicates. Amount sorting applies within each month and groups currencies separately without converting them. Categories prefer Plaid data and label merchant-name fallbacks as suggestions in details. The compact rows show merchant, amount, card, date, review status, and city when supplied; full category/location metadata remains in transaction details. The app does not infer your location or use GPS.

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
