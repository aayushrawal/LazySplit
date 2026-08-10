CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  apple_subject text UNIQUE,
  google_subject text UNIQUE,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE users ALTER COLUMN apple_subject DROP NOT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_subject text UNIQUE;

CREATE TABLE IF NOT EXISTS sessions (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS provider_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('plaid', 'splitwise')),
  provider_item_id text,
  encrypted_token text NOT NULL,
  sync_cursor text,
  status text NOT NULL DEFAULT 'active',
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, provider, provider_item_id)
);

CREATE TABLE IF NOT EXISTS accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  connection_id uuid REFERENCES provider_connections(id) ON DELETE SET NULL,
  external_id text,
  name text NOT NULL,
  mask text,
  currency_code text NOT NULL DEFAULT 'USD',
  UNIQUE(user_id, external_id)
);

CREATE TABLE IF NOT EXISTS transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id uuid REFERENCES accounts(id) ON DELETE SET NULL,
  external_id text,
  source text NOT NULL CHECK (source IN ('plaid', 'csv')),
  merchant text NOT NULL,
  original_description text,
  transaction_date date NOT NULL,
  amount_minor bigint NOT NULL,
  currency_code text NOT NULL,
  pending boolean NOT NULL DEFAULT false,
  review_state text NOT NULL DEFAULT 'needsReview',
  fingerprint text NOT NULL,
  possible_duplicate_id uuid REFERENCES transactions(id),
  raw_category text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, source, external_id)
);

CREATE TABLE IF NOT EXISTS splitwise_cache (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  splitwise_user jsonb NOT NULL DEFAULT '{}',
  friends jsonb NOT NULL DEFAULT '[]',
  groups jsonb NOT NULL DEFAULT '[]',
  categories jsonb NOT NULL DEFAULT '[]',
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS split_drafts (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  transaction_id uuid NOT NULL,
  payload jsonb NOT NULL,
  state text NOT NULL DEFAULT 'queued',
  splitwise_expense_id bigint,
  marker text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL,
  status_code integer,
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS devices (
  token text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  timezone text NOT NULL,
  digest_hour integer NOT NULL DEFAULT 19 CHECK (digest_hour BETWEEN 0 AND 23),
  enabled boolean NOT NULL DEFAULT true,
  last_digest_date date,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS transactions_user_review_idx ON transactions(user_id, review_state, transaction_date DESC);
CREATE INDEX IF NOT EXISTS transactions_user_account_date_idx ON transactions(user_id, account_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS transactions_user_fingerprint_idx ON transactions(user_id, fingerprint);
