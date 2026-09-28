-- Dimenzije keširane OG slike uz `image_cached`: zid mora znati omjer PRIJE
-- nego se slika učita (visina pločice; portret ide lijevo od teksta,
-- landscape ispod). OG „standard" je 1200×630, ali stvarne slike su i
-- kvadratne i portretne.
drop function if exists pinka_finance.set_contribution_link_preview_image(uuid, text);

create or replace function pinka_finance.set_contribution_link_preview_image(
  p_contribution_id uuid,
  p_image_cached text,
  p_width int default null,
  p_height int default null
) returns void
language sql
security definer
set search_path = ''
as $$
  update pinka_finance.contributions
     set link_preview = link_preview
           || jsonb_build_object('image_cached', p_image_cached)
           || jsonb_strip_nulls(jsonb_build_object('image_width', p_width, 'image_height', p_height)),
         updated_at = now()
   where id = p_contribution_id
     and link_preview is not null;
$$;

revoke execute on function pinka_finance.set_contribution_link_preview_image(uuid, text, int, int)
  from public, anon, authenticated;
grant execute on function pinka_finance.set_contribution_link_preview_image(uuid, text, int, int)
  to service_role;
