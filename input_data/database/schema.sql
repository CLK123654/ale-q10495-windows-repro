\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS notify CASCADE;
CREATE SCHEMA notify;

CREATE TABLE notify.notification_events (
  event_id bigint NOT NULL,
  tenant_id text NOT NULL,
  user_id text NOT NULL,
  channel text NOT NULL,
  delivery_state text NOT NULL CHECK (delivery_state IN ('queued','sent','failed','suppressed')),
  sent_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  PRIMARY KEY (event_id,sent_at)
) PARTITION BY RANGE (sent_at);

CREATE TABLE notify.notification_partition_inventory (
  partition_name text PRIMARY KEY,
  month_start date NOT NULL,
  month_end date NOT NULL,
  reported_rows bigint NOT NULL CHECK (reported_rows>=0),
  reported_failed_rows bigint NOT NULL CHECK (reported_failed_rows>=0),
  old_index_name text NOT NULL DEFAULT ''
);

CREATE TABLE notify.notification_tenant_monthly_capacity (
  tenant_id text NOT NULL,
  month_start date NOT NULL,
  reported_rows bigint NOT NULL CHECK (reported_rows>=0),
  reported_failed_rows bigint NOT NULL CHECK (reported_failed_rows>=0),
  PRIMARY KEY (tenant_id,month_start)
);

CREATE TABLE notify.retention_policy_runtime (
  policy_version text PRIMARY KEY,
  run_date date NOT NULL,
  detach_before date NOT NULL,
  retain_to_exclusive date NOT NULL,
  archive_bucket_prefix text NOT NULL,
  change_window_starts_at timestamptz NOT NULL,
  change_window_ends_at timestamptz NOT NULL,
  write_handling text NOT NULL,
  lock_timeout_ms integer NOT NULL CHECK (lock_timeout_ms>0),
  statement_timeout_ms integer NOT NULL CHECK (statement_timeout_ms>0),
  index_columns text[] NOT NULL,
  index_states text[] NOT NULL
);

CREATE TABLE notify.notification_load_receipt (
  source_name text PRIMARY KEY,
  loaded_rows bigint NOT NULL CHECK (loaded_rows>=0)
);
