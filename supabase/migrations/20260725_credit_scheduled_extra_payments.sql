-- Уточнение логики кредитов (2026-07-25, доп. ТЗ): «ожидаемый» платёж (из credits.monthly_payment
-- + credits.next_payment_date) и «фактический» платёж (credit_payments + связанная transactions)
-- должны учитываться РОВНО один раз — сейчас record_credit_payment не различает обычный
-- (обязательный) платёж и дополнительное досрочное погашение: оба одинаково переносят
-- next_payment_date на месяц вперёд, что неверно для допогашения (спец. §11-12). Также не было
-- защиты от повторной отметки обычного платежа за один и тот же период (§22) и способа корректно
-- откатить remaining_amount/next_payment_date при редактировании/удалении платежа (§19).

alter table public.credit_payments
  add column if not exists payment_type text not null default 'scheduled',
  add column if not exists closes_scheduled_payment boolean not null default true,
  add column if not exists remaining_amount_before numeric,
  add column if not exists next_payment_date_before date,
  add column if not exists next_payment_date_after date;

alter table public.credit_payments
  drop constraint if exists credit_payments_payment_type_check;
alter table public.credit_payments
  add constraint credit_payments_payment_type_check check (payment_type in ('scheduled', 'extra'));

-- record_credit_payment: теперь принимает payment_type ('scheduled' — обычный обязательный
-- платёж, 'extra' — дополнительное досрочное погашение) и closes_scheduled_payment (для scheduled;
-- extra никогда не закрывает ожидание и не переносит дату). Сохраняет remaining/next_payment_date
-- «до» и «после» — это даёт update/delete_credit_payment точку отсчёта для отката задним числом.
-- Защита §22: два обычных закрывающих платежа за один календарный месяц для одного кредита
-- запрещены (ловится по exists-проверке внутри select ... for update — сериализуется построчно).
create or replace function public.record_credit_payment(
  p_credit_id uuid,
  p_payment_date date,
  p_amount numeric,
  p_payment_type text default 'scheduled',
  p_closes_scheduled_payment boolean default true,
  p_remaining_amount_after numeric default null,
  p_comment text default null
)
returns public.credit_payments
language plpgsql
security invoker
as $$
declare
  v_credit public.credits;
  v_remaining_before numeric;
  v_next_before date;
  v_remaining_after numeric;
  v_next_after date;
  v_is_closing boolean;
  v_tx_id uuid;
  v_payment public.credit_payments;
begin
  if p_payment_type not in ('scheduled', 'extra') then
    raise exception 'invalid payment_type: %', p_payment_type;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  select * into v_credit from public.credits where id = p_credit_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'credit not found or access denied';
  end if;

  v_is_closing := (p_payment_type = 'scheduled' and p_closes_scheduled_payment);

  if v_is_closing and exists (
    select 1 from public.credit_payments
    where credit_id = p_credit_id
      and payment_type = 'scheduled' and closes_scheduled_payment
      and date_trunc('month', payment_date) = date_trunc('month', p_payment_date)
  ) then
    raise exception 'ALREADY_MARKED_THIS_PERIOD';
  end if;

  v_remaining_before := v_credit.remaining_amount;
  v_next_before := v_credit.next_payment_date;
  v_remaining_after := coalesce(p_remaining_amount_after, greatest(coalesce(v_remaining_before, 0) - p_amount, 0));
  v_next_after := case
    when v_is_closing and v_next_before is not null then (v_next_before + interval '1 month')::date
    else v_next_before
  end;

  insert into public.transactions (kind, category, subcategory, amount, date, comment, user_id, credit_id)
  values ('expense', 'Кредит', v_credit.name, p_amount, p_payment_date, p_comment, auth.uid(), p_credit_id)
  returning id into v_tx_id;

  insert into public.credit_payments (
    user_id, credit_id, payment_date, amount, payment_type, closes_scheduled_payment,
    remaining_amount_before, remaining_amount_after, next_payment_date_before, next_payment_date_after,
    notes, transaction_id
  )
  values (
    auth.uid(), p_credit_id, p_payment_date, p_amount, p_payment_type, v_is_closing,
    v_remaining_before, v_remaining_after, v_next_before, case when v_is_closing then v_next_after else null end,
    p_comment, v_tx_id
  )
  returning * into v_payment;

  update public.credits
  set remaining_amount = v_remaining_after,
      next_payment_date = v_next_after,
      status = case when v_remaining_after <= 0 then 'paid' else status end,
      updated_at = now()
  where id = p_credit_id;

  return v_payment;
end;
$$;

grant execute on function public.record_credit_payment(uuid, date, numeric, text, boolean, numeric, text) to authenticated;

-- Старая 5-параметрическая перегрузка (до payment_type/closes_scheduled_payment) больше не должна
-- существовать отдельно — CREATE OR REPLACE с новой сигнатурой добавляет функцию, не заменяет
-- старую (разное число параметров = разные функции в Postgres), поэтому старую вычищаем явно.
drop function if exists public.record_credit_payment(uuid, date, numeric, numeric, text);

-- update_credit_payment: помимо синхронизации даты/суммы/комментария со связанной операцией
-- (как раньше), теперь также синхронизирует credits.remaining_amount и (для scheduled+closing)
-- next_payment_date — НО только если редактируемый платёж самый последний по времени для этого
-- кредита (created_at). Правка более старого платежа истории не пересчитывает сегодняшнее
-- состояние кредита задним числом — только собственные remaining_amount_after/notes/дату/сумму
-- этой записи и связанной операции (§19: не пересчитывать чужую историю).
create or replace function public.update_credit_payment(
  p_payment_id uuid,
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
  v_payment public.credit_payments;
  v_is_latest boolean;
  v_new_remaining_after numeric;
  v_new_next_after date;
begin
  select * into v_payment from public.credit_payments where id = p_payment_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'payment not found or access denied';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  select not exists (
    select 1 from public.credit_payments
    where credit_id = v_payment.credit_id and created_at > v_payment.created_at
  ) into v_is_latest;

  v_new_remaining_after := coalesce(p_remaining_amount_after, greatest(coalesce(v_payment.remaining_amount_before, 0) - p_amount, 0));
  v_new_next_after := case
    when v_payment.closes_scheduled_payment and v_payment.next_payment_date_before is not null
      then (v_payment.next_payment_date_before + interval '1 month')::date
    else v_payment.next_payment_date_after
  end;

  update public.credit_payments
  set payment_date = p_payment_date,
      amount = p_amount,
      remaining_amount_after = v_new_remaining_after,
      next_payment_date_after = case when v_payment.closes_scheduled_payment then v_new_next_after else next_payment_date_after end,
      notes = p_comment
  where id = p_payment_id
  returning * into v_payment;

  if v_payment.transaction_id is not null then
    update public.transactions
    set date = p_payment_date, amount = p_amount, comment = p_comment
    where id = v_payment.transaction_id and user_id = auth.uid();
  end if;

  if v_is_latest then
    update public.credits
    set remaining_amount = v_new_remaining_after,
        next_payment_date = case when v_payment.closes_scheduled_payment then v_new_next_after else next_payment_date end,
        status = case when v_new_remaining_after <= 0 then 'paid' else 'active' end,
        updated_at = now()
    where id = v_payment.credit_id;
  end if;

  return v_payment;
end;
$$;

grant execute on function public.update_credit_payment(uuid, date, numeric, numeric, text) to authenticated;

-- delete_credit_payment: откатывает credits.remaining_amount/next_payment_date к значениям ДО
-- этого платежа (сохранённым при его создании), затем удаляет операцию (каскадом уносит и саму
-- запись credit_payments — FK transaction_id ... on delete cascade). Статус пересчитывается из
-- восстановленного остатка, а не просто "active" — если это был не последний платёж, а долг и
-- так уже был закрыт раньше, восстановление не должно случайно снять статус 'paid'.
create or replace function public.delete_credit_payment(p_payment_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_payment public.credit_payments;
  v_restored_remaining numeric;
begin
  select * into v_payment from public.credit_payments where id = p_payment_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'payment not found or access denied';
  end if;

  v_restored_remaining := coalesce(v_payment.remaining_amount_before, (select remaining_amount from public.credits where id = v_payment.credit_id));

  update public.credits
  set remaining_amount = v_restored_remaining,
      next_payment_date = coalesce(v_payment.next_payment_date_before, next_payment_date),
      status = case when v_restored_remaining <= 0 then 'paid' else 'active' end,
      updated_at = now()
  where id = v_payment.credit_id;

  if v_payment.transaction_id is not null then
    delete from public.transactions where id = v_payment.transaction_id and user_id = auth.uid();
  end if;
  -- Если операция уже была удалена отдельно (transaction_id указывал в никуда) — каскад выше не
  -- сработал, чистим запись платежа явно, чтобы она не зависла без связанной операции.
  delete from public.credit_payments where id = p_payment_id;
end;
$$;

grant execute on function public.delete_credit_payment(uuid) to authenticated;
