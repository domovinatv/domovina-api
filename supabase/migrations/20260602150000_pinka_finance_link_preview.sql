-- =============================================================================
-- Support-wall link previews + message moderation
-- =============================================================================
-- Contributors can leave a message with a URL; we fetch sanitized Open Graph
-- metadata (off-chain, via the pay-worker /api/og-preview which has public-only
-- egress) and store it so the wall renders a link-preview card → social feed.
-- message_hidden lets a campaign owner moderate a message/link off the wall.

alter table pinka_finance.contributions
  add column if not exists link_preview  jsonb,
  add column if not exists message_hidden boolean not null default false;

-- Rebuild the public wall view: expose link_preview; null out message + preview
-- when an owner has hidden the message.
create or replace view pinka_finance.public_contributions as
  select
    ct.id,
    ct.campaign_id,
    ct.display_name,
    case when ct.message_hidden then null else ct.message end       as message,
    ct.amount_cents,
    ct.currency,
    ct.created_at,
    ct.paid_at,
    case when ct.message_hidden then null else ct.link_preview end   as link_preview
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id
  where ct.state = 'paid'
    and ct.anonymous = false
    and c.deleted_at is null
    and c.visibility = 'public'
    and c.state in ('active','funded','closed');

-- Owner moderation: hide/unhide a contribution's message + link preview.
-- SECURITY DEFINER but gated on the CALLER owning the campaign (auth.uid()).
create or replace function pinka_finance.set_contribution_message_hidden(
  p_contribution_id uuid,
  p_hidden          boolean
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_account uuid; v_n integer;
begin
  select c.account_id into v_account
    from pinka_finance.contributions ct
    join pinka_finance.campaigns c on c.id = ct.campaign_id
   where ct.id = p_contribution_id;
  if not found then return false; end if;
  if not public.has_role_on_account(v_account, 'admin') then
    raise exception 'not_campaign_owner';
  end if;
  update pinka_finance.contributions
     set message_hidden = p_hidden, updated_at = now()
   where id = p_contribution_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

revoke execute on function pinka_finance.set_contribution_message_hidden(uuid,boolean) from public, anon;
grant execute on function pinka_finance.set_contribution_message_hidden(uuid,boolean) to authenticated, service_role;

-- service_role writes link_preview (from pinka-webhook after the OG fetch).
create or replace function pinka_finance.set_contribution_link_preview(
  p_contribution_id uuid,
  p_preview         jsonb
) returns void
language sql
security definer
set search_path = ''
as $$
  update pinka_finance.contributions
     set link_preview = p_preview, updated_at = now()
   where id = p_contribution_id;
$$;

revoke execute on function pinka_finance.set_contribution_link_preview(uuid,jsonb) from public, anon, authenticated;
grant execute on function pinka_finance.set_contribution_link_preview(uuid,jsonb) to service_role;
