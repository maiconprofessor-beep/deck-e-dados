-- =====================================================================
-- FICHAS PRONTAS da Mesa de RPG — Deck e Dados
-- O mestre cadastra personagens prontos (ex.: os heróis do livro) e os
-- jogadores escolhem um. Rode uma vez no Supabase: SQL Editor > cole > Run.
-- Pode rodar de novo sem problema.
-- =====================================================================
alter table public.rpg_mesas add column if not exists prontas jsonb not null default '[]'::jsonb;
alter table public.rpg_mesas drop constraint if exists rpg_mesas_prontas_tam;
alter table public.rpg_mesas add constraint rpg_mesas_prontas_tam
  check (jsonb_typeof(prontas) = 'array' and octet_length(prontas::text) <= 200000);
-- Quem pode alterar já está nas regras da mesa: só o mestre (política "mesas: mestre altera").
notify pgrst, 'reload schema';
