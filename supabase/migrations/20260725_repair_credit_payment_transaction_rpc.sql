-- Срочный фикс (2026-07-25): деплой-лаг между Supabase-миграцией record_credit_payment (15:58:17
-- UTC) и мёржем фронтенда, который её вызывает (4f93ed4, смёржен позже) привёл к тому, что часть
-- платежей по кредиту (как минимум платёж 48143 ₽ от 25.07.2026, credit_payments.id=
-- d1c24146-15a3-4c21-98bf-5c55b3fe2600) была записана СТАРЫМ опубликованным кодом — прямым
-- insert в credit_payments без создания связанной расходной операции. transaction_id у таких
-- платежей null, история расходов их не показывает.
--
-- Повторный вызов record_credit_payment для них недопустим: он создал бы вторую строку
-- credit_payments и повторно уменьшил бы remaining_amount / перенёс next_payment_date.
-- repair_credit_payment_transaction чинит только отсутствующую транзакцию у УЖЕ существующего
-- платежа, ничего не создавая и не трогая в credit_payments/credits, кроме самого
-- transaction_id. Идемпотентна: если transaction_id уже заполнен (и такая операция ещё
-- существует), просто возвращает платёж как есть.
create or replace function public.repair_credit_payment_transaction(
  p_payment_id uuid
)
returns public.credit_payments
language plpgsql
security invoker
as $$
declare
  v_payment public.credit_payments;
  v_credit public.credits;
  v_existing_tx_id uuid;
  v_tx_id uuid;
begin
  select * into v_payment
  from public.credit_payments
  where id = p_payment_id and user_id = auth.uid()
  for update;
  if not found then
    raise exception 'payment not found or access denied';
  end if;

  if v_payment.transaction_id is not null then
    select id into v_existing_tx_id from public.transactions where id = v_payment.transaction_id;
    if v_existing_tx_id is not null then
      -- Уже связано и операция существует — ничего не создаём, возвращаем как есть.
      return v_payment;
    end if;
  end if;

  select * into v_credit
  from public.credits
  where id = v_payment.credit_id and user_id = auth.uid()
  for update;
  if not found then
    raise exception 'credit not found or access denied';
  end if;

  insert into public.transactions (kind, category, subcategory, amount, date, comment, user_id, credit_id)
  values ('expense', 'Кредит', v_credit.name, v_payment.amount, v_payment.payment_date, v_payment.notes, auth.uid(), v_payment.credit_id)
  returning id into v_tx_id;

  update public.credit_payments
  set transaction_id = v_tx_id
  where id = v_payment.id
  returning * into v_payment;

  return v_payment;
end;
$$;

grant execute on function public.repair_credit_payment_transaction(uuid) to authenticated;
