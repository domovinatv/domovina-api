-- =============================================================================
-- pinka-og-cache: OG slike iz link previewa, keširane KOD NAS
-- =============================================================================
-- Zid podrške do sada NIJE crtao `link_preview.image`: `Image.network` na
-- proizvoljan tuđi host odao bi IP svakog posjetitelja zida vlasniku tog hosta
-- (odluka iz pay.domovina.ai/backend/src/og/preview.ts). Rješenje je isto kao
-- kod Facebooka/Slacka: sliku dohvati NAŠ server, JEDNOM po doprinosu, i spremi
-- je kod sebe. `pinka-webhook` je nakon plaćanja skine, uploada u ovaj bucket i
-- u `link_preview` dopiše `image_cached` (render URL na api.domovina.ai).
-- Zid crta ISKLJUČIVO `image_cached`; bez njega kartica ostaje tekstualna.
--
-- Storage backend je Cloudflare R2 (bucket domovina-storage), pa objekt fizički
-- živi na R2; javni pristup ide kroz Supabase storage API (public bucket +
-- imgproxy render za resize).
-- =============================================================================

-- ----- 1. bucket ------------------------------------------------------------
-- Public-read; upload SAMO service role (nema insert/update policyja za
-- authenticated/anon). 2 MB, bez SVG-a (skripta u slici = XSS na našem hostu).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pinka-og-cache', 'pinka-og-cache', true, 2097152,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ----- 2. RPC: dopiši image_cached u postojeći link_preview -----------------
-- Merge (`||`), ne zamjena — title/description/url ostaju netaknuti. Bez
-- previewa (null) ne radi ništa: slika bez kartice nema gdje stajati.
create or replace function pinka_finance.set_contribution_link_preview_image(
  p_contribution_id uuid,
  p_image_cached text
) returns void
language sql
security definer
set search_path = ''
as $$
  update pinka_finance.contributions
     set link_preview = link_preview || jsonb_build_object('image_cached', p_image_cached),
         updated_at = now()
   where id = p_contribution_id
     and link_preview is not null;
$$;

revoke execute on function pinka_finance.set_contribution_link_preview_image(uuid, text)
  from public, anon, authenticated;
grant execute on function pinka_finance.set_contribution_link_preview_image(uuid, text)
  to service_role;
