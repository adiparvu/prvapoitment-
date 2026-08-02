-- =============================================================================
-- PRV Beauty — 0003_functions_triggers.sql
--
-- The behaviour that has to live in the database because it must be true for
-- every caller: booking atomicity, aggregate maintenance, loyalty accrual,
-- stock alerts, and the derived views the client reads.
--
-- Every function that writes is SECURITY DEFINER with a pinned `search_path`
-- and an explicit EXECUTE grant. `book_appointment` and `award_loyalty_xp` are
-- the two that move state a client must not be able to move on its own, so
-- they authorize the caller before they touch a row.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- updated_at
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'profiles', 'organizations', 'salons', 'professionals', 'services',
    'appointments', 'orders', 'membership_plans', 'membership_subscriptions',
    'service_packages', 'loyalty_profiles', 'loyalty_challenges', 'reviews',
    'conversations', 'client_records', 'employees', 'shifts',
    'performance_goals', 'suppliers', 'products', 'purchase_orders',
    'coupons', 'campaigns'
  ]
  loop
    execute format(
      'create trigger %I_set_updated_at before update on public.%I
         for each row execute function public.set_updated_at()',
      v_table, v_table
    );
  end loop;
end;
$$;

create trigger prepayment_policies_set_updated_at
  before update on prepayment_policies
  for each row execute function public.set_updated_at();

create trigger feature_flags_set_updated_at
  before update on feature_flags
  for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- New account bootstrap
--
-- Sign-up creates the auth user; this creates everything the app expects to
-- exist on first launch — the profile row and a loyalty profile with a referral
-- code — so no screen has to handle "the user exists but has no profile yet".
-- -----------------------------------------------------------------------------

create or replace function public.generate_referral_code()
returns text
language sql
volatile
as $$
  select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
begin
  insert into profiles (id, role, first_name, last_name, email, phone, avatar_url, preferred_language)
  values (
    new.id,
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'client'),
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    coalesce(new.raw_user_meta_data ->> 'last_name', ''),
    coalesce(new.email, new.id::text || '@placeholder.invalid'),
    new.raw_user_meta_data ->> 'phone',
    new.raw_user_meta_data ->> 'avatar_url',
    coalesce(new.raw_user_meta_data ->> 'preferred_language', 'en')
  )
  on conflict (id) do nothing
  returning id into v_profile_id;

  if v_profile_id is not null then
    insert into loyalty_profiles (user_id, referral_code, referred_by_code)
    values (
      v_profile_id,
      public.generate_referral_code(),
      nullif(upper(coalesce(new.raw_user_meta_data ->> 'referred_by_code', '')), '')
    )
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- -----------------------------------------------------------------------------
-- Appointment spans and blocking state
--
-- `appointments.starts_at` / `ends_at` are derived from the items so the
-- calendar can index them. `appointment_items.is_blocking` is derived from the
-- parent status so the exclusion constraint in 0001 stops enforcing overlap
-- once a booking is cancelled or completed — a cancelled slot must be
-- immediately re-bookable.
-- -----------------------------------------------------------------------------

create or replace function public.sync_appointment_span()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_appointment_id uuid;
begin
  -- NEW is unassigned on DELETE and OLD on INSERT, so branch before touching them.
  if tg_op = 'DELETE' then
    v_appointment_id := old.appointment_id;
  else
    v_appointment_id := new.appointment_id;
  end if;

  update appointments a
  set starts_at = agg.min_start,
      ends_at   = agg.max_end
  from (
    select min(starts_at) as min_start, max(ends_at) as max_end
    from appointment_items
    where appointment_id = v_appointment_id
  ) as agg
  where a.id = v_appointment_id
    and (a.starts_at is distinct from agg.min_start or a.ends_at is distinct from agg.max_end);

  return null;
end;
$$;

create trigger appointment_items_sync_span
  after insert or update of starts_at, ends_at or delete on appointment_items
  for each row execute function public.sync_appointment_span();

create or replace function public.sync_appointment_item_blocking()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_blocking boolean := new.status in
    ('pending_confirmation', 'confirmed', 'checked_in', 'in_progress');
begin
  update appointment_items
  set is_blocking = v_blocking
  where appointment_id = new.id
    and is_blocking is distinct from v_blocking;

  return null;
end;
$$;

create trigger appointments_sync_blocking
  after update of status on appointments
  for each row
  when (old.status is distinct from new.status)
  execute function public.sync_appointment_item_blocking();

-- -----------------------------------------------------------------------------
-- Reviews → salon and professional aggregates
--
-- `salons.rating` / `review_count` are a cache of the approved reviews. They
-- are recomputed rather than incremented so a moderation decision, an edit, and
-- a delete all converge on the same number.
-- -----------------------------------------------------------------------------

create or replace function public.refresh_review_aggregates()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_salon_ids        uuid[] := '{}'::uuid[];
  v_professional_ids uuid[] := '{}'::uuid[];
begin
  -- Collect both sides of the change: a review that moved between salons or
  -- professionals must refresh the aggregate it left as well as the one it
  -- joined. OLD/NEW are only readable for the operations that assign them.
  if tg_op in ('UPDATE', 'DELETE') then
    v_salon_ids := v_salon_ids || old.salon_id;
    if old.professional_id is not null then
      v_professional_ids := v_professional_ids || old.professional_id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_salon_ids := v_salon_ids || new.salon_id;
    if new.professional_id is not null then
      v_professional_ids := v_professional_ids || new.professional_id;
    end if;
  end if;

  update salons s
  set rating = coalesce(agg.avg_rating, 0),
      review_count = coalesce(agg.total, 0)
  from (
    select r.salon_id,
           round(avg(r.rating)::numeric, 2) as avg_rating,
           count(*) as total
    from reviews r
    where r.salon_id = any (v_salon_ids)
      and r.moderation = 'approved'
    group by r.salon_id
  ) agg
  where s.id = agg.salon_id;

  -- A salon whose last approved review was removed drops back to zero.
  update salons s
  set rating = 0, review_count = 0
  where s.id = any (v_salon_ids)
    and not exists (
      select 1 from reviews r where r.salon_id = s.id and r.moderation = 'approved'
    );

  if cardinality(v_professional_ids) > 0 then
    update professionals p
    set rating = coalesce(agg.avg_rating, 0),
        review_count = coalesce(agg.total, 0)
    from (
      select r.professional_id,
             round(avg(r.rating)::numeric, 2) as avg_rating,
             count(*) as total
      from reviews r
      where r.professional_id = any (v_professional_ids)
        and r.moderation = 'approved'
      group by r.professional_id
    ) agg
    where p.id = agg.professional_id;

    update professionals p
    set rating = 0, review_count = 0
    where p.id = any (v_professional_ids)
      and not exists (
        select 1 from reviews r where r.professional_id = p.id and r.moderation = 'approved'
      );
  end if;

  return null;
end;
$$;

create trigger reviews_refresh_aggregates
  after insert or update of rating, moderation, salon_id, professional_id or delete on reviews
  for each row execute function public.refresh_review_aggregates();

create or replace function public.refresh_review_like_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_review_id uuid;
begin
  if tg_op = 'DELETE' then
    v_review_id := old.review_id;
  else
    v_review_id := new.review_id;
  end if;

  update reviews r
  set like_count = (select count(*) from review_likes rl where rl.review_id = v_review_id)
  where r.id = v_review_id;
  return null;
end;
$$;

create trigger review_likes_refresh_count
  after insert or delete on review_likes
  for each row execute function public.refresh_review_like_count();

-- -----------------------------------------------------------------------------
-- Coupons → redemption count
-- -----------------------------------------------------------------------------

create or replace function public.refresh_coupon_redemption_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_coupon_id uuid;
begin
  if tg_op = 'DELETE' then
    v_coupon_id := old.coupon_id;
  else
    v_coupon_id := new.coupon_id;
  end if;

  update coupons c
  set redemption_count = (
    select count(*) from coupon_redemptions cr where cr.coupon_id = v_coupon_id
  )
  where c.id = v_coupon_id;
  return null;
end;
$$;

create trigger coupon_redemptions_refresh_count
  after insert or delete on coupon_redemptions
  for each row execute function public.refresh_coupon_redemption_count();

-- -----------------------------------------------------------------------------
-- appointment_payload
--
-- Serializes one appointment into the exact shape `PRVModels.Appointment`
-- decodes: snake_case keys, ISO-8601 instants, and `Money` as
-- {amount, currency}. Defined before `book_appointment`, which returns it.
-- -----------------------------------------------------------------------------

create or replace function public.appointment_payload(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', a.id,
    'salon_id', a.salon_id,
    'salon_name', a.salon_name,
    'client_id', a.client_id,
    'additional_client_ids', to_jsonb(a.additional_client_ids),
    'status', a.status,
    'recurrence', case
      when a.recurrence_frequency is null then null
      else jsonb_build_object(
        'frequency', a.recurrence_frequency,
        'occurrences', a.recurrence_occurrences
      )
    end,
    'order_id', a.order_id,
    'client_notes', a.client_notes,
    'internal_notes', a.internal_notes,
    'created_at', to_char(a.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'updated_at', to_char(a.updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', ai.id,
          'service_id', ai.service_id,
          'service_name', ai.service_name,
          'professional_id', ai.professional_id,
          'professional_name', ai.professional_name,
          'start', to_char(ai.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'duration_minutes', ai.duration_minutes,
          'price', jsonb_build_object('amount', ai.price_amount, 'currency', ai.price_currency),
          'add_on_ids', to_jsonb(ai.add_on_ids)
        )
        order by ai.position
      )
      from appointment_items ai
      where ai.appointment_id = a.id
    ), '[]'::jsonb)
  )
  from appointments a
  where a.id = p_appointment_id;
$$;

comment on function public.appointment_payload(uuid) is
  'One appointment as the JSON shape PRVModels.Appointment decodes.';

-- -----------------------------------------------------------------------------
-- book_appointment
--
-- The transactional heart of the platform. Mirrors `BookingRequest` →
-- `Appointment` and is the ONLY supported way to create a booking, because it
-- is the only path that takes the locks:
--
--   1. an advisory transaction lock per professional, which serializes two
--      requests for the same chair even when neither can see the other's
--      uncommitted rows;
--   2. `SELECT … FOR UPDATE` over the overlapping items, so a concurrent
--      reschedule of an existing booking cannot slip underneath;
--   3. the `appointment_items_no_overlap` exclusion constraint from 0001 as the
--      final backstop — if the two above were ever bypassed, the database still
--      refuses the write.
--
-- Raises SQLSTATE 'PRV09' on a slot conflict, 'PRV04' on unknown references,
-- and 'PRV01' on an unauthorized caller. Rolls back everything on any of them.
-- -----------------------------------------------------------------------------

create or replace function public.book_appointment(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_salon_id            uuid := nullif(p_request ->> 'salon_id', '')::uuid;
  v_client_id           uuid := nullif(p_request ->> 'client_id', '')::uuid;
  v_slot_start          timestamptz := (p_request #>> '{slot,start}')::timestamptz;
  v_slot_professional   uuid := nullif(p_request #>> '{slot,professional_id}', '')::uuid;
  v_additional_clients  uuid[] := coalesce(
    (select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(p_request -> 'additional_client_ids', '[]'::jsonb))),
    '{}'::uuid[]
  );
  v_recurrence_frequency   recurrence_frequency :=
    nullif(p_request #>> '{recurrence,frequency}', '')::recurrence_frequency;
  v_recurrence_occurrences integer :=
    nullif(p_request #>> '{recurrence,occurrences}', '')::integer;
  v_notes               text := nullif(p_request ->> 'notes', '');
  v_coupon_code         text := nullif(p_request ->> 'coupon_code', '');
  v_salon               salons%rowtype;
  v_item                jsonb;
  v_service             services%rowtype;
  v_professional        professionals%rowtype;
  v_professional_id     uuid;
  v_professional_name   text;
  v_add_on_ids          uuid[];
  v_add_on_minutes      integer;
  v_add_on_price        numeric(12, 2);
  v_cursor              timestamptz;
  v_item_start          timestamptz;
  v_item_end            timestamptz;
  v_appointment_id      uuid;
  v_position            integer := 0;
  v_requires_prepayment boolean := false;
  v_status              appointment_status;
  v_conflict            record;
  v_result              jsonb;
begin
  if v_salon_id is null or v_client_id is null or v_slot_start is null then
    raise exception 'book_appointment: salon_id, client_id and slot.start are required'
      using errcode = 'PRV04';
  end if;

  if jsonb_typeof(p_request -> 'items') is distinct from 'array'
     or jsonb_array_length(p_request -> 'items') = 0 then
    raise exception 'book_appointment: at least one item is required'
      using errcode = 'PRV04';
  end if;

  -- Authorization. auth.uid() is NULL only for service_role (EXECUTE is not
  -- granted to anon), which is how the confirm-booking Edge Function calls in
  -- after it has already verified the caller's JWT.
  if auth.uid() is not null
     and auth.uid() <> v_client_id
     and not public.is_salon_member(v_salon_id) then
    raise exception 'book_appointment: not permitted to book for another client'
      using errcode = 'PRV01';
  end if;

  select * into v_salon from salons where id = v_salon_id;
  if not found then
    raise exception 'book_appointment: salon % not found', v_salon_id using errcode = 'PRV04';
  end if;

  if v_coupon_code is not null then
    perform 1 from coupons c
    where c.salon_id = v_salon_id
      and upper(c.code) = upper(v_coupon_code)
      and c.is_active
      and c.valid_from <= now()
      and (c.valid_until is null or c.valid_until > now())
      and (c.max_redemptions is null or c.redemption_count < c.max_redemptions);
    if not found then
      raise exception 'book_appointment: coupon % is not valid for this salon', v_coupon_code
        using errcode = 'PRV04';
    end if;
  end if;

  insert into appointments (
    salon_id, salon_name, client_id, additional_client_ids,
    status, recurrence_frequency, recurrence_occurrences, client_notes
  )
  values (
    v_salon_id, v_salon.name, v_client_id, v_additional_clients,
    'pending_confirmation', v_recurrence_frequency, v_recurrence_occurrences, v_notes
  )
  returning id into v_appointment_id;

  v_cursor := v_slot_start;

  for v_item in select value from jsonb_array_elements(p_request -> 'items') loop
    select * into v_service
    from services
    where id = nullif(v_item ->> 'service_id', '')::uuid and is_active;

    if not found then
      raise exception 'book_appointment: service % not found or inactive', v_item ->> 'service_id'
        using errcode = 'PRV04';
    end if;

    if v_service.salon_id is not null and v_service.salon_id <> v_salon_id then
      raise exception 'book_appointment: service % does not belong to salon %',
        v_service.id, v_salon_id using errcode = 'PRV04';
    end if;

    v_requires_prepayment := v_requires_prepayment or v_service.requires_prepayment;

    v_add_on_ids := coalesce(
      (select array_agg(value::uuid)
       from jsonb_array_elements_text(coalesce(v_item -> 'add_on_ids', '[]'::jsonb))),
      '{}'::uuid[]
    );

    select coalesce(sum(extra_minutes), 0), coalesce(sum(price_amount), 0)
      into v_add_on_minutes, v_add_on_price
    from service_add_ons
    where id = any (v_add_on_ids) and service_id = v_service.id and is_active;

    if cardinality(v_add_on_ids) <> (
      select count(*) from service_add_ons
      where id = any (v_add_on_ids) and service_id = v_service.id and is_active
    ) then
      raise exception 'book_appointment: one or more add-ons are unknown for service %', v_service.id
        using errcode = 'PRV04';
    end if;

    v_professional_id := coalesce(nullif(v_item ->> 'professional_id', '')::uuid, v_slot_professional);
    v_professional_name := null;

    if v_professional_id is not null then
      select * into v_professional from professionals where id = v_professional_id and is_active;
      if not found then
        raise exception 'book_appointment: professional % not found or inactive', v_professional_id
          using errcode = 'PRV04';
      end if;
      if v_professional.salon_id is distinct from v_salon_id and not v_professional.is_freelancer then
        raise exception 'book_appointment: professional % does not work at salon %',
          v_professional_id, v_salon_id using errcode = 'PRV04';
      end if;
      v_professional_name := v_professional.display_name;
    end if;

    -- The client-facing service window starts after this service's preparation.
    v_item_start := v_cursor + make_interval(mins => v_service.preparation_minutes);
    -- The chair stays occupied through cleanup and the salon's inter-booking
    -- buffer; that is the window we test for conflicts.
    v_item_end := v_item_start + make_interval(
      mins => v_service.duration_minutes + v_add_on_minutes
              + v_service.cleanup_minutes + v_service.buffer_minutes
    );

    if v_professional_id is not null then
      -- (1) Serialize every booking attempt for this professional.
      perform pg_advisory_xact_lock(hashtextextended(v_professional_id::text, 0));

      -- (2) Lock any existing item that overlaps, and fail loudly if one does.
      select ai.id, ai.starts_at, ai.ends_at
        into v_conflict
      from appointment_items ai
      join appointments a on a.id = ai.appointment_id
      where ai.professional_id = v_professional_id
        and ai.is_blocking
        and a.status in ('pending_confirmation', 'confirmed', 'checked_in', 'in_progress')
        and ai.appointment_id <> v_appointment_id
        and tstzrange(ai.starts_at, ai.ends_at, '[)') && tstzrange(v_item_start, v_item_end, '[)')
      order by ai.starts_at
      limit 1
      for update of ai;

      if found then
        raise exception
          'book_appointment: % is already booked between % and %',
          coalesce(v_professional_name, v_professional_id::text),
          v_conflict.starts_at, v_conflict.ends_at
          using errcode = 'PRV09',
                hint = 'Choose another time slot or another professional.';
      end if;
    end if;

    -- (3) The exclusion constraint is the final arbiter on this INSERT.
    insert into appointment_items (
      appointment_id, service_id, service_name, professional_id, professional_name,
      starts_at, duration_minutes, ends_at, price_amount, price_currency, add_on_ids, position
    )
    values (
      v_appointment_id, v_service.id, v_service.name, v_professional_id, v_professional_name,
      v_item_start, v_service.duration_minutes + v_add_on_minutes, v_item_end,
      v_service.price_amount + v_add_on_price, v_service.price_currency, v_add_on_ids, v_position
    );

    v_cursor := v_item_end;
    v_position := v_position + 1;
  end loop;

  -- A visit that requires money up front stays pending until it is paid;
  -- everything else is confirmed the moment the slot is held.
  v_status := case when v_requires_prepayment then 'pending_confirmation' else 'confirmed' end;
  update appointments set status = v_status where id = v_appointment_id;

  select public.appointment_payload(v_appointment_id) into v_result;
  return v_result;

exception
  when exclusion_violation then
    raise exception 'book_appointment: that slot was taken while you were booking'
      using errcode = 'PRV09',
            hint = 'Refresh availability and pick another slot.';
end;
$$;

comment on function public.book_appointment(jsonb) is
  'Transactionally books an appointment from a BookingRequest payload. Raises PRV09 on slot conflict, PRV04 on unknown references, PRV01 when the caller may not book for that client.';

-- -----------------------------------------------------------------------------
-- award_loyalty_xp
--
-- The single write path for XP and spendable points. The tier is never stored —
-- `LoyaltyTier.tier(forXP:)` derives it on the client from the same thresholds
-- returned here, so the two can never disagree.
-- -----------------------------------------------------------------------------

create or replace function public.award_loyalty_xp(p_user uuid, p_xp integer, p_points integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile loyalty_profiles%rowtype;
  v_tier    loyalty_tier;
begin
  if p_user is null then
    raise exception 'award_loyalty_xp: p_user is required' using errcode = 'PRV04';
  end if;

  if coalesce(p_xp, 0) < 0 or coalesce(p_points, 0) < 0 then
    raise exception 'award_loyalty_xp: awards cannot be negative' using errcode = 'PRV04';
  end if;

  insert into loyalty_profiles (user_id, xp, spendable_points, referral_code)
  values (p_user, coalesce(p_xp, 0), coalesce(p_points, 0), public.generate_referral_code())
  on conflict (user_id) do update
    set xp = loyalty_profiles.xp + coalesce(p_xp, 0),
        spendable_points = loyalty_profiles.spendable_points + coalesce(p_points, 0),
        updated_at = now()
  returning * into v_profile;

  v_tier := case
    when v_profile.xp >= 40000 then 'black'
    when v_profile.xp >= 15000 then 'diamond'
    when v_profile.xp >= 5000  then 'gold'
    when v_profile.xp >= 1000  then 'silver'
    else 'bronze'
  end;

  if coalesce(p_points, 0) > 0 then
    insert into wallet_transactions (user_id, kind, amount, points, title)
    values (p_user, 'reward_points', 0, p_points, 'Reward points earned');
  end if;

  return jsonb_build_object(
    'id', v_profile.id,
    'user_id', v_profile.user_id,
    'xp', v_profile.xp,
    'spendable_points', v_profile.spendable_points,
    'tier', v_tier,
    'referral_code', v_profile.referral_code,
    'current_streak_days', v_profile.current_streak_days
  );
end;
$$;

comment on function public.award_loyalty_xp(uuid, integer, integer) is
  'Adds XP and spendable points to a loyalty profile, creating it if absent. Service-role only — the client can read its balance but never set it.';

-- -----------------------------------------------------------------------------
-- Low-stock alerts
--
-- Fires on the transition into low stock, not on every decrement, so selling
-- the last five units of a product produces one notification rather than five.
-- -----------------------------------------------------------------------------

create or replace function public.notify_low_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_salon_name text;
  v_recipients uuid[];
begin
  if new.stock_quantity > new.low_stock_threshold then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    -- Nested rather than `AND`-ed: OLD is only readable on UPDATE.
    if old.stock_quantity <= old.low_stock_threshold then
      return null; -- already low; do not re-alert
    end if;
  end if;

  select name into v_salon_name from salons where id = new.salon_id;

  select array_agg(distinct e.user_id)
    into v_recipients
  from employees e
  join role_permissions rp on rp.role = e.role
  where e.salon_id = new.salon_id
    and e.user_id is not null
    and e.terminated_at is null
    and rp.permission = 'manageInventory';

  if v_recipients is null then
    return null;
  end if;

  insert into notifications (user_id, kind, title, body, route)
  select
    recipient,
    'system',
    'Low stock: ' || new.name,
    format(
      '%s has %s left at %s (threshold %s). Reorder to avoid running out.',
      new.name, new.stock_quantity, coalesce(v_salon_name, 'your salon'), new.low_stock_threshold
    ),
    -- `route` must decode as an `AppRoute`: Swift's synthesized enum encoding,
    -- one key naming the case with its positional values keyed `_0`. There is
    -- no inventory case, so the alert opens the salon the stock belongs to —
    -- an ad-hoc shape here fails to decode and takes the whole Notification
    -- Centre page down with it.
    jsonb_build_object('salon', jsonb_build_object('_0', new.salon_id::text))
  from unnest(v_recipients) as recipient;

  return null;
end;
$$;

create trigger products_notify_low_stock
  after insert or update of stock_quantity, low_stock_threshold on products
  for each row execute function public.notify_low_stock();

-- -----------------------------------------------------------------------------
-- Derived views
--
-- `security_invoker` keeps the caller's RLS in force, so a view can never be
-- used as a way around a policy.
-- -----------------------------------------------------------------------------

-- The Beauty Wallet balance: the running sum of the append-only ledger.
create view wallet_balances
with (security_invoker = true)
as
select
  wt.user_id,
  wt.currency,
  sum(wt.amount)                                       as balance_amount,
  sum(wt.points)                                       as points_balance,
  sum(wt.amount) filter (where wt.kind = 'cashback')   as cashback_amount,
  sum(wt.amount) filter (where wt.kind in ('store_credit_top_up', 'store_credit_spend'))
                                                       as store_credit_amount,
  count(*)                                             as transaction_count,
  max(wt.created_at)                                   as last_transaction_at
from wallet_transactions wt
group by wt.user_id, wt.currency;

comment on view wallet_balances is
  'Per-user, per-currency Beauty Wallet balance derived from the wallet_transactions ledger.';

-- Order money, computed from the lines. Nothing here is stored, so a client
-- cannot present a total that disagrees with what it is buying.
create view order_totals
with (security_invoker = true)
as
select
  o.id                                                    as order_id,
  o.salon_id,
  o.client_id,
  o.currency,
  o.status,
  coalesce(sum(ol.unit_price * ol.quantity), 0)           as subtotal_amount,
  o.discount_amount,
  greatest(coalesce(sum(ol.unit_price * ol.quantity), 0) - o.discount_amount, 0) as total_amount,
  o.amount_paid,
  greatest(
    greatest(coalesce(sum(ol.unit_price * ol.quantity), 0) - o.discount_amount, 0) - o.amount_paid,
    0
  )                                                       as outstanding_amount,
  o.vat_percent,
  round(
    greatest(coalesce(sum(ol.unit_price * ol.quantity), 0) - o.discount_amount, 0)
      * o.vat_percent / (100 + o.vat_percent),
    2
  )                                                       as vat_amount
from orders o
left join order_lines ol on ol.order_id = o.id
group by o.id;

comment on view order_totals is
  'Server-side order arithmetic. VAT is inclusive (EU style), so vat_amount is extracted from the total rather than added to it.';

-- What the salon dashboard reads for its headline numbers.
create view salon_daily_metrics
with (security_invoker = true)
as
select
  a.salon_id,
  date_trunc('day', a.starts_at)                                          as day,
  count(*)                                                                as appointment_count,
  count(*) filter (where a.status = 'completed')                          as completed_count,
  count(*) filter (where a.status in ('cancelled_by_client', 'cancelled_by_salon')) as cancelled_count,
  count(*) filter (where a.status = 'no_show')                            as no_show_count,
  coalesce(sum(items.total_amount), 0)                                    as booked_amount
from appointments a
left join lateral (
  select sum(ai.price_amount) as total_amount
  from appointment_items ai
  where ai.appointment_id = a.id
) items on true
where a.starts_at is not null
group by a.salon_id, date_trunc('day', a.starts_at);

-- -----------------------------------------------------------------------------
-- Execute grants
--
-- `book_appointment` is callable by a signed-in client (it authorizes the
-- caller itself). `award_loyalty_xp` is service-role only — XP is granted by the
-- payment pipeline, never claimed by a device.
-- -----------------------------------------------------------------------------

revoke all on function public.book_appointment(jsonb) from public;
revoke all on function public.award_loyalty_xp(uuid, integer, integer) from public;
revoke all on function public.appointment_payload(uuid) from public;

grant execute on function public.book_appointment(jsonb) to authenticated, service_role;
grant execute on function public.appointment_payload(uuid) to authenticated, service_role;
grant execute on function public.award_loyalty_xp(uuid, integer, integer) to service_role;

grant execute on function public.is_salon_member(uuid) to anon, authenticated, service_role;
grant execute on function public.is_salon_manager(uuid) to anon, authenticated, service_role;
grant execute on function public.has_permission(permission) to anon, authenticated, service_role;
grant execute on function public.is_platform_admin() to anon, authenticated, service_role;
grant execute on function public.current_role_value() to anon, authenticated, service_role;

grant select on wallet_balances, order_totals, salon_daily_metrics to authenticated, service_role;
