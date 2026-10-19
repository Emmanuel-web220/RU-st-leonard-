-- ============================================================
-- RU ST LÉONARD : script unique (client, gérant, administrateur général)
-- ============================================================

-- 0) NETTOYAGE (projet neuf : sans danger tant qu'il n'y a pas de vraies données)
drop policy if exists pr_ins on storage.objects;
drop policy if exists pr_sel on storage.objects;
drop policy if exists st_preuves_ins on storage.objects;
drop policy if exists st_preuves_sel on storage.objects;
drop policy if exists st_images_ins on storage.objects;
drop policy if exists st_images_upd on storage.objects;
drop policy if exists st_images_del on storage.objects;
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists t_new_user on auth.users;
drop table if exists public.journal, public.remboursements, public.avis, public.litiges,
  public.paiements, public.commande_lignes, public.commandes, public.annonces,
  public.plats, public.parametres, public.profiles, public.restaurants cascade;
drop function if exists public.set_frais();
drop function if exists public.is_announcer();

-- 1) TABLES
create table public.restaurants (
  id uuid primary key default gen_random_uuid(),
  nom text not null, description text, logo_url text, emplacement text, horaires text,
  actif boolean not null default false,
  ouvert boolean not null default true,
  whatsapp text,
  mpesa_numero text, mpesa_nom text,
  orange_numero text, orange_nom text,
  airtel_numero text, airtel_nom text,
  frais_retrait integer not null default 1000 check (frais_retrait >= 0),
  created_at timestamptz default now()
);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, nom text, telephone text,
  whatsapp_identique boolean not null default false,
  role text not null default 'client' check (role in ('client','gerant','adjoint','admin')),
  restaurant_id uuid references public.restaurants(id) on delete set null,
  actif boolean not null default true,
  derniere_activite timestamptz,
  created_at timestamptz default now()
);
create table public.plats (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  nom text not null,
  categorie text not null check (categorie in ('buffet','accompagnement','fast-food','boisson')),
  prix integer not null check (prix >= 0),
  disponible boolean not null default true,
  plat_du_jour boolean not null default false,
  promo boolean not null default false,
  image_url text, ordre integer not null default 0,
  created_at timestamptz default now()
);
create table public.commandes (
  id uuid primary key default gen_random_uuid(),
  numero text,
  restaurant_id uuid not null references public.restaurants(id),
  client_id uuid default auth.uid() references public.profiles(id),
  statut text not null default 'en_attente' check (statut in ('en_attente','refusee','validee','en_preparation','prete','remise','annulee')),
  motif_refus text,
  sous_total integer not null default 0,
  frais_retrait integer not null default 0,
  total integer not null default 0,
  appareil text,
  minuteur_debut timestamptz,
  created_at timestamptz default now()
);
create table public.commande_lignes (
  id uuid primary key default gen_random_uuid(),
  commande_id uuid not null references public.commandes(id) on delete cascade,
  plat_id uuid references public.plats(id) on delete set null,
  nom text, prix integer,
  quantite integer not null default 1 check (quantite between 1 and 50)
);
create table public.paiements (
  id uuid primary key default gen_random_uuid(),
  commande_id uuid not null references public.commandes(id) on delete cascade,
  restaurant_id uuid references public.restaurants(id),
  methode text not null check (methode in ('mpesa','orange_money','airtel_money')),
  montant integer not null default 0,
  preuve_url text,
  statut text not null default 'en_attente' check (statut in ('en_attente','preuve_recue','verifie','rejete')),
  motif_rejet text,
  verifie_par uuid, verifie_le timestamptz,
  created_at timestamptz default now()
);
create table public.remboursements (
  id uuid primary key default gen_random_uuid(),
  commande_id uuid references public.commandes(id),
  paiement_id uuid references public.paiements(id),
  restaurant_id uuid references public.restaurants(id),
  client_id uuid default auth.uid() references public.profiles(id),
  motif text, montant integer not null check (montant >= 0),
  statut text not null default 'demande' check (statut in ('demande','approuve','refuse','paye')),
  decide_par uuid,
  created_at timestamptz default now()
);
create table public.litiges (
  id uuid primary key default gen_random_uuid(),
  commande_id uuid references public.commandes(id),
  restaurant_id uuid references public.restaurants(id),
  auteur_id uuid default auth.uid() references public.profiles(id),
  type text check (type in ('annulation','probleme_connexion','commande_invalide','autre')),
  description text,
  statut text not null default 'ouvert' check (statut in ('ouvert','resolu')),
  resolution text, resolu_par uuid, resolu_le timestamptz,
  created_at timestamptz default now()
);
create table public.avis (
  id uuid primary key default gen_random_uuid(),
  commande_id uuid not null unique references public.commandes(id) on delete cascade,
  restaurant_id uuid references public.restaurants(id),
  client_id uuid default auth.uid() references public.profiles(id),
  note integer not null check (note between 1 and 5),
  commentaire text,
  created_at timestamptz default now()
);
create table public.annonces (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid references public.restaurants(id) on delete cascade,
  titre text not null, contenu text, image_url text,
  type text not null default 'annonce_restaurant' check (type in ('publicite','annonce_restaurant','universite')),
  actif boolean not null default true,
  date_debut timestamptz, date_fin timestamptz,
  modifie boolean not null default false,
  auteur_id uuid default auth.uid(),
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.parametres (cle text primary key, valeur text);
create table public.journal (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  type text not null check (type in ('connexion','echec_connexion','bug','action')),
  appareil text,
  message text check (char_length(message) <= 500),
  created_at timestamptz default now()
);

-- 2) FONCTIONS D'ACCÈS
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and actif);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('admin','gerant','adjoint') and actif);
$$;
create or replace function public.is_staff_of(rid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from profiles where id = auth.uid() and role in ('gerant','adjoint') and actif and restaurant_id = rid);
$$;
create or replace function public.can_see_client(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from commandes c where c.client_id = cid and public.is_staff_of(c.restaurant_id));
$$;

-- 3) LOGIQUE AUTOMATIQUE
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, nom, telephone, whatsapp_identique)
  values (new.id, new.email, new.raw_user_meta_data->>'nom', new.raw_user_meta_data->>'telephone',
          coalesce((new.raw_user_meta_data->>'whatsapp_identique')::boolean, false));
  return new;
end $$;

create or replace function public.profiles_protege() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.restaurant_id := old.restaurant_id; new.actif := old.actif; new.email := old.email;
  end if;
  return new;
end $$;

create or replace function public.commandes_avant_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from restaurants where id = new.restaurant_id and actif;
  if not found then raise exception 'Restaurant indisponible'; end if;
  if auth.uid() is not null then new.client_id := auth.uid(); end if;
  new.statut := 'en_attente'; new.minuteur_debut := null; new.sous_total := 0;
  new.frais_retrait := r.frais_retrait; new.total := r.frais_retrait;
  new.numero := (select count(*) + 1 from commandes where restaurant_id = new.restaurant_id
    and (created_at at time zone 'Africa/Kinshasa')::date = (now() at time zone 'Africa/Kinshasa')::date)::text;
  return new;
end $$;

create or replace function public.commandes_avant_update() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() = 1 and auth.uid() is not null and not public.is_staff_of(old.restaurant_id) then
    if new.statut <> 'annulee' or old.minuteur_debut is not null or old.statut not in ('en_attente','validee') then
      raise exception 'Annulation impossible : la commande est déjà en préparation';
    end if;
    new.sous_total := old.sous_total; new.frais_retrait := old.frais_retrait; new.total := old.total;
    new.restaurant_id := old.restaurant_id; new.client_id := old.client_id; new.numero := old.numero;
    new.minuteur_debut := old.minuteur_debut; new.motif_refus := old.motif_refus; new.appareil := old.appareil;
  end if;
  if new.statut <> old.statut then
    if not ((old.statut = 'en_attente' and new.statut in ('validee','refusee','annulee'))
         or (old.statut = 'validee' and new.statut in ('en_preparation','annulee'))
         or (old.statut = 'en_preparation' and new.statut = 'prete')
         or (old.statut = 'prete' and new.statut = 'remise')) then
      raise exception 'Changement de statut invalide';
    end if;
    if new.statut = 'validee' and not exists (select 1 from paiements where commande_id = old.id and preuve_url is not null) then
      raise exception 'Capture de paiement manquante';
    end if;
    if new.statut = 'en_preparation' and new.minuteur_debut is null then new.minuteur_debut := now(); end if;
  end if;
  return new;
end $$;

create or replace function public.lignes_avant_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare p record; rid uuid;
begin
  select restaurant_id into rid from commandes where id = new.commande_id;
  select * into p from plats where id = new.plat_id and restaurant_id = rid and disponible;
  if not found then raise exception 'Plat indisponible'; end if;
  new.nom := p.nom; new.prix := p.prix;
  return new;
end $$;
create or replace function public.lignes_apres_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update commandes set
    sous_total = (select coalesce(sum(prix * quantite), 0) from commande_lignes where commande_id = new.commande_id),
    total = frais_retrait + (select coalesce(sum(prix * quantite), 0) from commande_lignes where commande_id = new.commande_id)
  where id = new.commande_id;
  return new;
end $$;

create or replace function public.paiements_avant_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from commandes where id = new.commande_id;
  new.restaurant_id := c.restaurant_id; new.montant := c.total;
  if auth.uid() is not null and not public.is_staff_of(c.restaurant_id) then
    new.statut := case when new.preuve_url is not null then 'preuve_recue' else 'en_attente' end;
    new.verifie_par := null; new.verifie_le := null; new.motif_rejet := null;
  end if;
  return new;
end $$;
create or replace function public.paiements_avant_update() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.montant := old.montant; new.commande_id := old.commande_id; new.restaurant_id := old.restaurant_id;
  if new.statut in ('verifie','rejete') and new.statut is distinct from old.statut then
    new.verifie_par := auth.uid(); new.verifie_le := now();
  end if;
  return new;
end $$;

create or replace function public.set_from_commande() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.commande_id is not null then
    select restaurant_id into new.restaurant_id from commandes where id = new.commande_id;
  end if;
  return new;
end $$;
create or replace function public.annonces_avant_update() returns trigger language plpgsql as $$
begin
  if (new.titre, new.contenu) is distinct from (old.titre, old.contenu) then new.modifie := true; end if;
  new.updated_at := now();
  return new;
end $$;

create trigger t_new_user after insert on auth.users for each row execute function public.handle_new_user();
create trigger t_profiles before update on public.profiles for each row execute function public.profiles_protege();
create trigger t_cmd_ins before insert on public.commandes for each row execute function public.commandes_avant_insert();
create trigger t_cmd_upd before update on public.commandes for each row execute function public.commandes_avant_update();
create trigger t_lig_ins before insert on public.commande_lignes for each row execute function public.lignes_avant_insert();
create trigger t_lig_apres after insert on public.commande_lignes for each row execute function public.lignes_apres_insert();
create trigger t_pai_ins before insert on public.paiements for each row execute function public.paiements_avant_insert();
create trigger t_pai_upd before update on public.paiements for each row execute function public.paiements_avant_update();
create trigger t_lit_ins before insert on public.litiges for each row execute function public.set_from_commande();
create trigger t_remb_ins before insert on public.remboursements for each row execute function public.set_from_commande();
create trigger t_avis_ins before insert on public.avis for each row execute function public.set_from_commande();
create trigger t_ann_upd before update on public.annonces for each row execute function public.annonces_avant_update();

-- 4) SÉCURITÉ (qui voit quoi)
alter table public.restaurants enable row level security;
alter table public.profiles enable row level security;
alter table public.plats enable row level security;
alter table public.commandes enable row level security;
alter table public.commande_lignes enable row level security;
alter table public.paiements enable row level security;
alter table public.remboursements enable row level security;
alter table public.litiges enable row level security;
alter table public.avis enable row level security;
alter table public.annonces enable row level security;
alter table public.parametres enable row level security;
alter table public.journal enable row level security;

create policy r_sel on public.restaurants for select using (actif or public.is_admin() or public.is_staff_of(id));
create policy r_ins on public.restaurants for insert with check (public.is_admin());
create policy r_upd on public.restaurants for update using (public.is_admin()) with check (public.is_admin());
create policy r_del on public.restaurants for delete using (public.is_admin());

create policy p_sel on public.profiles for select using (id = auth.uid() or public.is_admin() or public.can_see_client(id));
create policy p_upd on public.profiles for update using (id = auth.uid() or public.is_admin());

create policy pl_sel on public.plats for select using (
  exists (select 1 from public.restaurants r where r.id = restaurant_id and r.actif) or public.is_staff_of(restaurant_id));
create policy pl_ins on public.plats for insert with check (public.is_staff_of(restaurant_id));
create policy pl_upd on public.plats for update using (public.is_staff_of(restaurant_id)) with check (public.is_staff_of(restaurant_id));
create policy pl_del on public.plats for delete using (public.is_staff_of(restaurant_id));

create policy c_sel on public.commandes for select using (client_id = auth.uid() or public.is_staff_of(restaurant_id));
create policy c_ins on public.commandes for insert with check (client_id = auth.uid());
create policy c_upd on public.commandes for update using (client_id = auth.uid() or public.is_staff_of(restaurant_id));

create policy cl_sel on public.commande_lignes for select using (exists (select 1 from public.commandes c where c.id = commande_id));
create policy cl_ins on public.commande_lignes for insert with check (
  exists (select 1 from public.commandes c where c.id = commande_id and c.client_id = auth.uid() and c.statut = 'en_attente'));

create policy pa_sel on public.paiements for select using (
  public.is_staff_of(restaurant_id) or exists (select 1 from public.commandes c where c.id = commande_id and c.client_id = auth.uid()));
create policy pa_ins on public.paiements for insert with check (
  exists (select 1 from public.commandes c where c.id = commande_id and c.client_id = auth.uid()));
create policy pa_upd on public.paiements for update using (public.is_staff_of(restaurant_id));

create policy rb_sel on public.remboursements for select using (client_id = auth.uid() or public.is_staff_of(restaurant_id));
create policy rb_ins on public.remboursements for insert with check ((client_id = auth.uid() and statut = 'demande') or public.is_staff_of(restaurant_id));
create policy rb_upd on public.remboursements for update using (public.is_staff_of(restaurant_id));

create policy l_sel on public.litiges for select using (auteur_id = auth.uid() or public.is_staff_of(restaurant_id));
create policy l_ins on public.litiges for insert with check ((auteur_id = auth.uid() and statut = 'ouvert' and resolution is null) or public.is_staff_of(restaurant_id));
create policy l_upd on public.litiges for update using (public.is_staff_of(restaurant_id));

create policy av_sel on public.avis for select using (true);
create policy av_ins on public.avis for insert with check (
  client_id = auth.uid() and exists (select 1 from public.commandes c where c.id = commande_id and c.client_id = auth.uid() and c.statut = 'remise'));

create policy an_sel on public.annonces for select using (
  (actif and (date_debut is null or date_debut <= now()) and (date_fin is null or date_fin >= now())
   and (restaurant_id is null or exists (select 1 from public.restaurants r where r.id = restaurant_id and r.actif)))
  or public.is_admin() or public.is_staff_of(restaurant_id));
create policy an_ins on public.annonces for insert with check (public.is_admin());
create policy an_upd on public.annonces for update using (public.is_admin());
create policy an_del on public.annonces for delete using (public.is_admin());

create policy pm_sel on public.parametres for select using (true);
create policy pm_ins on public.parametres for insert with check (public.is_admin());
create policy pm_upd on public.parametres for update using (public.is_admin());
create policy pm_del on public.parametres for delete using (public.is_admin());

create policy j_ins on public.journal for insert to anon, authenticated with check (true);
create policy j_sel on public.journal for select using (public.is_admin());

-- 5) STOCKAGE : captures de paiement privées, images publiques
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
 ('preuves','preuves',false,5242880,array['image/jpeg','image/png','image/webp']),
 ('images','images',true,3145728,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy st_preuves_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'preuves' and (storage.foldername(name))[1] = auth.uid()::text);
create policy st_preuves_sel on storage.objects for select to authenticated
  using (bucket_id = 'preuves' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()
    or exists (select 1 from public.paiements p where p.preuve_url = name and public.is_staff_of(p.restaurant_id))));
create policy st_images_ins on storage.objects for insert to authenticated with check (bucket_id = 'images' and public.is_staff());
create policy st_images_upd on storage.objects for update to authenticated using (bucket_id = 'images' and public.is_staff());
create policy st_images_del on storage.objects for delete to authenticated using (bucket_id = 'images' and public.is_staff());

-- 6) RAPPORT JOURNALIER (administrateur : global ; gérant : son restaurant)
create or replace function public.rapport_journalier(jour date, rid uuid default null)
returns jsonb language sql stable as $$
select jsonb_build_object(
 'date', jour,
 'entrees', coalesce((select sum(montant) from paiements where statut = 'verifie'
    and (verifie_le at time zone 'Africa/Kinshasa')::date = jour and (rid is null or restaurant_id = rid)), 0),
 'sorties', coalesce((select sum(montant) from remboursements where statut = 'paye'
    and (created_at at time zone 'Africa/Kinshasa')::date = jour and (rid is null or restaurant_id = rid)), 0),
 'nb_commandes', (select count(*) from commandes where statut not in ('annulee','refusee')
    and (created_at at time zone 'Africa/Kinshasa')::date = jour and (rid is null or restaurant_id = rid)),
 'plat_top', (select jsonb_build_object('nom', nom, 'quantite', q) from (
    select l.nom, sum(l.quantite) q from commande_lignes l join commandes c on c.id = l.commande_id
    left join plats p on p.id = l.plat_id
    where c.statut not in ('annulee','refusee') and (c.created_at at time zone 'Africa/Kinshasa')::date = jour
      and (rid is null or c.restaurant_id = rid) and coalesce(p.categorie,'') <> 'boisson'
    group by l.nom order by q desc limit 1) t),
 'boisson_top', (select jsonb_build_object('nom', nom, 'quantite', q) from (
    select l.nom, sum(l.quantite) q from commande_lignes l join commandes c on c.id = l.commande_id
    left join plats p on p.id = l.plat_id
    where c.statut not in ('annulee','refusee') and (c.created_at at time zone 'Africa/Kinshasa')::date = jour
      and (rid is null or c.restaurant_id = rid) and p.categorie = 'boisson'
    group by l.nom order by q desc limit 1) t),
 'appareils', (select coalesce(jsonb_object_agg(a, n), '{}'::jsonb) from (
    select coalesce(appareil,'inconnu') a, count(*) n from journal
    where type = 'connexion' and (created_at at time zone 'Africa/Kinshasa')::date = jour group by 1) t),
 'appareil_top', (select a from (
    select coalesce(appareil,'inconnu') a, count(*) n from journal
    where type = 'connexion' and (created_at at time zone 'Africa/Kinshasa')::date = jour
    group by 1 order by n desc limit 1) t)
);
$$;

-- 7) CRÉATION DES COMPTES D'AGENTS PAR L'ADMINISTRATEUR
create extension if not exists pgcrypto with schema extensions;
create or replace function public.creer_agent(p_email text, p_mot_de_passe text, p_nom text, p_role text, p_restaurant uuid)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid();
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur général'; end if;
  if p_role not in ('gerant','adjoint') then raise exception 'Rôle invalide'; end if;
  if p_restaurant is null then raise exception 'Restaurant obligatoire'; end if;
  if length(p_mot_de_passe) < 8 then raise exception 'Mot de passe trop court (8 caractères minimum)'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(p_email),
    crypt(p_mot_de_passe, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('nom', p_nom), now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', lower(p_email)), 'email', now(), now(), now());
  update public.profiles set role = p_role, restaurant_id = p_restaurant, nom = p_nom where id = uid;
  return uid;
end $$;
revoke all on function public.creer_agent(text, text, text, text, uuid) from public, anon;
grant execute on function public.creer_agent(text, text, text, text, uuid) to authenticated;

-- 8) DONNÉES : restaurant, menu, paramètres
insert into public.restaurants (nom, description, emplacement, horaires, actif, whatsapp)
values ('RU St Léonard', 'Restaurant universitaire de l''UCC',
        'Près du Bâtiment Administratif de la faculté d''Économie, UCC Limete',
        'Lundi au vendredi, 08h00 - 18h00', true, '+243971302415');

insert into public.plats (restaurant_id, nom, categorie, prix)
select r.id, v.nom, v.cat, v.prix from public.restaurants r,
(values
 ('Ngulu','buffet',15000),('Capitaine','buffet',15000),('Poisson de sol','buffet',15000),
 ('Boulette de viande','buffet',10000),('Poisson boucané','buffet',8000),('Makoso','buffet',5000),
 ('Cuisse de poulet','buffet',6000),('Maloi','buffet',5000),('Cotis','buffet',3000),
 ('Fumbwa','buffet',3000),('Légumes','buffet',3000),('Pondu','buffet',3000),
 ('Madesu','buffet',3000),('Sacamadesu','buffet',3000),('Brochette de poulet','buffet',2000),
 ('Frites','accompagnement',3000),('Bananes','accompagnement',3000),('Kwanga','accompagnement',2000),
 ('Riz','accompagnement',2000),('Pattes St Léonard','accompagnement',2000),('Fufu','accompagnement',1000),
 ('Chawarma','fast-food',8000),('Samoussa','fast-food',1500),('Mini-pizza','fast-food',1500),
 ('Tembo','boisson',5000),('Castel','boisson',4000),('Nkoyi Black','boisson',4000),
 ('Nkoyi GT','boisson',4000),('Heineken GT','boisson',6000),('Beaufort GT','boisson',4000),
 ('Coca','boisson',2500),('Fanta','boisson',2500),('Sprite','boisson',2500),
 ('Vitalo','boisson',2500),('Energy malt','boisson',2500),('Maltina','boisson',2500),('Eau','boisson',500)
) as v(nom, cat, prix)
where r.nom = 'RU St Léonard';

insert into public.parametres (cle, valeur) values
 ('message_erreur','Le site rencontre actuellement un problème, veuillez passer au restaurant pour passer votre commande.'),
 ('lien_communaute_whatsapp',''),
 ('site_maintenance','false');

-- 9) COMPTE ADMINISTRATEUR GÉNÉRAL
insert into public.profiles (id, email, nom, telephone)
select id, email, raw_user_meta_data->>'nom', raw_user_meta_data->>'telephone' from auth.users
on conflict (id) do nothing;
update public.profiles set role = 'admin' where email = 'stleonard@gmail.com';
