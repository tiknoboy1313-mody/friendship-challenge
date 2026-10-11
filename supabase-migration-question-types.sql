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
