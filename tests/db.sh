#!/usr/bin/env bash
# Database checks: builds a throwaway database from the migrations and runs every test file against it.
# Needs Postgres 15+ with pgcrypto. Usage: PGHOST=/var/run/postgresql PGUSER=postgres bash tests/db.sh
set -u
cd "$(dirname "$0")/.."
DB=${CREWDESK_TEST_DB:-central_test}
psql -qc "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
psql -d "$DB" -v ON_ERROR_STOP=1 -q -o /dev/null \
  -f supabase/tests/supabase_stub.sql \
  -f supabase/tests/storage_stub.sql \
  -f supabase/migrations/20261029100000_crewdesk.sql \
  -f supabase/tests/central_test_users.sql \
  -f supabase/migrations/20261030100000_central.sql \
  -f supabase/migrations/20261030100100_central_storage.sql \
  -f supabase/migrations/20261030100200_central_hardening.sql \
  -f supabase/migrations/20261031100000_notifications.sql \
  -f supabase/migrations/20261101100000_deductions_and_lists.sql \
  -f supabase/migrations/20261102100000_google_signin.sql \
  -f supabase/migrations/20261103100000_removals.sql \
  -f supabase/migrations/20261104100000_welcome_tour.sql \
  -f supabase/migrations/20261105100000_schedule_alerts_and_fixes.sql \
  -f supabase/migrations/20261106100000_chain_locks_tasks.sql \
  -f supabase/migrations/20261107100000_daily_costs_dpr.sql \
  -f supabase/migrations/20261109100000_overtime.sql \
  -f supabase/migrations/20261110100000_controller_and_invoice_files.sql \
  -f supabase/migrations/20261111100000_phone_mfa_encryption_imdb.sql \
  -f supabase/migrations/20261112100000_notification_prefs.sql \
  -f supabase/migrations/20261113100000_agreement_templates.sql \
  -f supabase/tests/central_test.sql \
  -f supabase/tests/central_notify_test.sql \
  -f supabase/tests/central_deduct_test.sql \
  -f supabase/tests/central_google_test.sql \
  -f supabase/tests/central_remove_test.sql \
  -f supabase/tests/central_schedule_test.sql \
  -f supabase/tests/central_chain_test.sql \
  -f supabase/tests/central_cost_test.sql \
  -f supabase/tests/central_view_test.sql \
  -f supabase/tests/central_ot_test.sql \
  -f supabase/tests/central_security_test.sql \
  -f supabase/tests/central_notify_prefs_test.sql \
  -f supabase/tests/central_agreement_test.sql \
  > /tmp/crewdesk-db-test.out 2>&1
code=$?
echo "checks passed: $(grep -c 'NOTICE:  ok' /tmp/crewdesk-db-test.out)"
grep -E "FAILED|ERROR" -B1 -A3 /tmp/crewdesk-db-test.out | head -20
grep -E "PASSED" /tmp/crewdesk-db-test.out
exit $code
