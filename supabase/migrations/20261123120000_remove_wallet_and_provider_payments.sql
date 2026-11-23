-- Payment model change, step 1 (cleanup): customers now pay riders directly, so the
-- in-app wallet, withdrawals and provider payment records are removed.
-- See docs/proposals/payment-model-change.md.
--
-- BEFORE `supabase db push` to the hosted project, run this read-only check in the
-- SQL Editor. Every value must match its comment; if not, stop and ask.
--
--   SELECT
--     (SELECT count(*) FROM public.payments)        AS payments_rows,           -- must be 0
--     (SELECT count(*) FROM public.wallet_entries)  AS wallet_entries_rows,     -- must be 0
--     (SELECT count(*) FROM public.withdrawals)     AS withdrawals_rows,        -- must be 0
--     (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
--       WHERE n.nspname = 'public'
--         AND t.typname IN ('payment_record_status', 'wallet_entry_type', 'withdrawal_status'))
--                                                   AS enums_present,           -- must be 3
--     (SELECT count(*) FROM information_schema.columns
--       WHERE table_schema = 'public'
--         AND udt_name IN ('payment_record_status', 'wallet_entry_type', 'withdrawal_status')
--         AND table_name NOT IN ('payments', 'wallet_entries', 'withdrawals'))
--                                                   AS enum_uses_elsewhere,     -- must be 0
--     (SELECT count(*) FROM pg_constraint
--       WHERE contype = 'f'
--         AND confrelid IN (to_regclass('public.payments'), to_regclass('public.wallet_entries'),
--                           to_regclass('public.withdrawals'))
--         AND conrelid NOT IN (to_regclass('public.payments'), to_regclass('public.wallet_entries'),
--                              to_regclass('public.withdrawals')))
--                                                   AS foreign_keys_into_them,  -- must be 0
--     (SELECT count(*) FROM pg_depend d
--       WHERE d.classid = 'pg_rewrite'::regclass
--         AND d.refobjid IN (to_regclass('public.payments'), to_regclass('public.wallet_entries'),
--                            to_regclass('public.withdrawals')))
--                                                   AS views_using_them,        -- must be 0
--     (SELECT count(*) FROM pg_trigger
--       WHERE tgfoid = to_regprocedure('public.reject_wallet_mutation()')
--         AND tgrelid <> to_regclass('public.wallet_entries'))
--                                                   AS function_used_elsewhere, -- must be 0
--     (SELECT count(*) FROM information_schema.columns
--       WHERE table_schema = 'public' AND table_name = 'app_settings'
--         AND column_name = 'min_withdrawal_kobo')  AS min_withdrawal_present,  -- must be 1
--     (SELECT max(version) FROM supabase_migrations.schema_migrations)
--                                                   AS latest_migration;        -- must be 20261123100000
--
-- Deliberately no CASCADE and no IF EXISTS: an unexpected dependency or a missing
-- object makes the whole migration fail and roll back, instead of silently
-- dropping something else or half-applying.

-- ---------------------------------------------------------------------------
-- Safety net: never drop money records. Refuse if any of the tables has a row.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.payments)
     OR EXISTS (SELECT 1 FROM public.wallet_entries)
     OR EXISTS (SELECT 1 FROM public.withdrawals) THEN
    RAISE EXCEPTION 'payments, wallet_entries or withdrawals is not empty: not dropping them';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tables. Dropping a table also drops its indexes, constraints, triggers and RLS
-- policies:
--   payments:       payments_order_id_idx, payments_provider_ref_unique,
--                   payments_raw_webhook_id_unique,
--                   policy payments_select_participant_or_admin
--   wallet_entries: wallet_entries_rider_id_created_at_idx,
--                   triggers wallet_entries_no_update / wallet_entries_no_delete,
--                   policy wallet_entries_select_own_or_admin
--   withdrawals:    withdrawals_rider_id_idx, withdrawals_provider_ref_unique,
--                   policy withdrawals_select_own_or_admin
-- ---------------------------------------------------------------------------
DROP TABLE public.payments;
DROP TABLE public.wallet_entries;
DROP TABLE public.withdrawals;

-- The wallet's append-only trigger function (the commission ledger gets its own).
DROP FUNCTION public.reject_wallet_mutation();

-- Enums used only by those tables. public.payment_status stays: orders uses it.
DROP TYPE public.payment_record_status;
DROP TYPE public.wallet_entry_type;
DROP TYPE public.withdrawal_status;

-- No withdrawals, so no minimum withdrawal.
ALTER TABLE public.app_settings DROP COLUMN min_withdrawal_kobo;
