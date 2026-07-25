-- Единоразовый backfill стратегии для кредитов, уже включённых в прогноз цели, применённый по
-- credit_type (ипотека → «выплачивать параллельно», остальные → «закрыть до накопления»).
-- Уже применён к живой базе. WHERE-условие ограничивает повтор строками, которые всё ещё
-- на значениях по умолчанию колонки (не редактировались вручную после первого запуска) — это
-- не destructive re-run: строки, где пользователь уже сохранил свой выбор в форме кредита, не
-- перезаписываются повторным запуском этого файла.
--
-- Известный нюанс из данных: запись «Ипотека» на момент этой миграции имела credit_type =
-- 'consumer' (не 'mortgage'), поэтому backfill отнёс её к close_before_goal. credit_type этой
-- записи НЕ переклассифицируется по названию — исправление стратегии для неё делается вручную,
-- через форму кредита («Выплачивать параллельно»), отдельным явным действием пользователя.

update public.credits
set
  goal_payoff_strategy = case
    when credit_type = 'mortgage' then 'scheduled_during_goal'
    else 'close_before_goal'
  end,
  allow_extra_payment_before_goal = case
    when credit_type = 'mortgage' then false
    else true
  end
where include_in_goal_forecast = true
  and goal_payoff_strategy = 'close_before_goal'
  and allow_extra_payment_before_goal = true;
