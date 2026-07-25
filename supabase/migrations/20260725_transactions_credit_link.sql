-- Явная связь операций с кредитами (доп. к ТЗ 2026-07-25 «Исправление расчёта свободного
-- остатка»): без этой связи невозможно гарантированно исключить кредитные платежи из
-- «Повседневных расходов», если пользователь внёс их как обычную операцию. Не сопоставлять по
-- названию/сумме/категории/банку — только явный выбор пользователя. Файл безопасен для
-- повторного запуска; уже применён к живой базе.

alter table public.transactions
  add column if not exists credit_id uuid references public.credits(id) on delete set null,
  add column if not exists credit_payment_type text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'transactions_credit_payment_type_check') then
    alter table public.transactions
      add constraint transactions_credit_payment_type_check
      check (credit_payment_type is null or credit_payment_type in ('minimum', 'extra'));
  end if;
end $$;

-- §3: RLS — привязать операцию можно только к своему кредиту. USING (видимость строк) не
-- меняется, только WITH CHECK (запись) получает дополнительное условие поверх существующего.
alter policy "scoped transactions" on public.transactions
  with check (
    (user_id is null or user_id = auth.uid())
    and (
      credit_id is null
      or exists (select 1 from public.credits c where c.id = transactions.credit_id and c.user_id = auth.uid())
    )
  );

-- §7 (альтернативный вариант архитектуры): кредит может быть явно связан с одной активной
-- регулярной группой расходов — тогда его минимальный платёж уже сидит внутри «Регулярных
-- расходов» и не должен вычитаться отдельной строкой. Не FK на recurring_group_id — это не
-- первичный ключ, а группирующее значение в transactions; связь только через явный выбор в
-- форме кредита (getActiveRecurringGroups()), не автоматическим сопоставлением.
alter table public.credits
  add column if not exists mandatory_recurring_group_id uuid;
