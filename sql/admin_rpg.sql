-- Administração do Deck e Dados: o admin vê e modera todas as mesas de RPG e o RPG Solo.
-- Rode DEPOIS de mesa_rpg.sql e rpgsolo_saves.sql. Pode rodar mais de uma vez.
-- Supabase: SQL Editor > New query > cole tudo > Run.

-- 1) Quem é admin (profiles.role = 'admin')
create or replace function public.deck_e_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;
revoke all on function public.deck_e_admin() from public;
grant execute on function public.deck_e_admin() to authenticated;

-- 2) Proteção do papel: ninguém se promove sozinho a admin ou lojista.
--    No cadastro o papel é sempre 'jogador'; só um admin (ou o SQL Editor) muda o papel depois.
create or replace function public.deck_protege_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;            -- SQL Editor / service role
  if public.deck_e_admin() then return new; end if;          -- admin pode tudo
  if tg_op = 'INSERT' then
    new.role := 'jogador';
  elsif new.role is distinct from old.role then
    raise exception 'Somente o administrador pode alterar o papel de um usuário.';
  end if;
  return new;
end $$;
drop trigger if exists deck_protege_role on public.profiles;
create trigger deck_protege_role before insert or update on public.profiles
  for each row execute function public.deck_protege_role();

-- 3) Mesas de RPG: admin vê tudo (inclusive sussurros e rolagens secretas) e modera
drop policy if exists "mesas: admin ve" on public.rpg_mesas;
create policy "mesas: admin ve" on public.rpg_mesas for select using (public.deck_e_admin());
drop policy if exists "mesas: admin altera" on public.rpg_mesas;
create policy "mesas: admin altera" on public.rpg_mesas for update using (public.deck_e_admin()) with check (public.deck_e_admin());
drop policy if exists "mesas: admin apaga" on public.rpg_mesas;
create policy "mesas: admin apaga" on public.rpg_mesas for delete using (public.deck_e_admin());

drop policy if exists "membros: admin ve" on public.rpg_membros;
create policy "membros: admin ve" on public.rpg_membros for select using (public.deck_e_admin());
drop policy if exists "membros: admin edita" on public.rpg_membros;
create policy "membros: admin edita" on public.rpg_membros for update using (public.deck_e_admin()) with check (public.deck_e_admin());
drop policy if exists "membros: admin remove" on public.rpg_membros;
create policy "membros: admin remove" on public.rpg_membros for delete
  using (public.deck_e_admin() and user_id <> public.rpg_mestre_de(mesa_id));

drop policy if exists "posts: admin le" on public.rpg_posts;
create policy "posts: admin le" on public.rpg_posts for select using (public.deck_e_admin());
drop policy if exists "posts: admin apaga" on public.rpg_posts;
create policy "posts: admin apaga" on public.rpg_posts for delete using (public.deck_e_admin());

-- 4) RPG Solo: admin vê o progresso de todos
drop policy if exists "rpgsolo: admin ve" on public.rpgsolo_saves;
create policy "rpgsolo: admin ve" on public.rpgsolo_saves for select using (public.deck_e_admin());

-- 5) Lista de todas as mesas para o painel do admin
create or replace function public.rpg_admin_mesas()
returns table (id uuid, nome text, sistema text, status text, codigo text, mestre_id uuid, mestre_nome text,
               jogadores bigint, posts bigint, criado_em timestamptz, atividade_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.deck_e_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  return query
    select m.id, m.nome, m.sistema, m.status, m.codigo, m.mestre_id, p.name::text,
           (select count(*) from public.rpg_membros x where x.mesa_id = m.id and x.user_id <> m.mestre_id),
           (select count(*) from public.rpg_posts x where x.mesa_id = m.id),
           m.criado_em, m.atividade_em
    from public.rpg_mesas m left join public.profiles p on p.id = m.mestre_id
    order by m.atividade_em desc;
end $$;
revoke all on function public.rpg_admin_mesas() from public;
grant execute on function public.rpg_admin_mesas() to authenticated;

-- 6) Progresso de todos no RPG Solo
create or replace function public.rpg_admin_rpgsolo()
returns table (user_id uuid, nome text, aventura text, estado jsonb, atualizado_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.deck_e_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  return query
    select s.user_id, p.name::text, s.aventura, s.estado, s.atualizado_em
    from public.rpgsolo_saves s left join public.profiles p on p.id = s.user_id
    order by s.atualizado_em desc;
end $$;
revoke all on function public.rpg_admin_rpgsolo() from public;
grant execute on function public.rpg_admin_rpgsolo() to authenticated;

notify pgrst, 'reload schema';
