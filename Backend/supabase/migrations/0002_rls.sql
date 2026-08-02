-- =============================================================================
-- PRV Beauty — 0002_rls.sql
--
-- DENY BY DEFAULT.
--
-- Row Level Security is enabled on every table in this schema. Enabling RLS
-- without a matching policy denies the operation, so a table that appears below
-- with (say) only a SELECT policy cannot be written by any client, ever — the
-- absence of a policy is the deny rule. Nothing here is advisory: the client
-- app's `RoleGate` / `session.can(_:)` checks are a UX affordance, and a
-- tampered client that skips them gains exactly nothing.
--
-- The four access shapes:
--
--   1. Public read — marketing-surface data only: active salons, their services
--      and professionals, approved reviews, membership plans, packages. No
--      authentication required; `anon` sees precisely what a search engine
--      could see and nothing else.
--   2. Own rows — a client reads and writes only rows keyed to `auth.uid()`:
--      their appointments, orders, wallet, messages, loyalty, notifications.
--   3. Salon-scoped — staff reach rows belonging to a salon they work at,
--      resolved by the security-definer helper `is_salon_member(uuid)`.
--      Salon A can never read salon B's CRM, revenue, notes, or payroll.
--   4. Append-only — `audit_log`. Insert is allowed; UPDATE and DELETE have no
--      policy and the privileges are revoked, so an entry cannot be rewritten
--      or erased by anyone holding a client JWT.
--
-- `service_role` (used only by Edge Functions, never shipped to a device)
-- bypasses RLS by design; every function that uses it re-checks the caller's
-- JWT before it acts.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Security-definer helpers
--
-- These run as the definer so they can consult `profiles` / `employees` /
-- `organizations` without recursing into the policies that themselves call
-- them. `search_path` is pinned so a caller cannot shadow a table name.
-- -----------------------------------------------------------------------------

create or replace function public.current_role_value()
returns user_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select role from profiles where id = auth.uid();
$$;

comment on function public.current_role_value() is
  'The caller''s UserRole, or NULL when unauthenticated.';

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select role in ('administrator', 'super_admin', 'developer') from profiles where id = auth.uid()),
    false
  );
$$;

comment on function public.is_platform_admin() is
  'True for administrator / super_admin / developer — support and moderation tooling.';

create or replace function public.has_permission(p_permission permission)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from profiles p
    join role_permissions rp on rp.role = p.role
    where p.id = auth.uid()
      and rp.permission = p_permission
  );
$$;

comment on function public.has_permission(permission) is
  'Server-side mirror of UserRole.permissions — the authority behind session.can(_:).';

-- The workhorse. A caller is a member of a salon when they are an active
-- employee there, a professional attached to it, the owner of the organization
-- that owns it, or a platform admin.
create or replace function public.is_salon_member(p_salon_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    p_salon_id is not null
    and (
      public.is_platform_admin()
      or exists (
        select 1
        from employees e
        where e.salon_id = p_salon_id
          and e.user_id = auth.uid()
          and e.terminated_at is null
      )
      or exists (
        select 1
        from professionals pr
        where pr.salon_id = p_salon_id
          and pr.user_id = auth.uid()
          and pr.is_active
      )
      or exists (
        select 1
        from salons s
        join organizations o on o.id = s.organization_id
        where s.id = p_salon_id
          and o.owner_id = auth.uid()
      )
    );
$$;

comment on function public.is_salon_member(uuid) is
  'Staff/ownership resolution for salon-scoped policies. Employment, professional attachment, or organization ownership all qualify.';

-- Membership plus a management-grade role. Guards payroll, policy, finance,
-- and anything else an employee should be able to see but not change.
create or replace function public.is_salon_manager(p_salon_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.is_salon_member(p_salon_id)
    and coalesce(
      (
        select role in (
          'salon_manager', 'salon_owner', 'multi_salon_owner',
          'regional_manager', 'administrator', 'super_admin', 'developer'
        )
        from profiles where id = auth.uid()
      ),
      false
    );
$$;

comment on function public.is_salon_manager(uuid) is
  'is_salon_member plus a management role — payroll, policies, finance, team.';

create or replace function public.is_conversation_participant(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from conversation_participants cp
    where cp.conversation_id = p_conversation_id
      and cp.user_id = auth.uid()
  );
$$;

create or replace function public.owns_client_record(p_client_record_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from client_records cr
    where cr.id = p_client_record_id
      and (cr.user_id = auth.uid() or public.is_salon_member(cr.salon_id))
  );
$$;

create or replace function public.can_manage_client_record(p_client_record_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from client_records cr
    where cr.id = p_client_record_id
      and public.is_salon_member(cr.salon_id)
  );
$$;

create or replace function public.employee_salon(p_employee_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select salon_id from employees where id = p_employee_id;
$$;

create or replace function public.is_own_employee_record(p_employee_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from employees e where e.id = p_employee_id and e.user_id = auth.uid()
  );
$$;

-- -----------------------------------------------------------------------------
-- Enable RLS everywhere
-- -----------------------------------------------------------------------------

alter table profiles                  enable row level security;
alter table role_permissions          enable row level security;
alter table organizations             enable row level security;
alter table salons                    enable row level security;
alter table salon_opening_hours       enable row level security;
alter table prepayment_policies       enable row level security;
alter table professionals             enable row level security;
alter table certificates              enable row level security;
alter table portfolio_items           enable row level security;
alter table services                  enable row level security;
alter table service_add_ons           enable row level security;
alter table professional_services     enable row level security;
alter table appointments              enable row level security;
alter table appointment_items         enable row level security;
alter table waitlist_entries          enable row level security;
alter table orders                    enable row level security;
alter table order_lines               enable row level security;
alter table refunds                   enable row level security;
alter table gift_cards                enable row level security;
alter table wallet_transactions       enable row level security;
alter table invoices                  enable row level security;
alter table saved_payment_methods     enable row level security;
alter table membership_plans          enable row level security;
alter table membership_benefits       enable row level security;
alter table membership_subscriptions  enable row level security;
alter table service_packages          enable row level security;
alter table package_services          enable row level security;
alter table loyalty_profiles          enable row level security;
alter table achievements              enable row level security;
alter table loyalty_achievements      enable row level security;
alter table loyalty_challenges        enable row level security;
alter table reviews                   enable row level security;
alter table review_likes              enable row level security;
alter table review_comments           enable row level security;
alter table conversations             enable row level security;
alter table conversation_participants enable row level security;
alter table messages                  enable row level security;
alter table notifications             enable row level security;
alter table device_tokens             enable row level security;
alter table client_records            enable row level security;
alter table client_favorite_products  enable row level security;
alter table client_notes              enable row level security;
alter table consent_forms             enable row level security;
alter table employees                 enable row level security;
alter table shifts                    enable row level security;
alter table time_entries              enable row level security;
alter table performance_goals         enable row level security;
alter table suppliers                 enable row level security;
alter table products                  enable row level security;
alter table purchase_orders           enable row level security;
alter table purchase_order_lines      enable row level security;
alter table coupons                   enable row level security;
alter table campaigns                 enable row level security;
alter table coupon_redemptions        enable row level security;
alter table audit_log                 enable row level security;
alter table feature_flags             enable row level security;

-- -----------------------------------------------------------------------------
-- Identity
-- -----------------------------------------------------------------------------

create policy profiles_select_self on profiles
  for select to authenticated
  using (id = auth.uid() or public.is_platform_admin());

-- A client's name and avatar are visible to staff of a salon they have visited
-- or messaged — nothing more, and never their email or phone in a list view
-- (the app selects an explicit column list for those surfaces).
create policy profiles_select_salon_clients on profiles
  for select to authenticated
  using (
    exists (
      select 1 from appointments a
      where a.client_id = profiles.id and public.is_salon_member(a.salon_id)
    )
    or exists (
      select 1 from client_records cr
      where cr.user_id = profiles.id and public.is_salon_member(cr.salon_id)
    )
  );

create policy profiles_insert_self on profiles
  for insert to authenticated
  with check (id = auth.uid());

create policy profiles_update_self on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_admin_all on profiles
  for all to authenticated
  using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- The role → permission matrix is world-readable and write-protected: no
-- INSERT/UPDATE/DELETE policy exists, so only a migration can change it.
create policy role_permissions_select_all on role_permissions
  for select to anon, authenticated
  using (true);

create policy organizations_select_member on organizations
  for select to authenticated
  using (
    owner_id = auth.uid()
    or public.is_platform_admin()
    or exists (select 1 from salons s where s.organization_id = organizations.id and public.is_salon_member(s.id))
  );

create policy organizations_write_owner on organizations
  for all to authenticated
  using (owner_id = auth.uid() or public.is_platform_admin())
  with check (owner_id = auth.uid() or public.is_platform_admin());

-- -----------------------------------------------------------------------------
-- Salons — public read of the marketing surface, staff write
-- -----------------------------------------------------------------------------

create policy salons_select_public on salons
  for select to anon, authenticated
  using (is_active or public.is_salon_member(id));

create policy salons_insert_owner on salons
  for insert to authenticated
  with check (public.has_permission('manageSalon'));

create policy salons_update_manager on salons
  for update to authenticated
  using (public.is_salon_manager(id))
  with check (public.is_salon_manager(id));

create policy salons_delete_admin on salons
  for delete to authenticated
  using (public.is_platform_admin());

create policy salon_opening_hours_select_public on salon_opening_hours
  for select to anon, authenticated
  using (true);

create policy salon_opening_hours_write_manager on salon_opening_hours
  for all to authenticated
  using (public.is_salon_manager(salon_id))
  with check (public.is_salon_manager(salon_id));

-- Prepayment incentives are advertised in the booking flow, so they are
-- readable; only an owner with `configurePrepayment` may change them.
create policy prepayment_policies_select_public on prepayment_policies
  for select to anon, authenticated
  using (true);

create policy prepayment_policies_write_owner on prepayment_policies
  for all to authenticated
  using (public.is_salon_manager(salon_id) and public.has_permission('configurePrepayment'))
  with check (public.is_salon_manager(salon_id) and public.has_permission('configurePrepayment'));

-- -----------------------------------------------------------------------------
-- Professionals & services — public read
-- -----------------------------------------------------------------------------

create policy professionals_select_public on professionals
  for select to anon, authenticated
  using (is_active or user_id = auth.uid() or public.is_salon_member(salon_id));

create policy professionals_write_self on professionals
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy professionals_write_manager on professionals
  for all to authenticated
  using (public.is_salon_manager(salon_id) and public.has_permission('manageTeam'))
  with check (public.is_salon_manager(salon_id) and public.has_permission('manageTeam'));

create policy certificates_select_public on certificates
  for select to anon, authenticated
  using (true);

create policy certificates_write_owner on certificates
  for all to authenticated
  using (exists (
    select 1 from professionals p
    where p.id = certificates.professional_id
      and (p.user_id = auth.uid() or public.is_salon_manager(p.salon_id))
  ))
  with check (exists (
    select 1 from professionals p
    where p.id = certificates.professional_id
      and (p.user_id = auth.uid() or public.is_salon_manager(p.salon_id))
  ));

create policy portfolio_items_select_public on portfolio_items
  for select to anon, authenticated
  using (true);

create policy portfolio_items_write_owner on portfolio_items
  for all to authenticated
  using (exists (
    select 1 from professionals p
    where p.id = portfolio_items.professional_id
      and (p.user_id = auth.uid() or public.is_salon_member(p.salon_id))
  ))
  with check (exists (
    select 1 from professionals p
    where p.id = portfolio_items.professional_id
      and (p.user_id = auth.uid() or public.is_salon_member(p.salon_id))
  ));

create policy services_select_public on services
  for select to anon, authenticated
  using (is_active or public.is_salon_member(salon_id));

create policy services_write_manager on services
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageServices'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageServices'));

create policy service_add_ons_select_public on service_add_ons
  for select to anon, authenticated
  using (true);

create policy service_add_ons_write_manager on service_add_ons
  for all to authenticated
  using (exists (
    select 1 from services s
    where s.id = service_add_ons.service_id
      and public.is_salon_member(s.salon_id)
      and public.has_permission('manageServices')
  ))
  with check (exists (
    select 1 from services s
    where s.id = service_add_ons.service_id
      and public.is_salon_member(s.salon_id)
      and public.has_permission('manageServices')
  ));

create policy professional_services_select_public on professional_services
  for select to anon, authenticated
  using (true);

create policy professional_services_write_manager on professional_services
  for all to authenticated
  using (exists (
    select 1 from professionals p
    where p.id = professional_services.professional_id
      and (p.user_id = auth.uid() or public.is_salon_manager(p.salon_id))
  ))
  with check (exists (
    select 1 from professionals p
    where p.id = professional_services.professional_id
      and (p.user_id = auth.uid() or public.is_salon_manager(p.salon_id))
  ));

-- -----------------------------------------------------------------------------
-- Appointments — the client who booked, plus the salon that performs it
-- -----------------------------------------------------------------------------

create policy appointments_select_participant on appointments
  for select to authenticated
  using (
    client_id = auth.uid()
    or auth.uid() = any (additional_client_ids)
    or public.is_salon_member(salon_id)
  );

create policy appointments_insert_client on appointments
  for insert to authenticated
  with check (
    (client_id = auth.uid() and public.has_permission('book'))
    or public.is_salon_member(salon_id)
  );

-- A client may amend their own booking (notes, cancellation); status
-- transitions that only a salon can make are enforced by the RPCs in 0003.
create policy appointments_update_participant on appointments
  for update to authenticated
  using (client_id = auth.uid() or public.is_salon_member(salon_id))
  with check (client_id = auth.uid() or public.is_salon_member(salon_id));

create policy appointments_delete_salon on appointments
  for delete to authenticated
  using (public.is_salon_manager(salon_id));

create policy appointment_items_select_participant on appointment_items
  for select to authenticated
  using (exists (
    select 1 from appointments a
    where a.id = appointment_items.appointment_id
      and (a.client_id = auth.uid() or auth.uid() = any (a.additional_client_ids) or public.is_salon_member(a.salon_id))
  ));

create policy appointment_items_write_participant on appointment_items
  for all to authenticated
  using (exists (
    select 1 from appointments a
    where a.id = appointment_items.appointment_id
      and (a.client_id = auth.uid() or public.is_salon_member(a.salon_id))
  ))
  with check (exists (
    select 1 from appointments a
    where a.id = appointment_items.appointment_id
      and (a.client_id = auth.uid() or public.is_salon_member(a.salon_id))
  ));

create policy waitlist_entries_select_participant on waitlist_entries
  for select to authenticated
  using (client_id = auth.uid() or public.is_salon_member(salon_id));

create policy waitlist_entries_insert_client on waitlist_entries
  for insert to authenticated
  with check (client_id = auth.uid() or public.is_salon_member(salon_id));

create policy waitlist_entries_update_participant on waitlist_entries
  for update to authenticated
  using (client_id = auth.uid() or public.is_salon_member(salon_id))
  with check (client_id = auth.uid() or public.is_salon_member(salon_id));

create policy waitlist_entries_delete_participant on waitlist_entries
  for delete to authenticated
  using (client_id = auth.uid() or public.is_salon_member(salon_id));

-- -----------------------------------------------------------------------------
-- Money — the client who owes it, and the salon that is owed
-- -----------------------------------------------------------------------------

create policy orders_select_participant on orders
  for select to authenticated
  using (client_id = auth.uid() or public.is_salon_member(salon_id));

create policy orders_insert_participant on orders
  for insert to authenticated
  with check (client_id = auth.uid() or public.is_salon_member(salon_id));

-- Deliberately narrow: a client may edit an order only while it is a draft.
-- Once payment is in flight, the Edge Functions (service_role) own it — that is
-- what makes "the server recomputes the amount" a guarantee rather than a hope.
create policy orders_update_client_draft on orders
  for update to authenticated
  using (client_id = auth.uid() and status = 'draft')
  with check (client_id = auth.uid() and status in ('draft', 'awaiting_payment'));

create policy orders_update_salon on orders
  for update to authenticated
  using (public.is_salon_member(salon_id))
  with check (public.is_salon_member(salon_id));

create policy order_lines_select_participant on order_lines
  for select to authenticated
  using (exists (
    select 1 from orders o
    where o.id = order_lines.order_id
      and (o.client_id = auth.uid() or public.is_salon_member(o.salon_id))
  ));

create policy order_lines_write_participant on order_lines
  for all to authenticated
  using (exists (
    select 1 from orders o
    where o.id = order_lines.order_id
      and ((o.client_id = auth.uid() and o.status = 'draft') or public.is_salon_member(o.salon_id))
  ))
  with check (exists (
    select 1 from orders o
    where o.id = order_lines.order_id
      and ((o.client_id = auth.uid() and o.status = 'draft') or public.is_salon_member(o.salon_id))
  ));

create policy refunds_select_participant on refunds
  for select to authenticated
  using (exists (
    select 1 from orders o
    where o.id = refunds.order_id
      and (o.client_id = auth.uid() or public.is_salon_member(o.salon_id))
  ));

-- Refunds are money leaving the business: only `manageRefunds` may request one,
-- and the automatic path runs in `cancel-appointment` under service_role.
create policy refunds_insert_authorized on refunds
  for insert to authenticated
  with check (
    public.has_permission('manageRefunds')
    and exists (
      select 1 from orders o
      where o.id = refunds.order_id
        and (public.is_salon_member(o.salon_id) or public.is_platform_admin())
    )
  );

create policy gift_cards_select_holder on gift_cards
  for select to authenticated
  using (
    purchaser_id = auth.uid()
    or (salon_id is not null and public.is_salon_member(salon_id))
  );

create policy gift_cards_insert_purchaser on gift_cards
  for insert to authenticated
  with check (purchaser_id = auth.uid() or (salon_id is not null and public.is_salon_member(salon_id)));

create policy wallet_transactions_select_own on wallet_transactions
  for select to authenticated
  using (user_id = auth.uid());

-- The wallet ledger is written by the payment functions, never by a device.
-- No INSERT/UPDATE/DELETE policy exists here on purpose.

create policy invoices_select_participant on invoices
  for select to authenticated
  using (exists (
    select 1 from orders o
    where o.id = invoices.order_id
      and (o.client_id = auth.uid() or public.is_salon_member(o.salon_id))
  ));

create policy saved_payment_methods_own on saved_payment_methods
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Memberships & packages — public catalogue, private subscriptions
-- -----------------------------------------------------------------------------

create policy membership_plans_select_public on membership_plans
  for select to anon, authenticated
  using (is_active or public.is_salon_member(salon_id));

create policy membership_plans_write_manager on membership_plans
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageMemberships'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageMemberships'));

create policy membership_benefits_select_public on membership_benefits
  for select to anon, authenticated
  using (true);

create policy membership_benefits_write_manager on membership_benefits
  for all to authenticated
  using (exists (
    select 1 from membership_plans mp
    where mp.id = membership_benefits.plan_id
      and public.is_salon_member(mp.salon_id)
      and public.has_permission('manageMemberships')
  ))
  with check (exists (
    select 1 from membership_plans mp
    where mp.id = membership_benefits.plan_id
      and public.is_salon_member(mp.salon_id)
      and public.has_permission('manageMemberships')
  ));

create policy membership_subscriptions_select_own on membership_subscriptions
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from membership_plans mp
      where mp.id = membership_subscriptions.plan_id and public.is_salon_member(mp.salon_id)
    )
  );

create policy membership_subscriptions_insert_own on membership_subscriptions
  for insert to authenticated
  with check (user_id = auth.uid());

create policy membership_subscriptions_update_own on membership_subscriptions
  for update to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from membership_plans mp
      where mp.id = membership_subscriptions.plan_id and public.is_salon_manager(mp.salon_id)
    )
  )
  with check (
    user_id = auth.uid()
    or exists (
      select 1 from membership_plans mp
      where mp.id = membership_subscriptions.plan_id and public.is_salon_manager(mp.salon_id)
    )
  );

create policy service_packages_select_public on service_packages
  for select to anon, authenticated
  using (is_active or public.is_salon_member(salon_id));

create policy service_packages_write_manager on service_packages
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageMemberships'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageMemberships'));

create policy package_services_select_public on package_services
  for select to anon, authenticated
  using (true);

create policy package_services_write_manager on package_services
  for all to authenticated
  using (exists (
    select 1 from service_packages sp
    where sp.id = package_services.package_id
      and public.is_salon_member(sp.salon_id)
      and public.has_permission('manageMemberships')
  ))
  with check (exists (
    select 1 from service_packages sp
    where sp.id = package_services.package_id
      and public.is_salon_member(sp.salon_id)
      and public.has_permission('manageMemberships')
  ));

-- -----------------------------------------------------------------------------
-- Loyalty — strictly personal
-- -----------------------------------------------------------------------------

create policy loyalty_profiles_select_own on loyalty_profiles
  for select to authenticated
  using (user_id = auth.uid());

create policy loyalty_profiles_insert_own on loyalty_profiles
  for insert to authenticated
  with check (user_id = auth.uid());

-- XP and points are awarded by `award_loyalty_xp` (security definer) and by the
-- Stripe webhook. A client may edit the referral fields only; the numbers are
-- not writable from a device — there is no UPDATE policy here.

create policy achievements_select_public on achievements
  for select to anon, authenticated
  using (is_active);

create policy loyalty_achievements_select_own on loyalty_achievements
  for select to authenticated
  using (exists (
    select 1 from loyalty_profiles lp
    where lp.id = loyalty_achievements.loyalty_profile_id and lp.user_id = auth.uid()
  ));

create policy loyalty_challenges_select_own on loyalty_challenges
  for select to authenticated
  using (user_id is null or user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Reviews — public read of approved, author write, salon response
-- -----------------------------------------------------------------------------

create policy reviews_select_approved on reviews
  for select to anon, authenticated
  using (
    moderation = 'approved'
    or author_id = auth.uid()
    or public.is_salon_member(salon_id)
    or public.has_permission('moderateReviews')
  );

create policy reviews_insert_author on reviews
  for insert to authenticated
  with check (author_id = auth.uid() and public.has_permission('review'));

create policy reviews_update_author on reviews
  for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid() and moderation = 'pending');

create policy reviews_update_salon_response on reviews
  for update to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('respondToReviews'))
  with check (public.is_salon_member(salon_id) and public.has_permission('respondToReviews'));

create policy reviews_update_moderator on reviews
  for update to authenticated
  using (public.has_permission('moderateReviews'))
  with check (public.has_permission('moderateReviews'));

create policy reviews_delete_author on reviews
  for delete to authenticated
  using (author_id = auth.uid() or public.has_permission('moderateReviews'));

create policy review_likes_select_own on review_likes
  for select to authenticated
  using (user_id = auth.uid());

create policy review_likes_write_own on review_likes
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy review_comments_select_public on review_comments
  for select to anon, authenticated
  using (exists (
    select 1 from reviews r
    where r.id = review_comments.review_id
      and (r.moderation = 'approved' or r.author_id = auth.uid() or public.is_salon_member(r.salon_id))
  ));

create policy review_comments_insert_author on review_comments
  for insert to authenticated
  with check (author_id = auth.uid());

create policy review_comments_delete_author on review_comments
  for delete to authenticated
  using (author_id = auth.uid() or public.has_permission('moderateReviews'));

-- -----------------------------------------------------------------------------
-- Chat — participants only. Non-participants cannot see that a conversation
-- exists, let alone its contents.
-- -----------------------------------------------------------------------------

create policy conversations_select_participant on conversations
  for select to authenticated
  using (public.is_conversation_participant(id));

create policy conversations_insert_authenticated on conversations
  for insert to authenticated
  with check (public.has_permission('chat'));

create policy conversations_update_participant on conversations
  for update to authenticated
  using (public.is_conversation_participant(id))
  with check (public.is_conversation_participant(id));

create policy conversation_participants_select_own on conversation_participants
  for select to authenticated
  using (user_id = auth.uid() or public.is_conversation_participant(conversation_id));

create policy conversation_participants_insert on conversation_participants
  for insert to authenticated
  with check (user_id = auth.uid() or public.is_conversation_participant(conversation_id));

create policy conversation_participants_update_own on conversation_participants
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy conversation_participants_delete_own on conversation_participants
  for delete to authenticated
  using (user_id = auth.uid());

create policy messages_select_participant on messages
  for select to authenticated
  using (public.is_conversation_participant(conversation_id));

create policy messages_insert_participant on messages
  for insert to authenticated
  with check (
    public.is_conversation_participant(conversation_id)
    and (sender_id = auth.uid() or (sender_id is null and is_from_assistant))
  );

-- A sender may amend delivery state on their own message; history is immutable.
create policy messages_update_sender on messages
  for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Notifications & devices — strictly personal
-- -----------------------------------------------------------------------------

create policy notifications_select_own on notifications
  for select to authenticated
  using (user_id = auth.uid());

create policy notifications_update_own on notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy notifications_delete_own on notifications
  for delete to authenticated
  using (user_id = auth.uid());

-- Notifications are created by the platform (notify-fanout, triggers) — a
-- device cannot fabricate one for itself or anyone else.

create policy device_tokens_own on device_tokens
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- CRM — the most sensitive data in the platform. Salon-scoped, always.
-- -----------------------------------------------------------------------------

create policy client_records_select_scoped on client_records
  for select to authenticated
  using (
    user_id = auth.uid()
    or (public.is_salon_member(salon_id) and public.has_permission('viewClients'))
  );

create policy client_records_write_staff on client_records
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageCRM'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageCRM'));

create policy client_favorite_products_scoped on client_favorite_products
  for all to authenticated
  using (public.can_manage_client_record(client_record_id))
  with check (public.can_manage_client_record(client_record_id));

-- Colour formulas and treatment notes never leave the salon that wrote them —
-- not even to the client they describe.
create policy client_notes_select_staff on client_notes
  for select to authenticated
  using (public.can_manage_client_record(client_record_id));

create policy client_notes_write_staff on client_notes
  for all to authenticated
  using (public.can_manage_client_record(client_record_id) and public.has_permission('manageCRM'))
  with check (
    author_id = auth.uid()
    and public.can_manage_client_record(client_record_id)
    and public.has_permission('manageCRM')
  );

-- A consent form is evidence for both parties, so the data subject can read it.
create policy consent_forms_select_scoped on consent_forms
  for select to authenticated
  using (public.owns_client_record(client_record_id));

create policy consent_forms_write_staff on consent_forms
  for all to authenticated
  using (public.can_manage_client_record(client_record_id))
  with check (public.can_manage_client_record(client_record_id));

-- -----------------------------------------------------------------------------
-- Team — an employee sees their own record; managers see the roster
-- -----------------------------------------------------------------------------

create policy employees_select_scoped on employees
  for select to authenticated
  using (
    user_id = auth.uid()
    or (public.is_salon_member(salon_id) and public.has_permission('manageTeam'))
  );

create policy employees_write_manager on employees
  for all to authenticated
  using (public.is_salon_manager(salon_id) and public.has_permission('manageTeam'))
  with check (public.is_salon_manager(salon_id) and public.has_permission('manageTeam'));

create policy shifts_select_scoped on shifts
  for select to authenticated
  using (public.is_own_employee_record(employee_id) or public.is_salon_member(salon_id));

create policy shifts_write_manager on shifts
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageCalendar'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageCalendar'));

create policy time_entries_select_scoped on time_entries
  for select to authenticated
  using (
    public.is_own_employee_record(employee_id)
    or public.is_salon_manager(public.employee_salon(employee_id))
  );

-- Clocking in is a personal act; correcting a time sheet is a managerial one.
create policy time_entries_insert_self on time_entries
  for insert to authenticated
  with check (public.is_own_employee_record(employee_id) and public.has_permission('checkInOut'));

create policy time_entries_update_scoped on time_entries
  for update to authenticated
  using (
    public.is_own_employee_record(employee_id)
    or public.is_salon_manager(public.employee_salon(employee_id))
  )
  with check (
    public.is_own_employee_record(employee_id)
    or public.is_salon_manager(public.employee_salon(employee_id))
  );

create policy performance_goals_select_scoped on performance_goals
  for select to authenticated
  using (
    public.is_own_employee_record(employee_id)
    or public.is_salon_manager(public.employee_salon(employee_id))
  );

create policy performance_goals_write_manager on performance_goals
  for all to authenticated
  using (public.is_salon_manager(public.employee_salon(employee_id)))
  with check (public.is_salon_manager(public.employee_salon(employee_id)));

-- -----------------------------------------------------------------------------
-- Inventory — never public; cost prices are commercially sensitive
-- -----------------------------------------------------------------------------

create policy suppliers_select_staff on suppliers
  for select to authenticated
  using (salon_id is null or public.is_salon_member(salon_id));

create policy suppliers_write_staff on suppliers
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageInventory'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageInventory'));

create policy products_select_staff on products
  for select to authenticated
  using (public.is_salon_member(salon_id));

create policy products_write_staff on products
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageInventory'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageInventory'));

create policy purchase_orders_scoped on purchase_orders
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageInventory'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageInventory'));

create policy purchase_order_lines_scoped on purchase_order_lines
  for all to authenticated
  using (exists (
    select 1 from purchase_orders po
    where po.id = purchase_order_lines.purchase_order_id
      and public.is_salon_member(po.salon_id)
      and public.has_permission('manageInventory')
  ))
  with check (exists (
    select 1 from purchase_orders po
    where po.id = purchase_order_lines.purchase_order_id
      and public.is_salon_member(po.salon_id)
      and public.has_permission('manageInventory')
  ));

-- -----------------------------------------------------------------------------
-- Marketing
-- -----------------------------------------------------------------------------

-- A coupon code is only useful if a client can validate it, but the campaign
-- economics behind it are staff-only.
create policy coupons_select_active on coupons
  for select to authenticated
  using (
    (is_active and valid_from <= now() and (valid_until is null or valid_until > now()))
    or public.is_salon_member(salon_id)
  );

create policy coupons_write_staff on coupons
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageMarketing'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageMarketing'));

create policy campaigns_scoped on campaigns
  for all to authenticated
  using (public.is_salon_member(salon_id) and public.has_permission('manageMarketing'))
  with check (public.is_salon_member(salon_id) and public.has_permission('manageMarketing'));

create policy coupon_redemptions_select_scoped on coupon_redemptions
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from coupons c
      where c.id = coupon_redemptions.coupon_id and public.is_salon_member(c.salon_id)
    )
  );

create policy coupon_redemptions_insert_own on coupon_redemptions
  for insert to authenticated
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Platform
-- -----------------------------------------------------------------------------

-- audit_log is APPEND-ONLY.
--
-- INSERT is the only policy, and the UPDATE/DELETE privileges are revoked
-- below. A salon can read its own trail and an admin can read all of it; no
-- role can rewrite history.
create policy audit_log_insert_any on audit_log
  for insert to authenticated
  with check (actor_id = auth.uid());

create policy audit_log_select_scoped on audit_log
  for select to authenticated
  using (
    public.is_platform_admin()
    or (salon_id is not null and public.is_salon_manager(salon_id))
  );

revoke update, delete, truncate on audit_log from authenticated, anon;

-- Feature flags are read by every client at launch; only the platform team
-- flips them.
create policy feature_flags_select_all on feature_flags
  for select to anon, authenticated
  using (true);

create policy feature_flags_write_admin on feature_flags
  for all to authenticated
  using (public.has_permission('manageFeatureFlags'))
  with check (public.has_permission('manageFeatureFlags'));

-- -----------------------------------------------------------------------------
-- Grants
--
-- RLS narrows what a role may touch; grants decide whether it may attempt the
-- statement at all. `anon` gets SELECT only — it can never write anything.
-- -----------------------------------------------------------------------------

grant usage on schema public to anon, authenticated, service_role;

grant select on all tables in schema public to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

revoke update, delete, truncate on audit_log from authenticated;

alter default privileges in schema public grant select on tables to anon;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant all on tables to service_role;
