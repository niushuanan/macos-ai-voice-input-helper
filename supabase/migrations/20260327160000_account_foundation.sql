create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    auth_channel text not null check (auth_channel in ('email', 'phone')),
    contact_email text,
    edition text not null default 'professional' check (edition in ('free', 'member', 'professional')),
    account_status text not null default 'active' check (account_status in ('active', 'pending', 'disabled')),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    last_login_at timestamptz
);

create table if not exists public.user_devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    installation_id uuid not null,
    device_name text not null,
    platform text not null,
    app_version text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    last_seen_at timestamptz not null default timezone('utc', now()),
    unique (user_id, installation_id)
);

create table if not exists public.memberships (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    edition text not null check (edition in ('free', 'member', 'professional')),
    status text not null default 'active' check (status in ('pending', 'active', 'expired', 'cancelled')),
    source text not null default 'manual',
    starts_at timestamptz,
    ends_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.daily_usage_counters (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    edition text not null check (edition in ('free', 'member', 'professional')),
    counter_date date not null default current_date,
    counter_key text not null check (counter_key in ('dictation_chars', 'magician_actions')),
    used_count integer not null default 0 check (used_count >= 0),
    limit_count integer check (limit_count is null or limit_count >= 0),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    unique (user_id, counter_date, counter_key)
);

create or replace function public.set_current_timestamp_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = timezone('utc', now());
    return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
before update on public.profiles
for each row
execute function public.set_current_timestamp_updated_at();

drop trigger if exists set_user_devices_updated_at on public.user_devices;
create trigger set_user_devices_updated_at
before update on public.user_devices
for each row
execute function public.set_current_timestamp_updated_at();

drop trigger if exists set_memberships_updated_at on public.memberships;
create trigger set_memberships_updated_at
before update on public.memberships
for each row
execute function public.set_current_timestamp_updated_at();

drop trigger if exists set_daily_usage_counters_updated_at on public.daily_usage_counters;
create trigger set_daily_usage_counters_updated_at
before update on public.daily_usage_counters
for each row
execute function public.set_current_timestamp_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (
        id,
        auth_channel,
        contact_email,
        edition,
        account_status,
        created_at,
        updated_at,
        last_login_at
    )
    values (
        new.id,
        case
            when coalesce(new.phone, '') <> '' then 'phone'
            else 'email'
        end,
        new.email,
        'professional',
        'active',
        timezone('utc', now()),
        timezone('utc', now()),
        coalesce(new.last_sign_in_at, timezone('utc', now()))
    )
    on conflict (id) do update
    set
        auth_channel = excluded.auth_channel,
        contact_email = excluded.contact_email,
        last_login_at = excluded.last_login_at,
        updated_at = timezone('utc', now());

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_auth_user();

alter table public.profiles enable row level security;
alter table public.user_devices enable row level security;
alter table public.memberships enable row level security;
alter table public.daily_usage_counters enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles
for select
using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles
for update
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "user_devices_select_own" on public.user_devices;
create policy "user_devices_select_own"
on public.user_devices
for select
using (auth.uid() = user_id);

drop policy if exists "user_devices_insert_own" on public.user_devices;
create policy "user_devices_insert_own"
on public.user_devices
for insert
with check (auth.uid() = user_id);

drop policy if exists "user_devices_update_own" on public.user_devices;
create policy "user_devices_update_own"
on public.user_devices
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "memberships_select_own" on public.memberships;
create policy "memberships_select_own"
on public.memberships
for select
using (auth.uid() = user_id);

drop policy if exists "daily_usage_counters_select_own" on public.daily_usage_counters;
create policy "daily_usage_counters_select_own"
on public.daily_usage_counters
for select
using (auth.uid() = user_id);
