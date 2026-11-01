-- Minimal stand-in for what a Supabase project provides, so the schema runs on plain Postgres and in the browser demo.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text, raw_user_meta_data jsonb default '{}', email_confirmed_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
-- Supabase Vault (secrets kept apart from the tables) and the phone column of auth.users
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, description from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text, new_description text default '') returns uuid language sql
  as $$ insert into vault.secrets (name, secret, description) values (new_name, new_secret, new_description) returning id $$;
alter table auth.users add column if not exists phone text;
