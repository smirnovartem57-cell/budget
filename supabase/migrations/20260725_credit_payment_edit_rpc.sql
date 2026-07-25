-- Исправление UX кредитных платежей (2026-07-25): редактирование платежа из истории кредита
-- должно синхронно менять credit_payments И связанную transactions — иначе они расходятся.
-- Удаление платежа обходится без отдельного RPC: credit_payments.transaction_id уже
-- on delete cascade (20260725_credit_payment_rpc.sql), поэтому один DELETE FROM transactions
-- атомарно убирает и операцию, и запись платежа.

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
begin
  select * into v_payment from public.credit_payments where id = p_payment_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'payment not found or access denied';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  update public.credit_payments
  set payment_date = p_payment_date,
      amount = p_amount,
      remaining_amount_after = p_remaining_amount_after,
      notes = p_comment
  where id = p_payment_id
  returning * into v_payment;

  if v_payment.transaction_id is not null then
    update public.transactions
    set date = p_payment_date, amount = p_amount, comment = p_comment
    where id = v_payment.transaction_id and user_id = auth.uid();
  end if;

  return v_payment;
end;
$$;

grant execute on function public.update_credit_payment(uuid, date, numeric, numeric, text) to authenticated;
