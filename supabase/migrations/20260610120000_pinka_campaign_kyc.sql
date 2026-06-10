-- =============================================================================
-- pinka_finance — kreiranje kampanje zahtijeva verificirani identitet (KYC/AML)
--
-- Poslovna odluka (2026-06-10): kampanju na pinka.io smije kreirati ISKLJUČIVO
-- korisnik prijavljen Certilia Mobile ID-jem (eOsobna) — time je implicitno
-- odrađen KYC i točno se zna koja fizička osoba stoji iza kampanje (AML).
-- UI gate postoji u appu; ovo je server-side enforcement na RLS razini.
--
-- identity_verifications je service_role-only (RLS bez client policyja) pa
-- policy subquery ne može čitati tablicu direktno → security definer helper
-- koji vraća samo boolean (nikakav PII ne izlazi).
-- =============================================================================

-- ----- helper: je li trenutni user KYC-verificiran ---------------------------
create or replace function public.is_identity_verified()
returns boolean
language sql security definer set search_path = '' stable
as $$
  select exists (
    select 1 from public.identity_verifications
    where user_id = (select auth.uid())
  );
$$;

revoke execute on function public.is_identity_verified() from public, anon;
grant execute on function public.is_identity_verified() to authenticated, service_role;

-- ----- campaigns INSERT: admin na accountu + KYC -----------------------------
drop policy if exists campaigns_insert on pinka_finance.campaigns;
create policy campaigns_insert on pinka_finance.campaigns
  for insert to authenticated
  with check (
    public.has_role_on_account(account_id, 'admin')
    and public.is_identity_verified()
  );

select 'OK pinka_campaign_kyc' as status;
