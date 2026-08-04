-- Supabase platform objects, recreated locally.
--
-- Hosted Supabase provides the `auth` schema, the `anon` / `authenticated` /
-- `service_role` roles, and the JWT claim helpers before any project migration
-- runs. A bare Postgres does not, so this shim stands them up and lets the real
-- migrations execute unmodified against a throwaway database.
--
-- It is TEST-ONLY: never apply it to a hosted project, where these objects
-- already exist and are managed by the platform.

create extension if not exists pgcrypto;

create schema if not exists auth;

-- The subset of auth.users the project's migrations and seed touch.
create table if not exists auth.users (
    id                  uuid primary key default gen_random_uuid(),
    instance_id         uuid,
    aud                 varchar(255),
    role                varchar(255),
    email               text,
    encrypted_password  varchar(255),
    email_confirmed_at  timestamptz,
    raw_app_meta_data   jsonb,
    raw_user_meta_data  jsonb,
    created_at          timestamptz default now(),
    updated_at          timestamptz default now()
);

create table if not exists auth.identities (
    provider_id     text        not null,
    user_id         uuid        not null references auth.users(id) on delete cascade,
    identity_data   jsonb       not null,
    provider        text        not null,
    last_sign_in_at timestamptz,
    created_at      timestamptz default now(),
    updated_at      timestamptz default now(),
    primary key (provider, provider_id)
);

-- PostgREST exposes JWT claims as GUCs; these mirror the hosted helpers so RLS
-- policies can be exercised by setting request.jwt.claim.sub.
create or replace function auth.uid() returns uuid
    language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.role() returns text
    language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;

create or replace function auth.email() returns text
    language sql stable
as $$ select nullif(current_setting('request.jwt.claim.email', true), '') $$;

do $$
begin
    if not exists (select from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
    if not exists (select from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
    if not exists (select from pg_roles where rolname = 'service_role') then
        create role service_role nologin bypassrls;
    end if;
end $$;
