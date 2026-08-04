-- Availability under RLS, and GDPR-safe erasure.
--
-- Two gaps the live data layer exposed once it was written against the real
-- policies:
--
--  1. `appointments_select_participant` lets a client read only their OWN
--     bookings. A client computing free slots from what they can see therefore
--     sees an empty calendar and offers times another client already took —
--     `book_appointment` rejects them, but only after the client has chosen.
--     `salon_busy_intervals` is a SECURITY DEFINER function returning just the
--     busy windows, with no client identity attached, so slot lists are correct
--     without leaking who is booked.
--
--  2. Account erasure must remove personal data while retaining the financial
--     records a business is legally required to keep. `pseudonymize_client_records`
--     scrubs the identifiers and leaves the money.

-- ---------------------------------------------------------------------------
-- 1. Busy intervals for availability
-- ---------------------------------------------------------------------------

create or replace function public.salon_busy_intervals(
    p_salon_id        uuid,
    p_from            timestamptz,
    p_to              timestamptz,
    p_professional_id uuid default null
)
returns table (
    starts_at       timestamptz,
    ends_at         timestamptz,
    professional_id uuid
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    -- Deliberately projects no client, service, or price column: a prospective
    -- client may learn that a slot is taken, never by whom or for what.
    select
        item.starts_at,
        item.ends_at,
        item.professional_id
    from appointment_items item
    join appointments appointment
      on appointment.id = item.appointment_id
    where appointment.salon_id = p_salon_id
      and appointment.status in (
            'pending_confirmation', 'confirmed', 'checked_in', 'in_progress'
          )
      and item.starts_at < p_to
      and item.ends_at   > p_from
      and (p_professional_id is null or item.professional_id = p_professional_id);
$$;

comment on function public.salon_busy_intervals is
    'Busy windows for a salon in a date range, without client identities. '
    'SECURITY DEFINER so a client can compute correct availability under RLS.';

revoke all on function public.salon_busy_intervals(uuid, timestamptz, timestamptz, uuid) from public;
grant execute on function public.salon_busy_intervals(uuid, timestamptz, timestamptz, uuid)
    to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Erasure that keeps the books
-- ---------------------------------------------------------------------------

create or replace function public.pseudonymize_client_records(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_scrubbed  integer := 0;
    v_rows      integer;
    v_record_ids uuid[];
begin
    -- Capture the affected records BEFORE scrubbing: once user_id is cleared
    -- there is no way back to them, and matching on the placeholder name
    -- afterwards would also sweep up clients erased in earlier requests.
    select coalesce(array_agg(id), '{}')
      into v_record_ids
      from client_records
     where user_id = p_user_id;

    -- Free-text notes and photographs are personal data with no accounting
    -- value, so they go entirely.
    delete from client_notes where client_record_id = any(v_record_ids);
    get diagnostics v_rows = row_count;
    v_scrubbed := v_scrubbed + v_rows;

    -- Salon-held CRM records: strip everything identifying and everything the
    -- client confided, but keep the row so the salon's visit and revenue
    -- history stays consistent.
    update client_records
       set user_id      = null,
           first_name   = 'Deleted',
           last_name    = 'Client',
           email        = null,
           phone        = null,
           avatar_url   = null,
           birthday     = null,
           skin_type    = null,
           hair_type    = null,
           allergies    = '{}',
           preferences  = '{}'
     where id = any(v_record_ids);
    get diagnostics v_rows = row_count;
    v_scrubbed := v_scrubbed + v_rows;

    -- Messages: keep the conversation shape so the other party's thread stays
    -- coherent, drop the content. A text message must keep a non-empty body
    -- (constraint `messages_text_has_body`), so it gets a redaction marker
    -- rather than NULL.
    update messages
       set body = case when content_kind = 'text' then '[deleted]' else null end,
           media_url = null,
           caption = null,
           recommendation = null
     where sender_id = p_user_id;
    get diagnostics v_rows = row_count;
    v_scrubbed := v_scrubbed + v_rows;

    return v_scrubbed;
end;
$$;

comment on function public.pseudonymize_client_records is
    'Clears personal data for an erased account while retaining the financial '
    'records a business must keep. Called by the delete-account Edge Function.';

revoke all on function public.pseudonymize_client_records(uuid) from public;
grant execute on function public.pseudonymize_client_records(uuid) to service_role;
