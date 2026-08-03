# LazySplit

LazySplit is a native iPhone transaction inbox for reviewing credit-card charges, assigning shared expenses, and publishing approved splits to Splitwise.

## Repository

- `ios/` — SwiftUI iOS 17 app using SwiftData, Sign in with Apple, Plaid Link, CSV imports, review gestures, coverage, and an export outbox.
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

Release uses `LazySplit.entitlements`. For live Sign in with Apple and Plaid OAuth redirects, register the bundle ID in the Apple Developer portal, enable both capabilities on that App ID, configure `example.com` to serve the Apple App Site Association file, and let Xcode regenerate the provisioning profile.

Without a configured API, the app launches in demo mode with representative transactions. Live Plaid linking requires a backend-generated link token, an Associated Domains entitlement, and Plaid LinkKit 7.

## Run the API

```sh
cd server
cp .env.example .env
pnpm install
pnpm db:migrate
pnpm dev
```

PostgreSQL, Plaid, Splitwise OAuth, Apple Services, and APNs credentials are required for live integrations. See `server/.env.example` for the complete contract.

## Safety defaults

- Provider access tokens remain encrypted on the server.
- Raw CSV files are parsed on-device and are never uploaded; only normalized transactions are sent.
- Pending transactions cannot be published.
- Every Splitwise export carries a `LazySplit:<UUID>` marker and is checked before retrying.
- No expense is published without explicit approval.
