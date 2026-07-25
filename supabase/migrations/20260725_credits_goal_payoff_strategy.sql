-- Стратегия учёта кредита в прогнозе цели (ТЗ 2026-07-25, «Кредиты × Цели»).
-- Уже применена к живой базе через apply_migration; этот файл — сохранённая копия для
-- репозитория, безопасна для повторного запуска (add column if not exists).

alter table public.credits
  add column if not exists goal_payoff_strategy text not null default 'close_before_goal',
  add column if not exists goal_priority_order smallint,
  add column if not exists allow_extra_payment_before_goal boolean not null default true;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'credits_goal_payoff_strategy_check'
  ) then
    alter table public.credits
      add constraint credits_goal_payoff_strategy_check
      check (goal_payoff_strategy in ('close_before_goal', 'scheduled_during_goal'));
  end if;
end $$;
