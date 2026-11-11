-- =====================================================================
-- MESA DE RPG (play-by-post) — Deck e Dados
-- O mestre narra, cada jogador responde quando puder. Tudo fica salvo.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run.
-- Pode rodar de novo sem problema (o script é idempotente).
-- =====================================================================

-- ---------- TABELAS ----------
create table if not exists public.rpg_mesas (
  id           uuid        primary key default gen_random_uuid(),
  nome         text        not null check (char_length(nome) between 2 and 80),
  sistema      text        not null default '' check (char_length(sistema) <= 60),
  descricao    text        not null default '' check (char_length(descricao) <= 2000),
  resumo       text        not null default '' check (char_length(resumo) <= 8000),
  mestre_id    uuid        not null references auth.users(id) on delete cascade,
  codigo       text        not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  status       text        not null default 'ativa' check (status in ('ativa', 'pausada', 'encerrada')),
  aguardando   uuid[]      not null default '{}',
  criado_em    timestamptz not null default now(),
  atividade_em timestamptz not null default now()
);

create table if not exists public.rpg_membros (
  mesa_id     uuid        not null references public.rpg_mesas(id) on delete cascade,
  user_id     uuid        not null references auth.users(id) on delete cascade,
  personagem  text        not null default '' check (char_length(personagem) <= 60),
  ficha       text        not null default '' check (char_length(ficha) <= 6000),
  pv_atual    int,
  pv_max      int,
  ultimo_lido timestamptz not null default now(),
  entrou_em   timestamptz not null default now(),
  primary key (mesa_id, user_id)
);

create table if not exists public.rpg_posts (
  id         bigint      generated always as identity primary key,
  mesa_id    uuid        not null references public.rpg_mesas(id) on delete cascade,
  autor_id   uuid        references auth.users(id) on delete set null,
  tipo       text        not null check (tipo in ('narracao', 'cena', 'acao', 'fala', 'ooc', 'rolagem', 'sistema')),
  personagem text        not null default '' check (char_length(personagem) <= 60),
  texto      text        not null default '' check (char_length(texto) <= 8000),
  rolagem    jsonb,
  para_id    uuid        references auth.users(id) on delete set null,   -- sussurro (mensagem privada)
  editado    boolean     not null default false,
  criado_em  timestamptz not null default now()
);
create index if not exists rpg_posts_mesa_idx on public.rpg_posts (mesa_id, id);
create index if not exists rpg_membros_user_idx on public.rpg_membros (user_id);

-- ---------- FUNÇÕES DE APOIO (evitam recursão nas regras) ----------
create or replace function public.rpg_e_membro(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from rpg_membros where mesa_id = m and user_id = auth.uid());
$$;

create or replace function public.rpg_e_mestre(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from rpg_mesas where id = m and mestre_id = auth.uid());
$$;

create or replace function public.rpg_mestre_de(m uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select mestre_id from rpg_mesas where id = m;
$$;

-- ---------- REGRAS DE ACESSO (RLS) ----------
alter table public.rpg_mesas   enable row level security;
alter table public.rpg_membros enable row level security;
alter table public.rpg_posts   enable row level security;

-- Mesas: só quem participa vê; só o mestre altera ou apaga. Criar é pela função rpg_criar_mesa.
drop policy if exists "mesas: participantes veem" on public.rpg_mesas;
create policy "mesas: participantes veem" on public.rpg_mesas for select using (public.rpg_e_membro(id));
drop policy if exists "mesas: mestre altera" on public.rpg_mesas;
create policy "mesas: mestre altera" on public.rpg_mesas for update using (mestre_id = auth.uid()) with check (mestre_id = auth.uid());
drop policy if exists "mesas: mestre apaga" on public.rpg_mesas;
create policy "mesas: mestre apaga" on public.rpg_mesas for delete using (mestre_id = auth.uid());

-- Membros: quem participa vê os colegas; cada um edita a própria ficha; o mestre edita qualquer ficha
-- (ex.: pontos de vida). Sair da mesa: o próprio jogador. Remover jogador: o mestre.
drop policy if exists "membros: participantes veem" on public.rpg_membros;
create policy "membros: participantes veem" on public.rpg_membros for select using (public.rpg_e_membro(mesa_id));
drop policy if exists "membros: editar ficha" on public.rpg_membros;
create policy "membros: editar ficha" on public.rpg_membros for update
  using (user_id = auth.uid() or public.rpg_e_mestre(mesa_id))
  with check (user_id = auth.uid() or public.rpg_e_mestre(mesa_id));
drop policy if exists "membros: sair ou remover" on public.rpg_membros;
create policy "membros: sair ou remover" on public.rpg_membros for delete
  using ((user_id = auth.uid() and user_id <> public.rpg_mestre_de(mesa_id)) or (public.rpg_e_mestre(mesa_id) and user_id <> auth.uid()));

-- Mensagens: participantes leem; sussurros só para quem enviou, quem recebeu e o mestre.
drop policy if exists "posts: participantes leem" on public.rpg_posts;
create policy "posts: participantes leem" on public.rpg_posts for select using (
  public.rpg_e_membro(mesa_id)
  and (para_id is null or autor_id = auth.uid() or para_id = auth.uid() or public.rpg_e_mestre(mesa_id))
);
-- Escrever: narração e nova cena só o mestre; rolagens só pela função rpg_rolar (dados honestos);
-- jogador só sussurra para o mestre.
drop policy if exists "posts: participantes escrevem" on public.rpg_posts;
create policy "posts: participantes escrevem" on public.rpg_posts for insert with check (
  autor_id = auth.uid()
  and public.rpg_e_membro(mesa_id)
  and tipo in ('narracao', 'cena', 'acao', 'fala', 'ooc')
  and (tipo not in ('narracao', 'cena') or public.rpg_e_mestre(mesa_id))
  and (para_id is null or para_id = public.rpg_mestre_de(mesa_id) or public.rpg_e_mestre(mesa_id))
  and (para_id is null or exists (select 1 from public.rpg_membros x where x.mesa_id = rpg_posts.mesa_id and x.user_id = rpg_posts.para_id))
);
drop policy if exists "posts: autor edita" on public.rpg_posts;
create policy "posts: autor edita" on public.rpg_posts for update
  using (autor_id = auth.uid() and tipo not in ('rolagem', 'sistema'))
  with check (autor_id = auth.uid() and tipo not in ('rolagem', 'sistema'));
drop policy if exists "posts: autor ou mestre apaga" on public.rpg_posts;
create policy "posts: autor ou mestre apaga" on public.rpg_posts for delete
  using ((autor_id = auth.uid() and tipo <> 'rolagem') or public.rpg_e_mestre(mesa_id));

-- Só estas colunas podem ser alteradas pelo site (ninguém troca o mestre, o código ou o autor).
revoke update on public.rpg_mesas   from anon, authenticated;
revoke update on public.rpg_membros from anon, authenticated;
revoke update on public.rpg_posts   from anon, authenticated;
grant  update (nome, sistema, descricao, resumo, status, aguardando) on public.rpg_mesas   to authenticated;
grant  update (personagem, ficha, pv_atual, pv_max, ultimo_lido)      on public.rpg_membros to authenticated;
grant  update (texto, personagem, editado)                             on public.rpg_posts   to authenticated;
revoke insert on public.rpg_mesas, public.rpg_membros from anon, authenticated;

-- ---------- AÇÕES (funções chamadas pelo site) ----------
-- Criar mesa: cria a mesa e já coloca o mestre como participante.
create or replace function public.rpg_criar_mesa(p_nome text, p_sistema text default '', p_descricao text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare nova uuid;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para criar uma mesa.'; end if;
  if (select count(*) from rpg_mesas where mestre_id = auth.uid() and status <> 'encerrada') >= 10 then
    raise exception 'Você já mestra 10 mesas ativas. Encerre uma antes de criar outra.';
  end if;
  insert into rpg_mesas (nome, sistema, descricao, mestre_id)
  values (left(trim(p_nome), 80), left(trim(coalesce(p_sistema, '')), 60), left(trim(coalesce(p_descricao, '')), 2000), auth.uid())
  returning id into nova;
  insert into rpg_membros (mesa_id, user_id, personagem) values (nova, auth.uid(), 'Mestre');
  insert into rpg_posts (mesa_id, autor_id, tipo, texto) values (nova, auth.uid(), 'sistema', 'A mesa foi criada. Que comece a aventura!');
  return nova;
end $$;

-- Entrar com o código do convite.
create or replace function public.rpg_entrar(p_codigo text, p_personagem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m record; nome_p text;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para participar.'; end if;
  select * into m from rpg_mesas where codigo = upper(trim(p_codigo));
  if not found then raise exception 'Código não encontrado. Confira com o mestre.'; end if;
  if m.status = 'encerrada' then raise exception 'Esta mesa já foi encerrada.'; end if;
  if exists (select 1 from rpg_membros where mesa_id = m.id and user_id = auth.uid()) then return m.id; end if;
  if (select count(*) from rpg_membros where mesa_id = m.id) >= 12 then raise exception 'A mesa está cheia (12 participantes).'; end if;
  nome_p := left(trim(coalesce(p_personagem, '')), 60);
  if nome_p = '' then raise exception 'Dê um nome ao seu personagem.'; end if;
  insert into rpg_membros (mesa_id, user_id, personagem) values (m.id, auth.uid(), nome_p);
  insert into rpg_posts (mesa_id, autor_id, tipo, texto) values (m.id, auth.uid(), 'sistema', nome_p || ' entrou na mesa.');
  return m.id;
end $$;

-- Rolar dados no servidor (ninguém consegue "escolher" o resultado).
-- Formatos: 1d20, d20, 2d6+3, 4d6-1, d100. Rolagem secreta: só o mestre vê.
create or replace function public.rpg_rolar(p_mesa uuid, p_expr text, p_motivo text default '', p_personagem text default '', p_secreta boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare m record; mm text[]; n int; f int; md int := 0; dados int[] := '{}'; tot int := 0; r int; i int; para uuid := null; novo bigint; ex text;
begin
  if auth.uid() is null or not rpg_e_membro(p_mesa) then raise exception 'Você não participa desta mesa.'; end if;
  select * into m from rpg_mesas where id = p_mesa;
  if m.status = 'encerrada' then raise exception 'Esta mesa está encerrada.'; end if;
  mm := regexp_match(lower(replace(coalesce(p_expr, ''), ' ', '')), '^(\d{0,2})d(\d{1,4})([+-]\d{1,3})?$');
  if mm is null then raise exception 'Use o formato 1d20, 2d6+3 ou d100.'; end if;
  n := coalesce(nullif(mm[1], '')::int, 1); f := mm[2]::int;
  if mm[3] is not null then md := mm[3]::int; end if;
  if n < 1 or n > 50 or f < 2 or f > 1000 then raise exception 'Use de 1 a 50 dados, com 2 a 1000 lados.'; end if;
  for i in 1..n loop r := 1 + floor(random() * f)::int; dados := dados || r; tot := tot + r; end loop;
  tot := tot + md;
  ex := n || 'd' || f || case when md > 0 then '+' || md when md < 0 then md::text else '' end;
  if p_secreta then para := m.mestre_id; end if;
  insert into rpg_posts (mesa_id, autor_id, tipo, personagem, texto, rolagem, para_id)
  values (p_mesa, auth.uid(), 'rolagem', left(coalesce(p_personagem, ''), 60), left(coalesce(p_motivo, ''), 300),
          jsonb_build_object('expr', ex, 'dados', to_jsonb(dados), 'mod', md, 'total', tot, 'faces', f), para)
  returning id into novo;
  return novo;
end $$;

-- Minhas mesas, com mensagens novas e se é a minha vez.
create or replace function public.rpg_minhas_mesas()
returns table (id uuid, nome text, sistema text, status text, mestre_id uuid, atividade_em timestamptz, jogadores int, novos int, minha_vez boolean)
language sql stable security definer set search_path = public as $$
  select m.id, m.nome, m.sistema, m.status, m.mestre_id, m.atividade_em,
         (select count(*) from rpg_membros x where x.mesa_id = m.id)::int,
         (select count(*) from rpg_posts p where p.mesa_id = m.id and p.criado_em > me.ultimo_lido
            and p.autor_id is distinct from auth.uid()
            and (p.para_id is null or p.para_id = auth.uid() or m.mestre_id = auth.uid()))::int,
         auth.uid() = any (m.aguardando)
  from rpg_mesas m join rpg_membros me on me.mesa_id = m.id and me.user_id = auth.uid()
  order by m.atividade_em desc;
$$;

-- Ao postar: atualiza a "última atividade" e tira o jogador da lista "esperando resposta".
create or replace function public.rpg_post_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update rpg_mesas set atividade_em = now(),
    aguardando = case when new.tipo in ('acao', 'fala', 'rolagem') then array_remove(aguardando, new.autor_id) else aguardando end
  where id = new.mesa_id;
  return new;
end $$;
drop trigger if exists rpg_post_depois on public.rpg_posts;
create trigger rpg_post_depois after insert on public.rpg_posts for each row execute function public.rpg_post_depois();

revoke execute on function public.rpg_criar_mesa(text, text, text), public.rpg_entrar(text, text),
  public.rpg_rolar(uuid, text, text, text, boolean), public.rpg_minhas_mesas() from anon;

-- ---------- TEMPO REAL (mensagens aparecem sem recarregar) ----------
do $$ begin
  begin alter publication supabase_realtime add table public.rpg_posts; exception when others then null; end;
end $$;
