-- Ускорение погашения кредитов фиксированной доплатой (доп. к ТЗ 2026-07-25 «Кредиты × Цели»).
-- Уже применена к живой базе; файл безопасен для повторного запуска. Не меняет существующие
-- расчёты: для уже созданных целей debt_acceleration_mode остаётся значением по умолчанию
-- 'auto_scenario', что соответствует прежнему (единственному) поведению.

alter table public.financial_goals
  add column if not exists debt_acceleration_mode text not null default 'auto_scenario',
  add column if not exists extra_monthly_debt_payment numeric(14,2) not null default 0,
  add column if not exists redirect_extra_debt_payment_to_goal boolean not null default true;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'financial_goals_debt_acceleration_mode_check') then
    alter table public.financial_goals
      add constraint financial_goals_debt_acceleration_mode_check
      check (debt_acceleration_mode in ('auto_scenario', 'fixed_monthly'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'financial_goals_extra_monthly_debt_payment_check') then
    alter table public.financial_goals
      add constraint financial_goals_extra_monthly_debt_payment_check
      check (extra_monthly_debt_payment >= 0);
  end if;
end $$;
