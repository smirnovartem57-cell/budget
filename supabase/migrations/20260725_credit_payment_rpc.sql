-- Упрощение учёта кредитов (план 2026-07-25, задачи #166-171): «Отметить платёж» перестаёт быть
-- отдельной записью без расхода — теперь это единственный и атомарный способ внести платёж по
-- кредиту. RPC record_credit_payment() за один вызов (1) создаёт credit_payments, (2) создаёт
-- связанную расходную операцию (category='Кредит', уже существует как top-level категория),
-- (3) обновляет остаток долга и переносит next_payment_date. Кредит теперь ВСЕГДА отдельная
-- статья в расчёте цели — двойной учёт (кредит внутри регулярной группы расходов) структурно
-- исключён, поэтому альтернативная архитектура из 20260725_transactions_credit_link.sql
-- (mandatory_recurring_group_id, payment_already_counted_in_mandatory) и ручная привязка
-- произвольной операции к кредиту (credit_payment_type) убираются.
--
-- Аудит перед миграцией (2026-07-25): credit_payments пуст (0 строк) — RPC ни разу не
-- использовался для платежа; ни у одного кредита не заполнен mandatory_recurring_group_id;
-- ни одна transactions-строка не связана через credit_id. Менять схему можно без переноса данных.

alter table public.credit_payments
  add column if not exists transaction_id uuid references public.transactions(id) on delete cascade;

alter table public.credits
  drop column if exists mandatory_recurring_group_id,
  drop column if exists payment_already_counted_in_mandatory;

alter table public.transactions
  drop constraint if exists transactions_credit_payment_type_check;
alter table public.transactions
  drop column if exists credit_payment_type;

-- security invoker (по умолчанию) — RPC не обходит RLS, а выполняется от имени вызывающего
-- пользователя, поэтому обычные политики "_own" на credits/credit_payments и "scoped
-- transactions" на transactions продолжают действовать как единственная граница доступа.
create or replace function public.record_credit_payment(
  p_credit_id uuid,
  p_payment_date date,
  p_amount numeric,
  p_remaining_amount_after numeric default null,
  p_comment text default null
)
returns public.credit_payments
language plpgsql
security invoker
as $$
declare
  v_credit public.credits;
  v_remaining_after numeric;
  v_tx_id uuid;
  v_payment public.credit_payments;
begin
  select * into v_credit from public.credits where id = p_credit_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'credit not found or access denied';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  v_remaining_after := coalesce(p_remaining_amount_after, greatest(coalesce(v_credit.remaining_amount, 0) - p_amount, 0));

  insert into public.transactions (kind, category, subcategory, amount, date, comment, user_id, credit_id)
  values ('expense', 'Кредит', v_credit.name, p_amount, p_payment_date, p_comment, auth.uid(), p_credit_id)
  returning id into v_tx_id;

  insert into public.credit_payments (user_id, credit_id, payment_date, amount, remaining_amount_after, notes, transaction_id)
  values (auth.uid(), p_credit_id, p_payment_date, p_amount, v_remaining_after, p_comment, v_tx_id)
  returning * into v_payment;

  -- Perенос next_payment_date на месяц вперёд с автоклампом дня (date + interval '1 month' в
  -- Postgres уже клампит - 31 янв + 1 мес = 28/29 фев), только если дата вообще была задана.
  update public.credits
  set remaining_amount = v_remaining_after,
      next_payment_date = case when next_payment_date is not null then (next_payment_date + interval '1 month')::date else next_payment_date end,
      status = case when v_remaining_after <= 0 then 'paid' else status end,
      updated_at = now()
  where id = p_credit_id;

  return v_payment;
end;
$$;

grant execute on function public.record_credit_payment(uuid, date, numeric, numeric, text) to authenticated;
