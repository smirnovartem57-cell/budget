-- Расчёт цели по актуальному месяцу вместо усреднения ненадёжной старой истории (доп. к ТЗ
-- 2026-07-25 «Кредиты × Цели»). Уже применена к живой базе; файл безопасен для повторного
-- запуска. Backfill не переопределяет уже заданный reference_month (WHERE ... is null).

alter table public.financial_goals
  add column if not exists calculation_basis text not null default 'reference_month_projection',
  add column if not exists reference_month date;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'financial_goals_calculation_basis_check') then
    alter table public.financial_goals
      add constraint financial_goals_calculation_basis_check
      check (calculation_basis in ('reference_month_projection', 'reference_month_actual', 'completed_months_average', 'manual'));
  end if;
end $$;

-- Первоначальный расчётный месяц для уже существующих целей — июль 2026 (см. ТЗ).
update public.financial_goals
set reference_month = '2026-07-01'
where reference_month is null;
