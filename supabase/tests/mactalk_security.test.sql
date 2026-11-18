-- pgTAP tests for MacTalk's server-side rules. Run with: supabase test db
-- Creates three verified users (alice, bob, eve) and one unverified (uma).
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, email_confirmed_at, aud, role) values
  ('00000000-0000-4000-8000-00000000000a', 'alice@test.dev', now(), 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000000b', 'bob@test.dev',   now(), 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000000e', 'eve@test.dev',   now(), 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000aa', 'uma@test.dev',   null,  'authenticated', 'authenticated');

select is((select count(*)::int from public.users), 4, 'profile rows are created by trigger');

create or replace function pg_temp.login(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
$$;
create or replace function pg_temp.online(uid uuid) returns void language sql as $$
  update public.users set last_seen = now(), presence_status = 'online' where id = uid;
$$;

-- Unverified users can do nothing.
select pg_temp.login('00000000-0000-4000-8000-0000000000aa');
select throws_ok($$ select public.request_friend('bob@test.dev') $$, 'email_not_verified');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'email_not_verified');
reset role;

-- Strangers cannot call.
select pg_temp.online('00000000-0000-4000-8000-00000000000b');
select pg_temp.login('00000000-0000-4000-8000-00000000000e');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'not_friends', 'stranger cannot call');
select is_empty($$ select * from public.users where id = '00000000-0000-4000-8000-00000000000b' $$, 'stranger cannot read profile/email');
select throws_ok($$ insert into public.calls (caller_id, receiver_id) values ('00000000-0000-4000-8000-00000000000e', '00000000-0000-4000-8000-00000000000b') $$,
                 '42501', null, 'calls cannot be inserted directly');
reset role;

-- Alice invites Bob; Bob accepts.
select pg_temp.login('00000000-0000-4000-8000-00000000000a');
select is(public.request_friend('BOB@test.dev')->>'outcome', 'sent', 'invite is case-insensitive');
select is(public.request_friend('bob@test.dev')->>'outcome', 'already_pending', 'no duplicate requests');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'not_friends', 'pending is not enough to call');
reset role;
select pg_temp.login('00000000-0000-4000-8000-00000000000b');
select lives_ok($$ select public.respond_friend_request((select id from public.friend_requests limit 1), true) $$);
select is((select count(*)::int from public.list_friends()), 1, 'bob sees alice');
reset role;

-- Offline friend: unavailable, not ringing.
update public.users set last_seen = now() - interval '5 minutes' where id = '00000000-0000-4000-8000-00000000000b';
select pg_temp.login('00000000-0000-4000-8000-00000000000a');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'friend_offline');
reset role;

-- Online: call rings; duplicate click returns the same call.
select pg_temp.online('00000000-0000-4000-8000-00000000000b');
select pg_temp.online('00000000-0000-4000-8000-00000000000a');
select pg_temp.login('00000000-0000-4000-8000-00000000000a');
create temp table c1 as select * from public.start_call('00000000-0000-4000-8000-00000000000b');
select is((select status from c1), 'ringing');
select is((select id from public.start_call('00000000-0000-4000-8000-00000000000b')), (select id from c1), 'duplicate click reuses call');
-- No signaling (and therefore no audio) before acceptance.
select throws_ok($$ insert into public.call_signals (call_id, sender_id, recipient_id, kind) values
                    ((select id from c1), '00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-00000000000b', 'offer') $$,
                 '42501', null, 'cannot signal while ringing');
reset role;

-- Bob calling Alice at the same time is a crossed call.
select pg_temp.login('00000000-0000-4000-8000-00000000000b');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000a') $$, 'crossed_call');
select is((public.answer_call((select id from c1), true)).status, 'accepted');
reset role;

select pg_temp.login('00000000-0000-4000-8000-00000000000a');
select lives_ok($$ insert into public.call_signals (call_id, sender_id, recipient_id, kind, payload) values
                   ((select id from c1), '00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-00000000000b', 'offer', '{"sdp":"v=0"}') $$,
                'participants can signal after acceptance');
reset role;

-- Eve can neither read nor inject signals into the call.
select pg_temp.login('00000000-0000-4000-8000-00000000000e');
select is_empty($$ select * from public.call_signals $$, 'outsiders cannot read signals');
select throws_ok($$ insert into public.call_signals (call_id, sender_id, recipient_id, kind) values
                    ((select id from c1), '00000000-0000-4000-8000-00000000000e', '00000000-0000-4000-8000-00000000000b', 'ice') $$,
                 '42501');
reset role;

-- Busy: Eve (after friending Bob) can't reach Bob while he's in a call.
select public.make_friends('00000000-0000-4000-8000-00000000000e', '00000000-0000-4000-8000-00000000000b');
select pg_temp.online('00000000-0000-4000-8000-00000000000e');
select pg_temp.login('00000000-0000-4000-8000-00000000000e');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'friend_in_call');
reset role;

-- Blocking ends the call and the friendship.
select pg_temp.login('00000000-0000-4000-8000-00000000000b');
select lives_ok($$ select public.block_user('00000000-0000-4000-8000-00000000000a') $$);
reset role;
select is((select status from public.calls where id = (select id from c1)), 'ended', 'block ends active call');
select pg_temp.login('00000000-0000-4000-8000-00000000000a');
select throws_ok($$ select public.start_call('00000000-0000-4000-8000-00000000000b') $$, 'not_friends', 'blocked user cannot call');
select is(public.request_friend('bob@test.dev')->>'outcome', 'sent', 'blocked user is not told they were blocked');
reset role;

select * from finish();
rollback;
