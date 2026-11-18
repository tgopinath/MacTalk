-- MacTalk database schema
-- Tables, indexes, Row Level Security and the server-side functions that enforce
-- every security rule (friendship-gated calling, blocking, rate limits, expiry).
-- Clients never write to friend_requests / friendships / calls directly: all
-- state changes go through SECURITY DEFINER functions below.

create extension if not exists citext with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.users (
    id                uuid primary key references auth.users (id) on delete cascade,
    email             extensions.citext not null unique,
    display_name      text check (display_name is null or char_length(display_name) between 1 and 40),
    avatar_url        text check (avatar_url is null or char_length(avatar_url) <= 512),
    presence_status   text not null default 'offline'
                      check (presence_status in ('online', 'offline', 'busy', 'dnd', 'in_call')),
    manual_status     text not null default 'online'
                      check (manual_status in ('online', 'busy', 'dnd')),
    profile_completed boolean not null default false,
    last_seen         timestamptz,
    created_at        timestamptz not null default now()
);

create table public.friend_requests (
    id                 uuid primary key default gen_random_uuid(),
    sender_id          uuid not null references public.users (id) on delete cascade,
    receiver_id        uuid not null references public.users (id) on delete cascade,
    status             text not null default 'pending'
                       check (status in ('pending', 'accepted', 'declined', 'cancelled')),
    last_email_sent_at timestamptz,
    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now(),
    check (sender_id <> receiver_id)
);
-- Only one open request per pair of people, in either direction.
create unique index friend_requests_one_pending_per_pair
    on public.friend_requests (least(sender_id, receiver_id), greatest(sender_id, receiver_id))
    where status = 'pending';
create index friend_requests_receiver_idx on public.friend_requests (receiver_id, status);
create index friend_requests_sender_idx on public.friend_requests (sender_id, status);

-- Two rows per friendship (one per direction) so each user can select their own list cheaply.
create table public.friendships (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.users (id) on delete cascade,
    friend_id  uuid not null references public.users (id) on delete cascade,
    status     text not null default 'accepted' check (status in ('accepted')),
    created_at timestamptz not null default now(),
    unique (user_id, friend_id),
    check (user_id <> friend_id)
);
create index friendships_friend_idx on public.friendships (friend_id);

create table public.blocked_users (
    id              uuid primary key default gen_random_uuid(),
    blocker_id      uuid not null references public.users (id) on delete cascade,
    blocked_user_id uuid not null references public.users (id) on delete cascade,
    created_at      timestamptz not null default now(),
    unique (blocker_id, blocked_user_id),
    check (blocker_id <> blocked_user_id)
);
create index blocked_users_blocked_idx on public.blocked_users (blocked_user_id);

create table public.calls (
    id           uuid primary key default gen_random_uuid(),
    caller_id    uuid not null references public.users (id) on delete cascade,
    receiver_id  uuid not null references public.users (id) on delete cascade,
    status       text not null default 'ringing'
                 check (status in ('ringing', 'accepted', 'connecting', 'connected',
                                   'declined', 'missed', 'busy', 'cancelled', 'ended', 'failed')),
    end_reason   text,
    created_at   timestamptz not null default now(),
    expires_at   timestamptz not null default now() + interval '45 seconds',
    started_at   timestamptz,          -- media connected
    accepted_at  timestamptz,
    ended_at     timestamptz,
    duration     integer,               -- seconds of connected audio
    check (caller_id <> receiver_id)
);
create index calls_caller_idx on public.calls (caller_id, created_at desc);
create index calls_receiver_idx on public.calls (receiver_id, created_at desc);
create index calls_active_idx on public.calls (status)
    where status in ('ringing', 'accepted', 'connecting', 'connected');

-- WebRTC signaling (SDP offer/answer, ICE candidates). Rows are only insertable by
-- the two participants of an accepted call; delivered through Supabase Realtime.
create table public.call_signals (
    id           bigint generated always as identity primary key,
    call_id      uuid not null references public.calls (id) on delete cascade,
    sender_id    uuid not null references public.users (id) on delete cascade,
    recipient_id uuid not null references public.users (id) on delete cascade,
    kind         text not null check (kind in ('offer', 'answer', 'ice', 'restart', 'bye')),
    payload      jsonb not null default '{}'::jsonb check (octet_length(payload::text) <= 16384),
    created_at   timestamptz not null default now()
);
create index call_signals_call_idx on public.call_signals (call_id, id);

create table public.rate_limits (
    user_id      uuid not null references public.users (id) on delete cascade,
    action       text not null,
    window_start timestamptz not null,
    hits         integer not null,
    primary key (user_id, action)
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_verified(uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from auth.users u where u.id = uid and u.email_confirmed_at is not null);
$$;

create or replace function public.require_verified()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
    if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
    if not public.is_verified(uid) then raise exception 'email_not_verified' using errcode = '28000'; end if;
    return uid;
end $$;

create or replace function public.hit_rate_limit(p_action text, p_max integer, p_window_seconds integer)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.rate_limits;
begin
    insert into public.rate_limits as rl (user_id, action, window_start, hits)
    values (uid, p_action, now(), 1)
    on conflict (user_id, action) do update set
        hits = case when rl.window_start < now() - make_interval(secs => p_window_seconds) then 1 else rl.hits + 1 end,
        window_start = case when rl.window_start < now() - make_interval(secs => p_window_seconds) then now() else rl.window_start end
    returning * into r;
    if r.hits > p_max then raise exception 'rate_limited' using errcode = 'P0001'; end if;
end $$;

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.friendships where user_id = a and friend_id = b)
       and exists (select 1 from public.friendships where user_id = b and friend_id = a);
$$;

create or replace function public.is_blocked_either(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.blocked_users
                   where (blocker_id = a and blocked_user_id = b) or (blocker_id = b and blocked_user_id = a));
$$;

create or replace function public.has_active_call(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.calls
                   where (caller_id = uid or receiver_id = uid)
                     and status in ('ringing', 'accepted', 'connecting', 'connected')
                     and not (status = 'ringing' and expires_at < now()));
$$;

-- Recomputes the presence a friend should see. Online/busy/dnd come from the user's
-- manual choice; "in_call" and "offline" are derived from server state.
create or replace function public.refresh_presence(uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    update public.users u set presence_status =
        case
            when u.last_seen is null or u.last_seen < now() - interval '60 seconds' then 'offline'
            when exists (select 1 from public.calls c
                         where (c.caller_id = uid or c.receiver_id = uid)
                           and c.status in ('accepted', 'connecting', 'connected')) then 'in_call'
            else u.manual_status
        end
    where u.id = uid;
end $$;

-- Closes calls that can no longer progress. Called opportunistically by every call
-- function and once a minute by pg_cron (when available).
create or replace function public.sweep_stale()
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
    for c in
        update public.calls set status = 'missed', ended_at = now(), end_reason = 'timeout'
        where status = 'ringing' and expires_at < now()
        returning caller_id, receiver_id
    loop null; end loop;

    for c in
        update public.calls set status = 'failed', ended_at = now(), end_reason = 'connect_timeout'
        where status in ('accepted', 'connecting') and accepted_at < now() - interval '60 seconds'
        returning caller_id, receiver_id
    loop perform public.refresh_presence(c.caller_id); perform public.refresh_presence(c.receiver_id); end loop;

    -- Connected calls where both apps have stopped heartbeating (crash, power loss).
    for c in
        update public.calls cl set status = 'ended', ended_at = now(), end_reason = 'abandoned',
               duration = greatest(0, extract(epoch from now() - coalesce(cl.started_at, now()))::int)
        where cl.status = 'connected'
          and exists (select 1 from public.users u where u.id = cl.caller_id and (u.last_seen is null or u.last_seen < now() - interval '90 seconds'))
          and exists (select 1 from public.users u where u.id = cl.receiver_id and (u.last_seen is null or u.last_seen < now() - interval '90 seconds'))
        returning caller_id, receiver_id
    loop perform public.refresh_presence(c.caller_id); perform public.refresh_presence(c.receiver_id); end loop;

    update public.users set presence_status = 'offline'
    where presence_status <> 'offline' and (last_seen is null or last_seen < now() - interval '60 seconds');

    delete from public.call_signals where created_at < now() - interval '1 day';
end $$;

-- ---------------------------------------------------------------------------
-- Profile bootstrap
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into public.users (id, email) values (new.id, new.email) on conflict (id) do nothing;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_auth_user();

create or replace function public.handle_auth_email_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    update public.users set email = new.email where id = new.id;
    return new;
end $$;

create trigger on_auth_user_email_changed
    after update of email on auth.users
    for each row when (old.email is distinct from new.email)
    execute function public.handle_auth_email_change();

-- ---------------------------------------------------------------------------
-- Presence
-- ---------------------------------------------------------------------------

-- Called every ~25 s by a running app. Returns the newest ringing incoming call, which
-- doubles as the polling fallback if a Realtime event was missed.
create or replace function public.heartbeat()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); incoming public.calls;
begin
    update public.users set last_seen = now() where id = uid;
    perform public.refresh_presence(uid);
    perform public.sweep_stale();
    select * into incoming from public.calls
    where receiver_id = uid and status = 'ringing' and expires_at > now()
    order by created_at desc limit 1;
    return case when incoming.id is null then null else to_jsonb(incoming) end;
end $$;

create or replace function public.set_manual_status(p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified();
begin
    if p_status not in ('online', 'busy', 'dnd') then raise exception 'invalid_status'; end if;
    update public.users set manual_status = p_status, last_seen = now() where id = uid;
    perform public.refresh_presence(uid);
end $$;

create or replace function public.go_offline()
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
    if uid is null then return; end if;
    update public.users set presence_status = 'offline', last_seen = now() - interval '61 seconds' where id = uid;
end $$;

-- ---------------------------------------------------------------------------
-- Friends
-- ---------------------------------------------------------------------------

create or replace function public.make_friends(a uuid, b uuid)
returns void language sql security definer set search_path = public as $$
    insert into public.friendships (user_id, friend_id) values (a, b), (b, a) on conflict do nothing;
$$;

-- Outcomes: 'sent' | 'accepted' (they had already invited you) | 'already_friends'
--           | 'already_pending' | 'no_account' | 'self'.
-- Blocked pairs get a generic 'sent' so a blocked person can't learn they were blocked.
create or replace function public.request_friend(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    uid uuid := public.require_verified();
    target public.users;
    reverse_req public.friend_requests;
    req public.friend_requests;
begin
    if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_email'; end if;
    perform public.hit_rate_limit('friend_request', 20, 3600);

    select * into target from public.users where email = lower(trim(p_email));
    if target.id is null then return jsonb_build_object('outcome', 'no_account'); end if;
    if target.id = uid then return jsonb_build_object('outcome', 'self'); end if;
    if public.is_blocked_either(uid, target.id) then return jsonb_build_object('outcome', 'sent'); end if;
    if public.are_friends(uid, target.id) then return jsonb_build_object('outcome', 'already_friends'); end if;

    select * into reverse_req from public.friend_requests
    where sender_id = target.id and receiver_id = uid and status = 'pending';
    if reverse_req.id is not null then
        update public.friend_requests set status = 'accepted', updated_at = now() where id = reverse_req.id;
        perform public.make_friends(uid, target.id);
        return jsonb_build_object('outcome', 'accepted', 'request_id', reverse_req.id);
    end if;

    select * into req from public.friend_requests
    where sender_id = uid and receiver_id = target.id and status = 'pending';
    if req.id is not null then
        return jsonb_build_object('outcome', 'already_pending', 'request_id', req.id);
    end if;

    insert into public.friend_requests (sender_id, receiver_id) values (uid, target.id) returning * into req;
    return jsonb_build_object('outcome', 'sent', 'request_id', req.id,
                              'receiver_verified', public.is_verified(target.id));
end $$;

create or replace function public.respond_friend_request(p_request_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); req public.friend_requests;
begin
    select * into req from public.friend_requests where id = p_request_id for update;
    if req.id is null or req.receiver_id <> uid then raise exception 'request_not_found'; end if;
    if req.status <> 'pending' then raise exception 'request_not_pending'; end if;
    update public.friend_requests set status = case when p_accept then 'accepted' else 'declined' end,
           updated_at = now() where id = req.id;
    if p_accept then perform public.make_friends(req.sender_id, req.receiver_id); end if;
end $$;

create or replace function public.cancel_friend_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified();
begin
    update public.friend_requests set status = 'cancelled', updated_at = now()
    where id = p_request_id and sender_id = uid and status = 'pending';
    if not found then raise exception 'request_not_found'; end if;
end $$;

-- Used by the invite-friend Edge Function before re-sending an invitation email.
create or replace function public.prepare_resend(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); req public.friend_requests; target public.users;
begin
    select * into req from public.friend_requests where id = p_request_id for update;
    if req.id is null or req.sender_id <> uid or req.status <> 'pending' then raise exception 'request_not_found'; end if;
    if req.last_email_sent_at is not null and req.last_email_sent_at > now() - interval '10 minutes' then
        raise exception 'rate_limited';
    end if;
    perform public.hit_rate_limit('friend_resend', 10, 3600);
    update public.friend_requests set last_email_sent_at = now(), updated_at = now() where id = req.id;
    select * into target from public.users where id = req.receiver_id;
    return jsonb_build_object('email', target.email, 'receiver_verified', public.is_verified(target.id));
end $$;

create or replace function public.mark_request_emailed(p_request_id uuid)
returns void language sql security definer set search_path = public as $$
    update public.friend_requests set last_email_sent_at = now()
    where id = p_request_id and sender_id = auth.uid();
$$;

create or replace function public.remove_friend(p_friend_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified();
begin
    delete from public.friendships
    where (user_id = uid and friend_id = p_friend_id) or (user_id = p_friend_id and friend_id = uid);
end $$;

create or replace function public.block_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified();
begin
    if p_user_id = uid then raise exception 'invalid_target'; end if;
    insert into public.blocked_users (blocker_id, blocked_user_id) values (uid, p_user_id) on conflict do nothing;
    delete from public.friendships
    where (user_id = uid and friend_id = p_user_id) or (user_id = p_user_id and friend_id = uid);
    update public.friend_requests set status = case when receiver_id = uid then 'declined' else 'cancelled' end,
           updated_at = now()
    where status = 'pending'
      and ((sender_id = uid and receiver_id = p_user_id) or (sender_id = p_user_id and receiver_id = uid));
    update public.calls set status = case when status = 'ringing' then 'declined' else 'ended' end,
           ended_at = now(), end_reason = 'blocked'
    where status in ('ringing', 'accepted', 'connecting', 'connected')
      and ((caller_id = uid and receiver_id = p_user_id) or (caller_id = p_user_id and receiver_id = uid));
    perform public.refresh_presence(uid);
    perform public.refresh_presence(p_user_id);
end $$;

create or replace function public.unblock_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified();
begin
    delete from public.blocked_users where blocker_id = uid and blocked_user_id = p_user_id;
end $$;

create or replace function public.list_friends()
returns table (id uuid, email text, display_name text, avatar_url text,
               presence_status text, last_seen timestamptz, friends_since timestamptz)
language sql stable security definer set search_path = public as $$
    select u.id, u.email::text, u.display_name, u.avatar_url,
           case when u.last_seen is null or u.last_seen < now() - interval '60 seconds' then 'offline'
                else u.presence_status end,
           u.last_seen, f.created_at
    from public.friendships f join public.users u on u.id = f.friend_id
    where f.user_id = auth.uid() and public.is_verified(auth.uid())
    order by lower(coalesce(u.display_name, u.email::text));
$$;

create or replace function public.list_friend_requests()
returns table (id uuid, direction text, status text, other_id uuid, other_email text,
               other_display_name text, other_avatar_url text, created_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
    select r.id,
           case when r.sender_id = auth.uid() then 'outgoing' else 'incoming' end,
           r.status, o.id, o.email::text, o.display_name, o.avatar_url, r.created_at, r.updated_at
    from public.friend_requests r
    join public.users o on o.id = case when r.sender_id = auth.uid() then r.receiver_id else r.sender_id end
    where public.is_verified(auth.uid())
      and ((r.receiver_id = auth.uid() and r.status = 'pending'
            and not public.is_blocked_either(r.sender_id, r.receiver_id))
        or (r.sender_id = auth.uid() and (r.status = 'pending'
            or (r.status = 'declined' and r.updated_at > now() - interval '7 days'))))
    order by r.updated_at desc;
$$;

create or replace function public.list_blocked()
returns table (id uuid, email text, display_name text, avatar_url text, blocked_at timestamptz)
language sql stable security definer set search_path = public as $$
    select u.id, u.email::text, u.display_name, u.avatar_url, b.created_at
    from public.blocked_users b join public.users u on u.id = b.blocked_user_id
    where b.blocker_id = auth.uid()
    order by b.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

-- Error codes raised (client maps them to friendly copy):
--   not_friends, friend_offline, friend_dnd, friend_busy, friend_in_call,
--   already_in_call, crossed_call, rate_limited, email_not_verified
create or replace function public.start_call(p_receiver_id uuid)
returns public.calls language plpgsql security definer set search_path = public as $$
declare
    uid uuid := public.require_verified();
    target public.users;
    existing public.calls;
    new_call public.calls;
begin
    if p_receiver_id = uid then raise exception 'invalid_target'; end if;
    perform public.hit_rate_limit('start_call', 12, 60);

    -- Serialise call creation for both people so two simultaneous calls can't both win.
    perform pg_advisory_xact_lock(hashtextextended(least(uid, p_receiver_id)::text, 0));
    perform pg_advisory_xact_lock(hashtextextended(greatest(uid, p_receiver_id)::text, 0));
    perform public.sweep_stale();

    if not public.are_friends(uid, p_receiver_id) or public.is_blocked_either(uid, p_receiver_id) then
        raise exception 'not_friends';
    end if;
    if not public.is_verified(p_receiver_id) then raise exception 'not_friends'; end if;

    -- Duplicate click: return the call that is already ringing.
    select * into existing from public.calls
    where caller_id = uid and receiver_id = p_receiver_id and status = 'ringing' and expires_at > now();
    if existing.id is not null then return existing; end if;

    -- Both people pressed Call at the same moment.
    select * into existing from public.calls
    where caller_id = p_receiver_id and receiver_id = uid and status = 'ringing' and expires_at > now();
    if existing.id is not null then
        raise exception 'crossed_call' using detail = existing.id::text;
    end if;

    if public.has_active_call(uid) then raise exception 'already_in_call'; end if;

    select * into target from public.users where id = p_receiver_id;
    if target.last_seen is null or target.last_seen < now() - interval '60 seconds'
       or target.presence_status = 'offline' then
        raise exception 'friend_offline';
    end if;
    if public.has_active_call(p_receiver_id) then raise exception 'friend_in_call'; end if;
    if target.manual_status = 'dnd' then raise exception 'friend_dnd'; end if;
    if target.manual_status = 'busy' then raise exception 'friend_busy'; end if;

    insert into public.calls (caller_id, receiver_id) values (uid, p_receiver_id) returning * into new_call;
    return new_call;
end $$;

create or replace function public.answer_call(p_call_id uuid, p_accept boolean)
returns public.calls language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); c public.calls;
begin
    select * into c from public.calls where id = p_call_id for update;
    if c.id is null or c.receiver_id <> uid then raise exception 'call_not_found'; end if;
    if c.status <> 'ringing' then raise exception 'call_not_ringing'; end if;
    if c.expires_at < now() then
        update public.calls set status = 'missed', ended_at = now(), end_reason = 'timeout' where id = c.id;
        raise exception 'call_expired';
    end if;
    if p_accept then
        update public.calls set status = 'accepted', accepted_at = now() where id = c.id returning * into c;
    else
        update public.calls set status = 'declined', ended_at = now(), end_reason = 'declined'
        where id = c.id returning * into c;
    end if;
    perform public.refresh_presence(c.caller_id);
    perform public.refresh_presence(c.receiver_id);
    return c;
end $$;

create or replace function public.cancel_call(p_call_id uuid)
returns public.calls language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); c public.calls;
begin
    update public.calls set
        status = case when expires_at < now() then 'missed' else 'cancelled' end,
        ended_at = now(), end_reason = 'caller_cancelled'
    where id = p_call_id and caller_id = uid and status = 'ringing'
    returning * into c;
    if c.id is null then select * into c from public.calls where id = p_call_id and caller_id = uid; end if;
    if c.id is null then raise exception 'call_not_found'; end if;
    return c;
end $$;

create or replace function public.update_call_state(p_call_id uuid, p_status text)
returns public.calls language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); c public.calls;
begin
    if p_status not in ('connecting', 'connected') then raise exception 'invalid_status'; end if;
    select * into c from public.calls where id = p_call_id for update;
    if c.id is null or uid not in (c.caller_id, c.receiver_id) then raise exception 'call_not_found'; end if;
    if c.status not in ('accepted', 'connecting', 'connected') then return c; end if;
    if p_status = 'connected' then
        update public.calls set status = 'connected', started_at = coalesce(started_at, now())
        where id = c.id returning * into c;
    elsif c.status = 'accepted' then
        update public.calls set status = 'connecting' where id = c.id returning * into c;
    end if;
    return c;
end $$;

create or replace function public.end_call(p_call_id uuid, p_reason text default 'hangup')
returns public.calls language plpgsql security definer set search_path = public as $$
declare uid uuid := public.require_verified(); c public.calls;
begin
    select * into c from public.calls where id = p_call_id for update;
    if c.id is null or uid not in (c.caller_id, c.receiver_id) then raise exception 'call_not_found'; end if;
    if c.status in ('accepted', 'connecting', 'connected') then
        update public.calls set
            status = case when p_reason = 'failed' then 'failed' else 'ended' end,
            ended_at = now(), end_reason = left(coalesce(p_reason, 'hangup'), 40),
            duration = case when started_at is null then 0
                            else greatest(0, extract(epoch from now() - started_at)::int) end
        where id = c.id returning * into c;
    elsif c.status = 'ringing' and uid = c.receiver_id then
        update public.calls set status = 'declined', ended_at = now(), end_reason = 'declined'
        where id = c.id returning * into c;
    elsif c.status = 'ringing' then
        update public.calls set status = 'cancelled', ended_at = now(), end_reason = 'caller_cancelled'
        where id = c.id returning * into c;
    end if;
    perform public.refresh_presence(c.caller_id);
    perform public.refresh_presence(c.receiver_id);
    return c;
end $$;

-- Caller identity for the incoming-call alert.
create or replace function public.get_call_peer(p_call_id uuid)
returns table (id uuid, display_name text, avatar_url text, email text)
language sql stable security definer set search_path = public as $$
    select u.id, u.display_name, u.avatar_url, u.email::text
    from public.calls c
    join public.users u on u.id = case when c.caller_id = auth.uid() then c.receiver_id else c.caller_id end
    where c.id = p_call_id and auth.uid() in (c.caller_id, c.receiver_id);
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.users enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.blocked_users enable row level security;
alter table public.calls enable row level security;
alter table public.call_signals enable row level security;
alter table public.rate_limits enable row level security;

-- users: yourself and your accepted friends only (that's what Realtime presence needs).
create policy users_select on public.users for select to authenticated
    using (id = auth.uid() or public.are_friends(auth.uid(), id));
create policy users_update_self on public.users for update to authenticated
    using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.users from authenticated, anon;
grant update (display_name, avatar_url, profile_completed) on public.users to authenticated;

create policy friend_requests_select on public.friend_requests for select to authenticated
    using (sender_id = auth.uid() or receiver_id = auth.uid());

create policy friendships_select on public.friendships for select to authenticated
    using (user_id = auth.uid());

create policy blocked_users_select on public.blocked_users for select to authenticated
    using (blocker_id = auth.uid());

create policy calls_select on public.calls for select to authenticated
    using (caller_id = auth.uid() or receiver_id = auth.uid());

create policy call_signals_select on public.call_signals for select to authenticated
    using (recipient_id = auth.uid() or sender_id = auth.uid());
create policy call_signals_insert on public.call_signals for insert to authenticated
    with check (
        sender_id = auth.uid()
        and exists (
            select 1 from public.calls c
            where c.id = call_id
              and c.status in ('accepted', 'connecting', 'connected')
              and ((c.caller_id = auth.uid() and c.receiver_id = recipient_id)
                or (c.receiver_id = auth.uid() and c.caller_id = recipient_id))
        )
    );

-- rate_limits has no policies: invisible to clients.

revoke all on public.users, public.friend_requests, public.friendships, public.blocked_users,
              public.calls, public.call_signals, public.rate_limits from anon;
revoke insert, update, delete on public.friend_requests, public.friendships, public.blocked_users,
              public.calls, public.rate_limits from authenticated;
revoke update, delete on public.call_signals from authenticated;

-- Functions: only signed-in users may call them; internal helpers aren't exposed.
revoke execute on all functions in schema public from public, anon;
grant execute on function
    public.heartbeat(), public.set_manual_status(text), public.go_offline(),
    public.request_friend(text), public.respond_friend_request(uuid, boolean),
    public.cancel_friend_request(uuid), public.prepare_resend(uuid), public.mark_request_emailed(uuid),
    public.remove_friend(uuid), public.block_user(uuid), public.unblock_user(uuid),
    public.list_friends(), public.list_friend_requests(), public.list_blocked(),
    public.start_call(uuid), public.answer_call(uuid, boolean), public.cancel_call(uuid),
    public.update_call_state(uuid, text), public.end_call(uuid, text), public.get_call_peer(uuid),
    public.are_friends(uuid, uuid), public.is_verified(uuid)
to authenticated;
revoke execute on function public.sweep_stale(), public.refresh_presence(uuid), public.make_friends(uuid, uuid),
    public.hit_rate_limit(text, integer, integer), public.handle_new_auth_user(),
    public.handle_auth_email_change() from authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

alter table public.friend_requests replica identity full;
alter table public.friendships replica identity full;
alter table public.calls replica identity full;

alter publication supabase_realtime add table
    public.users, public.friend_requests, public.friendships, public.calls, public.call_signals;

-- ---------------------------------------------------------------------------
-- Avatars (Storage)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg'])
on conflict (id) do nothing;

create policy avatars_insert_own on storage.objects for insert to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update_own on storage.objects for update to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete_own on storage.objects for delete to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- Scheduled sweep (pg_cron is available on all Supabase projects)
-- ---------------------------------------------------------------------------

do $$
begin
    create extension if not exists pg_cron;
    perform cron.schedule('mactalk-sweep', '* * * * *', 'select public.sweep_stale()');
exception when others then
    raise notice 'pg_cron unavailable (%); stale calls are still swept on every heartbeat.', sqlerrm;
end $$;
