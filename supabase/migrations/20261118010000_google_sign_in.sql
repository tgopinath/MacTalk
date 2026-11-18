-- Google sign-in: prefill the MacTalk profile from the Google account (name + photo).
-- Google-verified emails arrive with email_confirmed_at set, so these users can call right away.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
    meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
    name text := nullif(left(trim(coalesce(meta->>'full_name', meta->>'name', '')), 40), '');
    photo text := nullif(left(coalesce(meta->>'avatar_url', meta->>'picture', ''), 512), '');
begin
    insert into public.users (id, email, display_name, avatar_url)
    values (new.id, new.email, name, photo)
    on conflict (id) do nothing;
    return new;
end $$;

-- An invited (email) account that later signs in with Google keeps its profile but
-- gains the Google name/photo if it didn't have one yet.
create or replace function public.handle_auth_metadata_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
    update public.users set
        display_name = coalesce(display_name, nullif(left(trim(coalesce(meta->>'full_name', meta->>'name', '')), 40), '')),
        avatar_url   = coalesce(avatar_url, nullif(left(coalesce(meta->>'avatar_url', meta->>'picture', ''), 512), ''))
    where id = new.id;
    return new;
end $$;

drop trigger if exists on_auth_user_metadata_changed on auth.users;
create trigger on_auth_user_metadata_changed
    after update of raw_user_meta_data on auth.users
    for each row when (old.raw_user_meta_data is distinct from new.raw_user_meta_data)
    execute function public.handle_auth_metadata_change();

revoke execute on function public.handle_auth_metadata_change() from public, anon, authenticated;
