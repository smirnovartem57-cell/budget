-- Настройки цели, связанные с очередью погашения приоритетных кредитов (ТЗ 2026-07-25,
-- «Кредиты × Цели», §3). Уже применена к живой базе; файл безопасен для повторного запуска.

alter table public.financial_goals
  add column if not exists debt_first_strategy boolean not null default true,
  add column if not exists pre_debt_goal_allocation_percent numeric(5,2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'financial_goals_pre_debt_allocation_check'
  ) then
    alter table public.financial_goals
      add constraint financial_goals_pre_debt_allocation_check
      check (pre_debt_goal_allocation_percent between 0 and 30);
  end if;
end $$;
