-- RPG Solo: progresso das aventuras, um registro por jogador e por aventura.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run.

create table if not exists public.rpgsolo_saves (
  user_id       uuid        not null references auth.users(id) on delete cascade,
  aventura      text        not null,
  estado        jsonb       not null,
  atualizado_em timestamptz not null default now(),
  primary key (user_id, aventura)
);

alter table public.rpgsolo_saves enable row level security;

-- Cada jogador só vê e mexe no próprio progresso.
drop policy if exists "rpgsolo: ver o proprio" on public.rpgsolo_saves;
create policy "rpgsolo: ver o proprio" on public.rpgsolo_saves
  for select using (auth.uid() = user_id);

drop policy if exists "rpgsolo: criar o proprio" on public.rpgsolo_saves;
create policy "rpgsolo: criar o proprio" on public.rpgsolo_saves
  for insert with check (auth.uid() = user_id);

drop policy if exists "rpgsolo: atualizar o proprio" on public.rpgsolo_saves;
create policy "rpgsolo: atualizar o proprio" on public.rpgsolo_saves
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "rpgsolo: apagar o proprio" on public.rpgsolo_saves;
create policy "rpgsolo: apagar o proprio" on public.rpgsolo_saves
  for delete using (auth.uid() = user_id);
