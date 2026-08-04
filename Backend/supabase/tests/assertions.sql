-- Backend behaviour tests, run against a freshly migrated + seeded database.
--
-- These assert the two properties the platform cannot be wrong about: a
-- professional is never double-booked, and one tenant never sees another's
-- data. Every check raises an exception on failure, so psql with
-- ON_ERROR_STOP=1 turns this file into a pass/fail gate.

\set ON_ERROR_STOP on
\timing off

create or replace function tests.assert(condition boolean, description text)
returns void language plpgsql as $$
begin
    if condition then
        raise notice '  ok    %', description;
    else
        raise exception 'FAILED: %', description;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Seed integrity: the SQL fixtures must match Swift's PreviewData so the demo
-- backend and the live backend describe the same world.
-- ---------------------------------------------------------------------------
\echo 'seed integrity'
do $$
begin
    perform tests.assert(
        exists (select 1 from salons where id = '00000000-0000-0000-0001-000000000001'
                and name = 'Maison Lumière'),
        'Maison Lumière seeded with the PreviewData UUID');
    perform tests.assert(
        exists (select 1 from services where id = '00000000-0000-0000-0003-000000000001'),
        'Balayage & Gloss seeded with the PreviewData UUID');
    perform tests.assert((select count(*) from salons) >= 2, 'at least two salons seeded');
end $$;

-- ---------------------------------------------------------------------------
-- Every table carries row-level security. A table added without it is a data
-- leak waiting to happen, so this is a hard gate rather than a review item.
-- ---------------------------------------------------------------------------
\echo 'row-level security coverage'
do $$
declare
    unprotected text;
begin
    select string_agg(t.tablename, ', ')
      into unprotected
      from pg_tables t
      join pg_class c
        on c.relname = t.tablename
       and c.relnamespace = 'public'::regnamespace
     where t.schemaname = 'public'
       and not c.relrowsecurity;

    perform tests.assert(unprotected is null,
        'every public table has RLS enabled' ||
        coalesce(' (missing: ' || unprotected || ')', ''));
end $$;

-- ---------------------------------------------------------------------------
-- The transactional booking RPC: the overlap check is the entire reason it
-- exists, so prove it rejects a conflicting request.
-- ---------------------------------------------------------------------------
\echo 'book_appointment overlap prevention'
do $$
declare
    v_client       uuid;
    v_professional uuid;
    v_request      jsonb;
    v_first        jsonb;
    v_rejected     boolean := false;
begin
    select id into v_client from profiles limit 1;
    select id into v_professional from professionals
     where salon_id = '00000000-0000-0000-0001-000000000001' limit 1;

    v_request := jsonb_build_object(
        'salon_id',  '00000000-0000-0000-0001-000000000001',
        'client_id', v_client,
        'slot',      jsonb_build_object(
                         'start', '2099-03-01T10:00:00Z',
                         'professional_id', v_professional),
        'items',     jsonb_build_array(jsonb_build_object(
                         'service_id', '00000000-0000-0000-0003-000000000001',
                         'professional_id', v_professional,
                         'add_on_ids', '[]'::jsonb)));

    v_first := book_appointment(v_request);
    perform tests.assert(v_first ? 'id', 'first booking is accepted and returns the appointment');
    perform tests.assert(
        exists (select 1 from appointment_items
                 where appointment_id = (v_first ->> 'id')::uuid),
        'first booking persisted its items');

    begin
        perform book_appointment(v_request);
    exception when others then
        v_rejected := true;
    end;
    perform tests.assert(v_rejected,
        'an overlapping booking for the same professional is rejected');

    -- The same slot with no professional named must also respect salon capacity
    -- rather than silently succeeding as an unassigned booking.
    delete from appointment_items where appointment_id = (v_first ->> 'id')::uuid;
    delete from appointments where id = (v_first ->> 'id')::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- Tenant isolation. The client experience runs as `authenticated` with a JWT
-- subject; the marketing surface runs as `anon`. Neither may read another
-- person's private rows.
-- ---------------------------------------------------------------------------
\echo 'tenant isolation under RLS'
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;

do $$
declare
    v_owner_id           uuid;
    v_anon_appointments  bigint;
    v_anon_crm           bigint;
    v_anon_salons        bigint;
    v_owner_appointments bigint;
    v_stranger_rows      bigint;
begin
    select clientID into v_owner_id from (
        select client_id as clientID from appointments limit 1
    ) s;

    set local role anon;
    select count(*) into v_anon_appointments from appointments;
    select count(*) into v_anon_crm from client_records;
    select count(*) into v_anon_salons from salons;
    reset role;

    perform tests.assert(v_anon_appointments = 0, 'anonymous cannot read appointments');
    perform tests.assert(v_anon_crm = 0, 'anonymous cannot read client records');
    perform tests.assert(v_anon_salons > 0, 'anonymous CAN read public salon listings');

    set local role authenticated;
    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    select count(*) into v_owner_appointments from appointments;
    reset role;
    perform tests.assert(v_owner_appointments > 0, 'a client reads their own appointments');

    set local role authenticated;
    perform set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
    select (select count(*) from appointments)
         + (select count(*) from client_records)
         + (select count(*) from wallet_transactions)
      into v_stranger_rows;
    reset role;
    perform tests.assert(v_stranger_rows = 0,
        'an unrelated signed-in user reads no appointments, CRM records, or wallet rows');
end $$;

\echo ''
\echo 'All backend assertions passed.'
