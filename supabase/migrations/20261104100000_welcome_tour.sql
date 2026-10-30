-- Remember who has seen the welcome video, so it shows once per person on any device.
alter table public.profiles add column tour_seen_at timestamptz;

create function public.tour_status() returns timestamptz
language sql stable security definer set search_path = public as $$ select tour_seen_at from profiles where id = auth.uid() $$;

create function public.tour_done() returns void
language sql security definer set search_path = public as $$ update profiles set tour_seen_at = coalesce(tour_seen_at, now()) where id = auth.uid() $$;
