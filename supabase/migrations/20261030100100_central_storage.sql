-- Private storage for profile photos and KYC documents (masked Aadhaar, PAN card).
-- Files live at <user id>/<kind>-<time>.jpg. People upload only into their own folder;
-- reading follows the same rules as the people view (see kyc_file_visible).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc', 'kyc', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "kyc: upload into own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kyc: read what you may see" on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and public.kyc_file_visible(name));
