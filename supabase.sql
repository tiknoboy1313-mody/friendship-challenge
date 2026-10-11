-- Friendship Challenge schema for Supabase. Run this entire file in SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.fc_questions (
  id uuid primary key default gen_random_uuid(),
  question_text text not null check (char_length(question_text) between 3 and 300),
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 8),
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.fc_quizzes (
  id uuid primary key default gen_random_uuid(),
  creator_name text not null,
  creator_answers jsonb not null default '{}'::jsonb,
  question_snapshot jsonb not null default '[]'::jsonb,
  share_code text not null unique,
  owner_token text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.fc_responses (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.fc_quizzes(id) on delete cascade,
  participant_name text not null,
  answers jsonb not null default '{}'::jsonb,
  score integer not null check (score between 0 and 100),
  created_at timestamptz not null default now()
);
create index if not exists fc_responses_quiz_id_idx on public.fc_responses(quiz_id);
create index if not exists fc_quizzes_created_at_idx on public.fc_quizzes(created_at desc);

alter table public.fc_questions enable row level security;
alter table public.fc_quizzes enable row level security;
alter table public.fc_responses enable row level security;
revoke all on public.fc_questions, public.fc_quizzes, public.fc_responses from anon, authenticated;

-- Only users whose Auth app_metadata contains {"role":"admin"} can use admin functions.
create or replace function public.fc_is_admin() returns boolean
language sql stable security definer set search_path = public, auth
as $$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $$;

create or replace function public.fc_public_questions() returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', question_text, 'options', options) order by position, created_at), '[]'::jsonb)
  from public.fc_questions where active = true;
$$;

create or replace function public.fc_create_quiz(p_creator_name text, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_share text; v_owner text; v_snapshot jsonb; v_count integer;
begin
  if p_creator_name is null or char_length(trim(p_creator_name)) < 2 or char_length(p_creator_name) > 80 then raise exception 'اكتب اسمًا صحيحًا'; end if;
  if jsonb_typeof(p_answers) <> 'object' then raise exception 'الإجابات غير صحيحة'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', question_text, 'options', options) order by position, created_at), '[]'::jsonb), count(*)
  into v_snapshot, v_count from public.fc_questions where active = true;
  if v_count < 1 then raise exception 'لا توجد أسئلة متاحة الآن'; end if;
  if (select count(*) from jsonb_object_keys(p_answers)) <> v_count then raise exception 'أجب عن كل الأسئلة'; end if;
  if exists (select 1 from public.fc_questions q where q.active = true and (not (p_answers ? q.id::text) or not exists (select 1 from jsonb_array_elements_text(q.options) as opt(value) where opt.value = p_answers ->> q.id::text))) then raise exception 'توجد إجابة غير صالحة'; end if;
  v_share := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  v_owner := encode(gen_random_bytes(24), 'hex');
  insert into public.fc_quizzes(creator_name, creator_answers, question_snapshot, share_code, owner_token)
  values (trim(p_creator_name), p_answers, v_snapshot, v_share, v_owner) returning id into v_id;
  return jsonb_build_object('share_code', v_share, 'owner_token', v_owner, 'creator_name', trim(p_creator_name));
end $$;

create or replace function public.fc_quiz_questions(p_share_code text) returns jsonb
language plpgsql stable security definer set search_path = public
as $$ declare v_snapshot jsonb; v_creator text;
begin
  select question_snapshot, creator_name into v_snapshot, v_creator from public.fc_quizzes where share_code = upper(trim(p_share_code));
  if not found then raise exception 'رابط الاختبار غير صحيح أو غير موجود'; end if;
  return jsonb_build_object('creator_name', v_creator, 'questions', v_snapshot);
end $$;

create or replace function public.fc_submit_friend(p_share_code text, p_name text, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public
as $$ declare v_quiz public.fc_quizzes%rowtype; v_total integer; v_matches integer; v_score integer; v_id uuid;
begin
  if p_name is null or char_length(trim(p_name)) < 3 or char_length(trim(p_name)) > 80 or position(' ' in trim(p_name)) = 0 then raise exception 'اكتب اسمك الثنائي على الأقل'; end if;
  if jsonb_typeof(p_answers) <> 'object' then raise exception 'الإجابات غير صحيحة'; end if;
  select * into v_quiz from public.fc_quizzes where share_code = upper(trim(p_share_code));
  if not found then raise exception 'رابط الاختبار غير صحيح أو غير موجود'; end if;
  select count(*) into v_total from jsonb_array_elements(v_quiz.question_snapshot);
  if v_total < 1 or (select count(*) from jsonb_object_keys(p_answers)) <> v_total then raise exception 'أجب عن كل الأسئلة'; end if;
  if exists (select 1 from jsonb_array_elements(v_quiz.question_snapshot) q where not (p_answers ? (q->>'id')) or not exists (select 1 from jsonb_array_elements_text(q->'options') as opt(value) where opt.value = p_answers ->> (q->>'id'))) then raise exception 'توجد إجابة غير صالحة'; end if;
  select count(*) into v_matches from jsonb_array_elements(v_quiz.question_snapshot) q where (p_answers ->> (q->>'id')) = (v_quiz.creator_answers ->> (q->>'id'));
  v_score := round((v_matches::numeric / v_total) * 100)::integer;
  insert into public.fc_responses(quiz_id, participant_name, answers, score) values(v_quiz.id, trim(p_name), p_answers, v_score) returning id into v_id;
  return jsonb_build_object('score', v_score, 'response_id', v_id, 'creator_name', v_quiz.creator_name);
end $$;

create or replace function public.fc_owner_results(p_owner_token text) returns jsonb
language plpgsql stable security definer set search_path = public
as $$ declare v_quiz public.fc_quizzes%rowtype; v_list jsonb; v_count integer; v_avg numeric;
begin
  select * into v_quiz from public.fc_quizzes where owner_token = p_owner_token;
  if not found then raise exception 'رابط النتائج الخاص غير صحيح'; end if;
  select count(*), coalesce(round(avg(score)), 0), coalesce(jsonb_agg(jsonb_build_object('name', participant_name, 'score', score, 'created_at', created_at) order by score desc, created_at desc), '[]'::jsonb)
  into v_count, v_avg, v_list from public.fc_responses where quiz_id = v_quiz.id;
  return jsonb_build_object('creator_name', v_quiz.creator_name, 'participant_count', v_count, 'average_score', v_avg, 'results', v_list);
end $$;

create or replace function public.fc_admin_save_question(p_id uuid, p_text text, p_options jsonb, p_position integer default 0) returns jsonb
language plpgsql security definer set search_path = public
as $$ declare v_id uuid;
begin
  if not public.fc_is_admin() then raise exception 'غير مسموح: هذه الوظيفة للأدمن فقط'; end if;
  if p_text is null or char_length(trim(p_text)) < 3 or char_length(p_text) > 300 then raise exception 'نص السؤال يجب أن يكون من 3 إلى 300 حرف'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) < 2 or jsonb_array_length(p_options) > 8 then raise exception 'أضف من اختيارين إلى 8 اختيارات'; end if;
  if exists(select 1 from jsonb_array_elements_text(p_options) as opt(value) where char_length(trim(opt.value)) < 1 or char_length(opt.value) > 100) then raise exception 'تحقق من نصوص الاختيارات'; end if;
  if p_id is null then insert into public.fc_questions(question_text, options, position, active) values(trim(p_text), p_options, greatest(coalesce(p_position,0),0), true) returning id into v_id;
  else update public.fc_questions set question_text=trim(p_text), options=p_options, position=greatest(coalesce(p_position,0),0), active=true where id=p_id returning id into v_id; if v_id is null then raise exception 'السؤال غير موجود'; end if; end if;
  return jsonb_build_object('id',v_id);
end $$;

create or replace function public.fc_admin_delete_question(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public
as $$ begin
  if not public.fc_is_admin() then raise exception 'غير مسموح: هذه الوظيفة للأدمن فقط'; end if;
  delete from public.fc_questions where id=p_id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.fc_admin_data() returns jsonb
language plpgsql stable security definer set search_path = public
as $$ declare v_questions jsonb; v_quizzes jsonb;
begin
  if not public.fc_is_admin() then raise exception 'غير مسموح: هذه الوظيفة للأدمن فقط'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'text',question_text,'options',options,'position',position,'active',active) order by position,created_at),'[]'::jsonb) into v_questions from public.fc_questions;
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'creator_name',q.creator_name,'share_code',q.share_code,'created_at',q.created_at,'question_snapshot',q.question_snapshot,'participants',coalesce(r.people,'[]'::jsonb)) order by q.created_at desc),'[]'::jsonb)
  into v_quizzes from public.fc_quizzes q left join lateral (
    select jsonb_agg(jsonb_build_object('name',x.participant_name,'score',x.score,'answers',x.answers,'created_at',x.created_at) order by x.created_at desc) as people from public.fc_responses x where x.quiz_id=q.id
  ) r on true;
  return jsonb_build_object('questions',v_questions,'quizzes',v_quizzes);
end $$;

revoke all on function public.fc_is_admin() from public, anon, authenticated;
revoke all on function public.fc_public_questions() from public;
revoke all on function public.fc_create_quiz(text,jsonb) from public;
revoke all on function public.fc_quiz_questions(text) from public;
revoke all on function public.fc_submit_friend(text,text,jsonb) from public;
revoke all on function public.fc_owner_results(text) from public;
revoke all on function public.fc_admin_save_question(uuid,text,jsonb,integer) from public;
revoke all on function public.fc_admin_delete_question(uuid) from public;
revoke all on function public.fc_admin_data() from public;
grant execute on function public.fc_public_questions() to anon, authenticated;
grant execute on function public.fc_create_quiz(text,jsonb) to anon, authenticated;
grant execute on function public.fc_quiz_questions(text) to anon, authenticated;
grant execute on function public.fc_submit_friend(text,text,jsonb) to anon, authenticated;
grant execute on function public.fc_owner_results(text) to anon, authenticated;
grant execute on function public.fc_admin_save_question(uuid,text,jsonb,integer) to authenticated;
grant execute on function public.fc_admin_delete_question(uuid) to authenticated;
grant execute on function public.fc_admin_data() to authenticated;

-- Initial 20 questions. These are examples; edit them from the admin dashboard after setup.
insert into public.fc_questions(question_text, options, position) values
('إيه أكتر لون بتحبه؟', '["أسود","أبيض","أزرق","أحمر"]'::jsonb,1),
('بتفضّل تقضي يوم الإجازة إزاي؟','["في البيت","مع الأصحاب","في مكان جديد","مع العيلة"]'::jsonb,2),
('إيه أكتر حاجة بتحبها في الصداقة؟','["الوفاء","الضحك","المساعدة","الصراحة"]'::jsonb,3),
('لو هتختار أكلة واحدة، تختار إيه؟','["بيتزا","برجر","مكرونة","مشويات"]'::jsonb,4),
('بتحب تصحى بدري ولا تسهر؟','["أصحى بدري","أسهر","حسب اليوم","الاتنين"]'::jsonb,5),
('إيه نوع الأفلام أو القصص المفضّل؟','["أكشن","كوميدي","خيال وفانتازيا","غموض"]'::jsonb,6),
('لما تزعل، غالبًا بتعمل إيه؟','["أفضل لوحدي","أكلم حد قريب","أسمع موسيقى","أضحك وأتجاهل"]'::jsonb,7),
('بتفضّل البحر ولا الجبل؟','["البحر","الجبل","الاتنين","ولا واحد"]'::jsonb,8),
('إيه أهم صفة في صاحبك؟','["الأمانة","الجدعنة","خفة الدم","التفاهم"]'::jsonb,9),
('لو كسبت مبلغ كبير، تعمل إيه؟','["أوفره","أشتري حاجة نفسي فيها","أسافر","أساعد أهلي"]'::jsonb,10),
('أنهي وقت بتحبه أكتر؟','["الصبح","الظهر","المغرب","بالليل"]'::jsonb,11),
('بتحب المنافسة؟','["آه جدًا","أحيانًا","مش قوي","على حسب اللعبة"]'::jsonb,12),
('إيه الهدية اللي تفرحك؟','["حاجة عملية","حاجة معمولة مخصوص","خروجة","رسالة لطيفة"]'::jsonb,13),
('لو عندك قوة خارقة تختار إيه؟','["السرعة","الاختفاء","الطيران","قراءة الأفكار"]'::jsonb,14),
('بتفضّل تخطط ولا ترتجل؟','["أخطط لكل حاجة","أرتجل","خليط بين الاتنين","حسب الموقف"]'::jsonb,15),
('إيه أكتر حاجة بتضحكك؟','["المواقف العفوية","النكت","الميمز","صحابي"]'::jsonb,16),
('لو سافرت، تختار فين؟','["مدينة كبيرة","مكان طبيعي هادي","شاطئ","مكان تاريخي"]'::jsonb,17),
('بتحب تتعلم حاجات جديدة؟','["دايمًا","لو الموضوع شدني","أحيانًا","أفضل الحاجات اللي أعرفها"]'::jsonb,18),
('إيه أفضل طريقة لحل الخلاف؟','["نتكلم بصراحة","ناخد وقت نهدى","نضحك ونصالح بعض","نطلب رأي شخص محايد"]'::jsonb,19),
('لو صاحبك محتاجك، تعمل إيه؟','["أقف جنبه فورًا","أسمعه وأفهمه","أساعد على قد ما أقدر","أدور له على حل"]'::jsonb,20)
on conflict do nothing;

create or replace function public.fc_admin_delete_quiz(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public
as $$ begin
  if not public.fc_is_admin() then raise exception 'غير مسموح: هذه الوظيفة للأدمن فقط'; end if;
  delete from public.fc_quizzes where id=p_id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.fc_admin_delete_quiz(uuid) from public;
grant execute on function public.fc_admin_delete_quiz(uuid) to authenticated;


-- Friendship Challenge: question types + admin ordering migration
-- Run this AFTER the original supabase.sql in Supabase SQL Editor.

ALTER TABLE public.fc_questions
  ADD COLUMN IF NOT EXISTS question_type text NOT NULL DEFAULT 'single';

ALTER TABLE public.fc_questions
  DROP CONSTRAINT IF EXISTS fc_questions_options_check;

ALTER TABLE public.fc_questions
  DROP CONSTRAINT IF EXISTS fc_questions_question_type_check;

ALTER TABLE public.fc_questions
  ADD CONSTRAINT fc_questions_question_type_check
    CHECK (question_type IN ('single', 'multiple', 'text', 'true_false'));

ALTER TABLE public.fc_questions
  ADD CONSTRAINT fc_questions_options_check
    CHECK (
      (question_type = 'text' AND jsonb_typeof(options) = 'array' AND jsonb_array_length(options) = 0)
      OR
      (question_type <> 'text' AND jsonb_typeof(options) = 'array' AND jsonb_array_length(options) BETWEEN 2 AND 8)
    );

CREATE OR REPLACE FUNCTION public.fc_public_questions() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', id,
        'text', question_text,
        'options', options,
        'type', question_type
      ) ORDER BY position, created_at
    ),
    '[]'::jsonb
  )
  FROM public.fc_questions
  WHERE active = true;
$$;

-- Replace the old 4-argument admin save function with a type-aware version.
DROP FUNCTION IF EXISTS public.fc_admin_save_question(uuid, text, jsonb, integer);

CREATE OR REPLACE FUNCTION public.fc_admin_save_question(
  p_id uuid,
  p_text text,
  p_options jsonb,
  p_position integer DEFAULT 0,
  p_type text DEFAULT 'single'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_type text := coalesce(nullif(p_type, ''), 'single');
BEGIN
  IF NOT public.fc_is_admin() THEN
    RAISE EXCEPTION 'غير مسموح: هذه الوظيفة للأدمن فقط';
  END IF;

  IF p_text IS NULL OR char_length(trim(p_text)) < 3 OR char_length(trim(p_text)) > 300 THEN
    RAISE EXCEPTION 'نص السؤال يجب أن يكون من 3 إلى 300 حرف';
  END IF;

  IF v_type NOT IN ('single', 'multiple', 'text', 'true_false') THEN
    RAISE EXCEPTION 'نوع السؤال غير صحيح';
  END IF;

  IF v_type = 'text' THEN
    p_options := '[]'::jsonb;
  ELSIF v_type = 'true_false' THEN
    p_options := '["صح","غلط"]'::jsonb;
  ELSIF jsonb_typeof(p_options) <> 'array'
      OR jsonb_array_length(p_options) < 2
      OR jsonb_array_length(p_options) > 8 THEN
    RAISE EXCEPTION 'أضف من اختيارين إلى 8 اختيارات';
  END IF;

  IF v_type <> 'text' AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(p_options) AS opt(value)
    WHERE char_length(trim(opt.value)) < 1 OR char_length(opt.value) > 100
  ) THEN
    RAISE EXCEPTION 'تحقق من نصوص الاختيارات';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.fc_questions(question_text, options, question_type, position, active)
    VALUES (trim(p_text), p_options, v_type, greatest(coalesce(p_position, 0), 0), true)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.fc_questions
    SET question_text = trim(p_text),
        options = p_options,
        question_type = v_type,
        position = greatest(coalesce(p_position, 0), 0),
        active = true
    WHERE id = p_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'السؤال غير موجود'; END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.fc_admin_reorder_questions(p_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  IF NOT public.fc_is_admin() THEN
    RAISE EXCEPTION 'غير مسموح: هذه الوظيفة للأدمن فقط';
  END IF;

  SELECT count(*) INTO v_count FROM public.fc_questions;
  IF coalesce(cardinality(p_ids), 0) <> v_count THEN
    RAISE EXCEPTION 'قائمة ترتيب الأسئلة غير مكتملة؛ حدّث لوحة الأدمن وحاول مرة أخرى';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(p_ids) AS u(x)) <> v_count THEN
    RAISE EXCEPTION 'قائمة ترتيب الأسئلة تحتوي على تكرار';
  END IF;

  UPDATE public.fc_questions q
  SET position = ordered.ordinality::integer
  FROM unnest(p_ids) WITH ORDINALITY AS ordered(id, ordinality)
  WHERE q.id = ordered.id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.fc_create_quiz(p_creator_name text, p_answers jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_share text;
  v_owner text;
  v_snapshot jsonb;
  v_count integer;
  q jsonb;
  v_answer jsonb;
BEGIN
  IF p_creator_name IS NULL OR char_length(trim(p_creator_name)) < 2 OR char_length(p_creator_name) > 80 THEN
    RAISE EXCEPTION 'اكتب اسمًا صحيحًا';
  END IF;
  IF jsonb_typeof(p_answers) <> 'object' THEN RAISE EXCEPTION 'الإجابات غير صحيحة'; END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('id', id, 'text', question_text, 'options', options, 'type', question_type)
      ORDER BY position, created_at
    ), '[]'::jsonb
  ), count(*)
  INTO v_snapshot, v_count
  FROM public.fc_questions
  WHERE active = true;

  IF v_count < 1 THEN RAISE EXCEPTION 'لا توجد أسئلة متاحة الآن'; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p_answers)) <> v_count THEN RAISE EXCEPTION 'أجب عن كل الأسئلة'; END IF;

  FOR q IN SELECT value FROM jsonb_array_elements(v_snapshot)
  LOOP
    IF NOT (p_answers ? (q->>'id')) THEN RAISE EXCEPTION 'أجب عن كل الأسئلة'; END IF;
    v_answer := p_answers -> (q->>'id');

    IF coalesce(q->>'type', 'single') = 'text' THEN
      IF jsonb_typeof(v_answer) <> 'string' OR char_length(trim(v_answer #>> '{}')) < 1 OR char_length(v_answer #>> '{}') > 500 THEN
        RAISE EXCEPTION 'توجد إجابة نصية غير صالحة';
      END IF;
    ELSIF coalesce(q->>'type', 'single') = 'multiple' THEN
      IF jsonb_typeof(v_answer) <> 'array' OR jsonb_array_length(v_answer) < 1 OR jsonb_array_length(v_answer) > 8
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(v_answer) a(value)
          WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(q->'options') o(value) WHERE o.value = a.value)
        ) THEN RAISE EXCEPTION 'توجد إجابة غير صالحة'; END IF;
    ELSE
      IF jsonb_typeof(v_answer) <> 'string'
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(q->'options') o(value) WHERE o.value = v_answer #>> '{}')
      THEN RAISE EXCEPTION 'توجد إجابة غير صالحة'; END IF;
    END IF;
  END LOOP;

  v_share := upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10));
  v_owner := encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.fc_quizzes(creator_name, creator_answers, question_snapshot, share_code, owner_token)
  VALUES (trim(p_creator_name), p_answers, v_snapshot, v_share, v_owner)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('share_code', v_share, 'owner_token', v_owner, 'creator_name', trim(p_creator_name));
END;
$$;

CREATE OR REPLACE FUNCTION public.fc_submit_friend(p_share_code text, p_name text, p_answers jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_quiz public.fc_quizzes%rowtype;
  v_total integer;
  v_matches integer := 0;
  v_score integer;
  v_id uuid;
  q jsonb;
  v_answer jsonb;
  v_creator_answer jsonb;
  v_type text;
BEGIN
  IF p_name IS NULL OR char_length(trim(p_name)) < 3 OR char_length(trim(p_name)) > 80 OR position(' ' IN trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'اكتب اسمك الثنائي على الأقل';
  END IF;
  IF jsonb_typeof(p_answers) <> 'object' THEN RAISE EXCEPTION 'الإجابات غير صحيحة'; END IF;

  SELECT * INTO v_quiz FROM public.fc_quizzes WHERE share_code = upper(trim(p_share_code));
  IF NOT FOUND THEN RAISE EXCEPTION 'رابط الاختبار غير صحيح أو غير موجود'; END IF;

  SELECT count(*) INTO v_total FROM jsonb_array_elements(v_quiz.question_snapshot);
  IF v_total < 1 OR (SELECT count(*) FROM jsonb_object_keys(p_answers)) <> v_total THEN RAISE EXCEPTION 'أجب عن كل الأسئلة'; END IF;

  FOR q IN SELECT value FROM jsonb_array_elements(v_quiz.question_snapshot)
  LOOP
    IF NOT (p_answers ? (q->>'id')) THEN RAISE EXCEPTION 'أجب عن كل الأسئلة'; END IF;
    v_answer := p_answers -> (q->>'id');
    v_type := coalesce(q->>'type', 'single');

    IF v_type = 'text' THEN
      IF jsonb_typeof(v_answer) <> 'string' OR char_length(trim(v_answer #>> '{}')) < 1 OR char_length(v_answer #>> '{}') > 500 THEN
        RAISE EXCEPTION 'توجد إجابة نصية غير صالحة';
      END IF;
    ELSIF v_type = 'multiple' THEN
      IF jsonb_typeof(v_answer) <> 'array' OR jsonb_array_length(v_answer) < 1 OR jsonb_array_length(v_answer) > 8
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(v_answer) a(value)
          WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(q->'options') o(value) WHERE o.value = a.value)
        ) THEN RAISE EXCEPTION 'توجد إجابة غير صالحة'; END IF;
    ELSE
      IF jsonb_typeof(v_answer) <> 'string'
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(q->'options') o(value) WHERE o.value = v_answer #>> '{}')
      THEN RAISE EXCEPTION 'توجد إجابة غير صالحة'; END IF;
    END IF;

    v_creator_answer := v_quiz.creator_answers -> (q->>'id');
    IF v_type = 'text' THEN
      IF lower(trim(v_answer #>> '{}')) = lower(trim(v_creator_answer #>> '{}')) THEN v_matches := v_matches + 1; END IF;
    ELSIF v_answer = v_creator_answer THEN
      v_matches := v_matches + 1;
    END IF;
  END LOOP;

  v_score := round((v_matches::numeric / v_total) * 100)::integer;
  INSERT INTO public.fc_responses(quiz_id, participant_name, answers, score)
  VALUES (v_quiz.id, trim(p_name), p_answers, v_score)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('score', v_score, 'response_id', v_id, 'creator_name', v_quiz.creator_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.fc_admin_data() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_questions jsonb;
  v_quizzes jsonb;
BEGIN
  IF NOT public.fc_is_admin() THEN RAISE EXCEPTION 'غير مسموح: هذه الوظيفة للأدمن فقط'; END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('id', id, 'text', question_text, 'options', options,
        'type', question_type, 'position', position, 'active', active)
      ORDER BY position, created_at
    ), '[]'::jsonb
  ) INTO v_questions
  FROM public.fc_questions;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('id', q.id, 'creator_name', q.creator_name, 'share_code', q.share_code,
        'created_at', q.created_at, 'question_snapshot', q.question_snapshot,
        'participants', coalesce(r.people, '[]'::jsonb))
      ORDER BY q.created_at DESC
    ), '[]'::jsonb
  )
  INTO v_quizzes
  FROM public.fc_quizzes q
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('name', x.participant_name, 'score', x.score,
      'answers', x.answers, 'created_at', x.created_at) ORDER BY x.created_at DESC) AS people
    FROM public.fc_responses x WHERE x.quiz_id = q.id
  ) r ON true;

  RETURN jsonb_build_object('questions', v_questions, 'quizzes', v_quizzes);
END;
$$;

REVOKE ALL ON FUNCTION public.fc_admin_save_question(uuid, text, jsonb, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fc_admin_reorder_questions(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_admin_save_question(uuid, text, jsonb, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fc_admin_reorder_questions(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fc_public_questions() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fc_create_quiz(text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fc_submit_friend(text, text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fc_admin_data() TO authenticated;

