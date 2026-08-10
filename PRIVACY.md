# LazySplit Beta Privacy Notes

LazySplit processes financial transaction metadata only to help the signed-in user review and publish shared expenses.

- Google or Apple provides the user's sign-in identity. LazySplit verifies provider ID tokens and stores the provider subject identifier and verified email address; provider passwords are never received.
- Bank authentication is performed by Plaid Link. LazySplit never receives bank usernames or passwords.
- Plaid and Splitwise access tokens are encrypted on the server and are not placed in the iPhone app.
- Plaid Hosted Link session tokens used by free-development builds are short-lived and encrypted on the server; public and access tokens are never returned to the app.
- CSV statements are parsed on the iPhone. The original file is not retained or uploaded; normalized transaction fields are synchronized to the user's account.
- Friends do not create LazySplit accounts merely because they are included in an expense. Published expenses are governed by Splitwise's privacy terms.
- Optional friend aliases, preferred ordering, and friend groups are stored in LazySplit for the signed-in user. They do not rename friends or create groups in Splitwise.
- Authentication, financial, and provider-token fields are redacted from application logs.
- A user may disconnect integrations or delete their LazySplit account and associated server-side data.

This is an engineering draft for an invite-only beta, not a substitute for legal review. Add the production operator's identity, contact information, retention periods, and jurisdiction-specific disclosures before TestFlight distribution.
