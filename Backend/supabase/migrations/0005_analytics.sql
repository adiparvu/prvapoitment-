-- =============================================================================
-- PRV Beauty — 0005_analytics.sql
--
-- The salon dashboard, computed where the data lives.
--
-- `PRVModels.DashboardSnapshot` is seventeen figures plus three series, drawn
-- from `orders`, `order_lines`, `refunds`, `appointments`, `appointment_items`,
-- `shifts`, `salon_opening_hours`, `professionals`, and
-- `membership_subscriptions`. Assembling it from the device would mean a dozen
-- round trips, a dozen partial failures, and a dozen chances for two figures on
-- the same screen to disagree because they were read a second apart. It is
-- therefore one function: everything below is evaluated inside a single
-- statement, against one snapshot of the database, and returned as one object
-- shaped exactly like the Swift type.
--
-- Conventions, matching `0003_functions_triggers.sql`:
--
--   * keys are snake_case and instants are whole-second UTC ISO-8601 text, the
--     one shape `JSONCoding.decoder` and `SupabaseTimestamp` both accept;
--   * money is a bare `numeric` plus one `currency` field for the whole
--     snapshot — the salon's own currency — because `Money` is
--     (amount, currency) and a location bills in exactly one;
--   * rates are fractions in 0…1, never percentages;
--   * `security definer` with a pinned `search_path`, and the function
--     authorizes its own caller, raising 'PRV01' (→ APIError.forbidden) or
--     'PRV04' (→ APIError.notFound).
--
-- The reporting window is HALF-OPEN — [p_start, p_end) — which is what
-- `PRVDashboardFeature` computes and what every comparison window assumes.
-- `p_start` is whatever midnight the caller's calendar produced, so the daily
-- buckets are stepped from it rather than from `date_trunc`: a salon in Brussels
-- gets Brussels days, not UTC days.
-- =============================================================================

-- Revenue is read by `paid_at`, which no existing index covers: `orders_salon_idx`
-- is on `created_at`. Partial, because an unpaid order is never in scope.
create index if not exists orders_salon_paid_idx
  on orders (salon_id, paid_at)
  where paid_at is not null;

-- Every breakdown groups appointment items by the day they were performed.
create index if not exists appointment_items_start_idx
  on appointment_items (starts_at);

-- -----------------------------------------------------------------------------
-- salon_dashboard
--
-- Definitions, stated once so the app never has to guess what a number means:
--
--   revenue              money actually collected in the window
--                        (`orders.amount_paid` for orders paid inside it) less
--                        refunds issued inside it. Never negative.
--   revenue_forecast     revenue plus the value of appointments still to come
--                        inside the window that are not cancelled — money in the
--                        bank plus money on the books. Equals revenue for a
--                        window entirely in the past.
--   appointment_count    appointments starting in the window, any status.
--   completed_count      … of which completed.
--   cancellation_rate    cancelled_by_client + cancelled_by_salon, over
--                        appointment_count. No-shows are a different failure and
--                        are not counted here.
--   occupancy_rate       booked chair-minutes over available chair-minutes,
--                        capped at 1. Availability is the rostered shifts when a
--                        roster exists, and otherwise opening hours times the
--                        number of active professionals — which is the honest
--                        approximation for a salon that does not roster.
--   new_client_count     clients who visited in the window and never before.
--   returning_client_count  clients who visited in the window and also before it.
--   retention_rate       returning over total distinct clients in the window.
--   average_ticket       revenue over the number of orders paid in the window.
--   products_sold        units on `order_lines.kind = 'product'` for orders paid
--                        in the window.
--   memberships_sold     subscriptions started in the window on this salon's plans.
--   revenue_series       one point per day of the window, zero-filled.
--   revenue_by_service   completed item revenue by service name, top 10.
--   revenue_by_employee  the same by professional, unassigned work grouped.
-- -----------------------------------------------------------------------------

create or replace function public.salon_dashboard(
  p_salon_id uuid,
  p_start    timestamptz,
  p_end      timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_currency          currency_code;
  v_now               timestamptz := now();
  v_revenue           numeric(14, 2) := 0;
  v_refunded          numeric(14, 2) := 0;
  v_paid_orders       integer := 0;
  v_future_booked     numeric(14, 2) := 0;
  v_appointments      integer := 0;
  v_completed         integer := 0;
  v_cancelled         integer := 0;
  v_booked_minutes    numeric := 0;
  v_shift_minutes     numeric := 0;
  v_hours_minutes     numeric := 0;
  v_professionals     integer := 0;
  v_capacity_minutes  numeric := 0;
  v_new_clients       integer := 0;
  v_returning_clients integer := 0;
  v_period_clients    integer := 0;
  v_products_sold     integer := 0;
  v_memberships_sold  integer := 0;
  v_series            jsonb;
  v_by_service        jsonb;
  v_by_employee       jsonb;
begin
  if p_salon_id is null or p_start is null or p_end is null or p_end <= p_start then
    raise exception 'salon_dashboard: a salon and an ordered half-open window are required'
      using errcode = 'PRV04';
  end if;

  -- Authorization is this function's own job: it runs as the definer, so it
  -- sees every row regardless of policy, and must not hand a report to somebody
  -- the policies would have refused.
  if not (public.is_salon_member(p_salon_id) and public.has_permission('viewReports')) then
    raise exception 'salon_dashboard: not authorized to report on salon %', p_salon_id
      using errcode = 'PRV01';
  end if;

  select s.currency into v_currency from salons s where s.id = p_salon_id;
  if v_currency is null then
    raise exception 'salon_dashboard: salon % not found', p_salon_id
      using errcode = 'PRV04';
  end if;

  -- ---------------------------------------------------------------------------
  -- Money
  -- ---------------------------------------------------------------------------

  select coalesce(sum(o.amount_paid), 0), count(*)
  into v_revenue, v_paid_orders
  from orders o
  where o.salon_id = p_salon_id
    and o.paid_at is not null
    and o.paid_at >= p_start
    and o.paid_at <  p_end
    and o.amount_paid > 0;

  select coalesce(sum(r.amount), 0)
  into v_refunded
  from refunds r
  join orders o on o.id = r.order_id
  where o.salon_id = p_salon_id
    and r.created_at >= p_start
    and r.created_at <  p_end;

  v_revenue := greatest(v_revenue - v_refunded, 0);

  -- Work already on the books for the remainder of the window.
  select coalesce(sum(ai.price_amount), 0)
  into v_future_booked
  from appointment_items ai
  join appointments a on a.id = ai.appointment_id
  where a.salon_id = p_salon_id
    and ai.starts_at >= greatest(p_start, v_now)
    and ai.starts_at <  p_end
    and a.status in ('pending_confirmation', 'confirmed', 'checked_in', 'in_progress');

  select coalesce(sum(ol.quantity), 0)
  into v_products_sold
  from order_lines ol
  join orders o on o.id = ol.order_id
  where o.salon_id = p_salon_id
    and ol.kind = 'product'
    and o.paid_at is not null
    and o.paid_at >= p_start
    and o.paid_at <  p_end;

  select count(*)
  into v_memberships_sold
  from membership_subscriptions ms
  join membership_plans mp on mp.id = ms.plan_id
  where mp.salon_id = p_salon_id
    and ms.started_at >= p_start
    and ms.started_at <  p_end;

  -- ---------------------------------------------------------------------------
  -- Appointments
  -- ---------------------------------------------------------------------------

  select
    count(*),
    count(*) filter (where a.status = 'completed'),
    count(*) filter (where a.status in ('cancelled_by_client', 'cancelled_by_salon'))
  into v_appointments, v_completed, v_cancelled
  from appointments a
  where a.salon_id = p_salon_id
    and a.starts_at >= p_start
    and a.starts_at <  p_end;

  -- ---------------------------------------------------------------------------
  -- Occupancy
  -- ---------------------------------------------------------------------------

  select coalesce(sum(extract(epoch from (ai.ends_at - ai.starts_at))::numeric / 60), 0)
  into v_booked_minutes
  from appointment_items ai
  join appointments a on a.id = ai.appointment_id
  where a.salon_id = p_salon_id
    and ai.starts_at >= p_start
    and ai.starts_at <  p_end
    and a.status not in ('cancelled_by_client', 'cancelled_by_salon', 'no_show');

  -- Rostered capacity, clipped to the window so a shift straddling either edge
  -- contributes only the part that falls inside it.
  select coalesce(sum(
           extract(
             epoch from (least(sh.ends_at, p_end) - greatest(sh.starts_at, p_start))
           )::numeric / 60
         ), 0)
  into v_shift_minutes
  from shifts sh
  where sh.salon_id = p_salon_id
    and sh.starts_at <  p_end
    and sh.ends_at   >  p_start;

  select count(*)
  into v_professionals
  from professionals pr
  where pr.salon_id = p_salon_id
    and pr.is_active;

  -- Opening-hours capacity, used when the salon does not roster. `weekday` is
  -- 1 = Sunday, matching `Calendar.component(.weekday:)` on the client, and the
  -- midday offset keeps a bucket on its own calendar day for any UTC offset the
  -- product ships in.
  select coalesce(sum(oh.close_minutes - oh.open_minutes), 0)
  into v_hours_minutes
  from generate_series(p_start, p_end - interval '1 microsecond', interval '1 day') as bucket(starts)
  join salon_opening_hours oh
    on oh.salon_id = p_salon_id
   and oh.weekday  = extract(dow from bucket.starts + interval '12 hours')::integer + 1;

  v_capacity_minutes := coalesce(
    nullif(v_shift_minutes, 0),
    v_hours_minutes * greatest(v_professionals, 1)
  );

  -- ---------------------------------------------------------------------------
  -- Clients
  --
  -- A client is "returning" when this salon has seen them before the window,
  -- cancellations excluded on both sides — a booking that never happened is not
  -- a visit.
  -- ---------------------------------------------------------------------------

  select
    count(*),
    count(*) filter (where c.is_returning),
    count(*) filter (where not c.is_returning)
  into v_period_clients, v_returning_clients, v_new_clients
  from (
    select
      a.client_id,
      exists (
        select 1
        from appointments earlier
        where earlier.salon_id  = p_salon_id
          and earlier.client_id = a.client_id
          and earlier.starts_at < p_start
          and earlier.status not in ('cancelled_by_client', 'cancelled_by_salon')
      ) as is_returning
    from appointments a
    where a.salon_id  = p_salon_id
      and a.starts_at >= p_start
      and a.starts_at <  p_end
      and a.status not in ('cancelled_by_client', 'cancelled_by_salon')
    group by a.client_id
  ) c;

  -- ---------------------------------------------------------------------------
  -- Series and breakdowns
  -- ---------------------------------------------------------------------------

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'date',  to_char(bucket.starts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'value', coalesce(paid.amount, 0)
             )
             order by bucket.starts
           ),
           '[]'::jsonb
         )
  into v_series
  from generate_series(p_start, p_end - interval '1 microsecond', interval '1 day') as bucket(starts)
  left join lateral (
    select coalesce(sum(o.amount_paid), 0) as amount
    from orders o
    where o.salon_id = p_salon_id
      and o.paid_at is not null
      and o.paid_at >= bucket.starts
      and o.paid_at <  least(bucket.starts + interval '1 day', p_end)
  ) paid on true;

  select coalesce(
           jsonb_agg(jsonb_build_object('name', t.name, 'value', t.value) order by t.value desc),
           '[]'::jsonb
         )
  into v_by_service
  from (
    select ai.service_name as name, sum(ai.price_amount) as value
    from appointment_items ai
    join appointments a on a.id = ai.appointment_id
    where a.salon_id = p_salon_id
      and a.status = 'completed'
      and ai.starts_at >= p_start
      and ai.starts_at <  p_end
    group by ai.service_name
    order by sum(ai.price_amount) desc
    limit 10
  ) t;

  select coalesce(
           jsonb_agg(jsonb_build_object('name', t.name, 'value', t.value) order by t.value desc),
           '[]'::jsonb
         )
  into v_by_employee
  from (
    select coalesce(ai.professional_name, 'Unassigned') as name, sum(ai.price_amount) as value
    from appointment_items ai
    join appointments a on a.id = ai.appointment_id
    where a.salon_id = p_salon_id
      and a.status = 'completed'
      and ai.starts_at >= p_start
      and ai.starts_at <  p_end
    group by coalesce(ai.professional_name, 'Unassigned')
    order by sum(ai.price_amount) desc
    limit 10
  ) t;

  -- ---------------------------------------------------------------------------
  -- Result
  -- ---------------------------------------------------------------------------

  return jsonb_build_object(
    'salon_id',     p_salon_id,
    'period_start', to_char(p_start at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'period_end',   to_char(p_end   at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency',     v_currency,
    'revenue',          round(v_revenue, 2),
    'revenue_forecast', round(v_revenue + v_future_booked, 2),
    'appointment_count', v_appointments,
    'completed_count',   v_completed,
    'cancellation_rate', case
      when v_appointments = 0 then 0
      else round(v_cancelled::numeric / v_appointments, 4)
    end,
    'occupancy_rate', case
      when v_capacity_minutes is null or v_capacity_minutes = 0 then 0
      else least(round(v_booked_minutes / v_capacity_minutes, 4), 1)
    end,
    'new_client_count',       v_new_clients,
    'returning_client_count', v_returning_clients,
    'retention_rate', case
      when v_period_clients = 0 then 0
      else round(v_returning_clients::numeric / v_period_clients, 4)
    end,
    'average_ticket', case
      when v_paid_orders = 0 then 0
      else round(v_revenue / v_paid_orders, 2)
    end,
    'products_sold',    v_products_sold,
    'memberships_sold', v_memberships_sold,
    'revenue_series',      v_series,
    'revenue_by_service',  v_by_service,
    'revenue_by_employee', v_by_employee
  );
end;
$$;

comment on function public.salon_dashboard(uuid, timestamptz, timestamptz) is
  'One salon dashboard for a half-open window, as the JSON shape PRVModels.DashboardSnapshot decodes.';

-- -----------------------------------------------------------------------------
-- organization_dashboard
--
-- The multi-location comparison. Returns one snapshot per location of the brand
-- that the caller actually works at, ordered by name, so a regional manager sees
-- their region and an owner sees everything.
--
-- An organization id that matches nothing — including the owner id
-- `SalonDashboardModel` falls back to when a salon has no parent brand — yields
-- an empty array rather than an error, so the comparison card simply does not
-- appear.
-- -----------------------------------------------------------------------------

create or replace function public.organization_dashboard(
  p_organization_id uuid,
  p_start           timestamptz,
  p_end             timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  if p_organization_id is null or p_start is null or p_end is null or p_end <= p_start then
    raise exception 'organization_dashboard: an organization and an ordered half-open window are required'
      using errcode = 'PRV04';
  end if;

  -- Checked here as well as inside `salon_dashboard` so a caller without the
  -- permission is told so, rather than silently receiving an empty comparison.
  if not public.has_permission('viewReports') then
    raise exception 'organization_dashboard: not authorized to read reports'
      using errcode = 'PRV01';
  end if;

  -- `materialized` is load-bearing: it forces the membership filter to run to
  -- completion before `salon_dashboard` is called, so the inner function is
  -- never handed a salon it would refuse — which would fail the whole request
  -- instead of omitting one location.
  with visible as materialized (
    select s.id, s.name
    from salons s
    where s.organization_id = p_organization_id
      and public.is_salon_member(s.id)
  )
  select coalesce(
           jsonb_agg(public.salon_dashboard(v.id, p_start, p_end) order by v.name),
           '[]'::jsonb
         )
  into v_result
  from visible v;

  return v_result;
end;
$$;

comment on function public.organization_dashboard(uuid, timestamptz, timestamptz) is
  'One salon_dashboard per location of an organization that the caller is staff at.';

-- -----------------------------------------------------------------------------
-- Execute grants
--
-- Both functions run as the definer and authorize their own caller, so they are
-- callable by any signed-in user; `anon` has no salon membership and therefore
-- no report to read.
-- -----------------------------------------------------------------------------

revoke all on function public.salon_dashboard(uuid, timestamptz, timestamptz) from public;
revoke all on function public.organization_dashboard(uuid, timestamptz, timestamptz) from public;

grant execute on function public.salon_dashboard(uuid, timestamptz, timestamptz)
  to authenticated, service_role;
grant execute on function public.organization_dashboard(uuid, timestamptz, timestamptz)
  to authenticated, service_role;
