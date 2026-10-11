
/* Friendship Challenge
   Supabase + Admin Question Ordering
*/

const SUPABASE_URL = 'https://evngjmpneiakkoyiwkut.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_kqZzdsBIXbW1ysh5pPLvdA_4Zc36VXW';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const hasConfig =
  SUPABASE_URL.startsWith('https://') &&
  !SUPABASE_URL.includes('YOUR_') &&
  SUPABASE_ANON_KEY.length > 20 &&
  !SUPABASE_ANON_KEY.includes('YOUR_');

const sb =
  hasConfig && window.supabase
    ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
    : null;

let activeQuestions = [];
let currentShareCode = '';
let currentOwnerToken = '';
let lastFriendResult = null;
let adminSession = null;
let toastTimer;
let adminBusy = false;

/* =========================
   General utilities
========================= */

function toast(message) {
  const el = $('#toast');
  if (!el) {
    alert(message);
    return;
  }

  el.textContent = message;
  el.classList.add('show');

  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2800);
}

function showPage(id) {
  $$('.page').forEach(page => {
    page.classList.toggle('active', page.id === id);
  });

  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function navigate(page) {
  if (page === 'play' && currentShareCode) {
    location.hash = `play=${encodeURIComponent(currentShareCode)}`;
  } else if (page === 'ownerResults' && currentOwnerToken) {
    location.hash = `owner=${encodeURIComponent(currentOwnerToken)}`;
  } else {
    location.hash = page === 'home' ? 'home' : page;
  }

  routeFromHash();
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  })[c]);
}

function niceError(error) {
  const message = String(error?.message || error || 'حدث خطأ غير متوقع.');

  if (/Failed to fetch|NetworkError/i.test(message)) {
    return 'تعذر الاتصال. تحقق من الإنترنت وإعدادات Supabase.';
  }

  if (/Invalid login credentials/i.test(message)) {
    return 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
  }

  if (/fc_admin_reorder_questions/i.test(message)) {
    return 'تعذر تغيير الترتيب. تحقق من إعداد دالة ترتيب الأسئلة في Supabase.';
  }

  return message.replace(/^Error:\s*/, '');
}

function requireConfig() {
  if (!sb) {
    toast('تحقق من رابط Supabase والمفتاح العام في أول script.js.');
    return false;
  }

  return true;
}

async function rpc(name, params = {}) {
  if (!requireConfig()) {
    throw new Error('Supabase غير مضبوط بعد.');
  }

  const { data, error } = await sb.rpc(name, params);

  if (error) throw new Error(error.message || 'حدث خطأ في الاتصال.');

  return data;
}

/* =========================
   Questions and progress
========================= */

function setProgress(type) {
  const root = type === 'creator'
    ? $('#creatorQuestions')
    : $('#friendQuestions');

  const cards = root ? $$('.question-card', root) : [];

  const count = cards.filter(card => {
    const checked = $$(
      'input[type="radio"]:checked, input[type="checkbox"]:checked',
      card
    ).length;

    const text = $('textarea, input[type="text"]', card);

    return checked > 0 || Boolean(text && text.value.trim());
  }).length;

  const total = activeQuestions.length;

  const textEl = $(`#${type}ProgressText`);
  const progressEl = $(`#${type}Progress`);

  if (textEl) textEl.textContent = `${count} / ${total}`;
  if (progressEl) {
    progressEl.style.width = `${total ? count / total * 100 : 0}%`;
  }
}

function renderQuestions(target, questions, type) {
  const root = $(target);
  if (!root) return;

  root.innerHTML = '';

  if (!questions.length) {
    root.innerHTML = '<div class="loading">لا توجد أسئلة متاحة حاليًا.</div>';
    return;
  }

  questions.forEach((q, index) => {
    const card = document.createElement('article');
    card.className = 'question-card';
    card.dataset.questionId = q.id;

    const top = document.createElement('div');
    top.className = 'question-top';

    const number = document.createElement('span');
    number.className = 'question-number';
    number.textContent = String(index + 1).padStart(2, '0');

    const text = document.createElement('div');
    text.className = 'question-text';
    text.textContent = q.text;

    top.append(number, text);
    card.append(top);

    const questionType = q.type || q.question_type || 'single';

    if (questionType === 'text') {
      const input = document.createElement('textarea');
      input.className = 'input answer-text';
      input.name = `${type}-${q.id}`;
      input.maxLength = 500;
      input.rows = 2;
      input.placeholder = 'اكتب إجابتك هنا…';
      input.required = true;

      input.addEventListener('input', () => setProgress(type));
      card.append(input);
    } else {
      const options = document.createElement('div');
      options.className = 'options-grid';

      (q.options || []).forEach((option, oi) => {
        const label = document.createElement('label');
        label.className = 'option-label';

        const input = document.createElement('input');
        input.type = questionType === 'multiple' ? 'checkbox' : 'radio';
        input.name = `${type}-${q.id}`;
        input.value = option;

        input.required = questionType !== 'multiple' && oi === 0;

        input.addEventListener('change', () => {
          if (questionType === 'multiple') {
            const checked = $$(
              `input[name="${type}-${q.id}"]:checked`,
              card
            );

            if (checked.length > 8) {
              input.checked = false;
              toast('اختار 8 إجابات كحد أقصى.');
            }
          }

          setProgress(type);
        });

        const span = document.createElement('span');
        span.textContent = option;

        label.append(input, span);
        options.append(label);
      });

      card.append(options);
    }

    root.append(card);
  });
}

function collectAnswers(rootSelector, questions, type) {
  const root = $(rootSelector);
  const answers = {};

  for (const q of questions) {
    const card = $(
      `.question-card[data-question-id="${q.id}"]`,
      root
    );

    const questionType = q.type || q.question_type || 'single';

    if (questionType === 'text') {
      const input = $('textarea, input[type="text"]', card);
      const value = input?.value.trim() || '';

      if (!value) {
        toast(`اكتب إجابتك عن السؤال: ${q.text}`);
        input?.focus();
        return null;
      }

      answers[q.id] = value;
      continue;
    }

    if (questionType === 'multiple') {
      const selected = $$(
        'input[type="checkbox"]:checked',
        card
      ).map(input => input.value);

      if (!selected.length) {
        toast(`اختار إجابة واحدة على الأقل للسؤال: ${q.text}`);
        card?.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return null;
      }

      answers[q.id] = selected;
      continue;
    }

    const selected = $('input[type="radio"]:checked', card);

    if (!selected) {
      toast(`جاوب عن السؤال: ${q.text}`);
      card?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return null;
    }

    answers[q.id] = selected.value;
  }

  return answers;
}

/* =========================
   Create a friendship quiz
========================= */

async function loadPublicQuestions() {
  const data = await rpc('fc_public_questions');

  if (!Array.isArray(data)) {
    throw new Error('تعذر تحميل الأسئلة.');
  }

  activeQuestions = data;
  renderQuestions('#creatorQuestions', activeQuestions, 'creator');
  setProgress('creator');
}

async function startCreator() {
  showPage('creator');

  const root = $('#creatorQuestions');
  if (root) root.innerHTML = '<div class="loading">جاري تحميل الأسئلة…</div>';

  try {
    await loadPublicQuestions();
  } catch (e) {
    if (root) {
      root.innerHTML = `<div class="loading">${escapeHtml(niceError(e))}</div>`;
    }

    toast(niceError(e));
  }
}

async function handleCreateQuiz(event) {
  event.preventDefault();

  if (!requireConfig()) return;

  if (!activeQuestions.length) {
    toast('الأسئلة لم تُحمّل بعد.');
    return;
  }

  const name = $('#creatorName').value.trim();
  const answers = collectAnswers(
    '#creatorQuestions',
    activeQuestions,
    'creator'
  );

  if (!answers) return;

  const button = $('#creatorForm button[type="submit"]');
  button.disabled = true;
  button.textContent = 'جاري إنشاء الاختبار…';

  try {
    const data = await rpc('fc_create_quiz', {
      p_creator_name: name,
      p_answers: answers
    });

    currentShareCode = data.share_code;
    currentOwnerToken = data.owner_token;

    const base = `${location.origin}${location.pathname}`;

    $('#shareLink').value =
      `${base}#play=${encodeURIComponent(currentShareCode)}`;

    $('#ownerLink').value =
      `${base}#owner=${encodeURIComponent(currentOwnerToken)}`;

    showPage('created');
  } catch (e) {
    toast(niceError(e));
  } finally {
    button.disabled = false;
    button.textContent = 'إنشاء الاختبار 🚀';
  }
}

/* =========================
   Friends answering
========================= */

async function loadPlay(code) {
  currentShareCode = code;
  showPage('play');

  $('#friendQuestions').innerHTML =
    '<div class="loading">جاري تحميل الأسئلة…</div>';

  try {
    const data = await rpc('fc_quiz_questions', {
      p_share_code: code
    });

    activeQuestions = data.questions || [];

    $('#playSubtitle').textContent =
      `اختبار ${data.creator_name} — جاوب عن الأسئلة عشان تعرف نسبة تطابقك.`;

    renderQuestions('#friendQuestions', activeQuestions, 'friend');
    setProgress('friend');
  } catch (e) {
    $('#friendQuestions').innerHTML =
      `<div class="loading">${escapeHtml(niceError(e))}</div>`;

    toast(niceError(e));
  }
}

async function handleFriendSubmit(event) {
  event.preventDefault();

  if (!requireConfig()) return;

  const name = $('#friendName').value.trim();

  if (name.split(/\s+/).filter(Boolean).length < 2) {
    toast('اكتب اسمك الأول واسم العائلة.');
    $('#friendName').focus();
    return;
  }

  const answers = collectAnswers(
    '#friendQuestions',
    activeQuestions,
    'friend'
  );

  if (!answers) return;

  const button = $('#friendForm button[type="submit"]');
  button.disabled = true;
  button.textContent = 'جاري إرسال إجاباتك…';

  try {
    lastFriendResult = await rpc('fc_submit_friend', {
      p_share_code: currentShareCode,
      p_name: name,
      p_answers: answers
    });

    const score = Number(lastFriendResult.score) || 0;

    $('#friendScore').textContent = `${score}%`;

    $('#friendScoreRing').style.background =
      `conic-gradient(var(--pink) 0deg, var(--purple) ${score * 3.6}deg, #2a1d34 ${score * 3.6}deg)`;

    $('#friendResultTitle').textContent =
      score >= 80
        ? 'أنتوا شبه بعض جدًا! 💖'
        : score >= 50
          ? 'في بينكم حاجات مشتركة! ✨'
          : 'لسه محتاجين تعرفوا بعض أكتر 😄';

    $('#friendResultText').textContent =
      `دي نسبة تطابق إجاباتك مع إجابات ${lastFriendResult.creator_name}. مش هتظهر لك الإجابات التفصيلية.`;

    showPage('result');
  } catch (e) {
    toast(niceError(e));
  } finally {
    button.disabled = false;
    button.textContent = 'إرسال الإجابات 💌';
  }
}

/* =========================
   Owner results
========================= */

async function loadOwnerResults(token) {
  currentOwnerToken = token;
  showPage('ownerResults');

  $('#ownerResultsList').innerHTML =
    '<div class="loading">جاري تحميل النتائج…</div>';

  try {
    const data = await rpc('fc_owner_results', {
      p_owner_token: token
    });

    $('#ownerGreeting').textContent =
      `دي نتائج اختبار ${data.creator_name}.`;

    $('#participantCount').textContent = data.participant_count;
    $('#averageScore').textContent = `${data.average_score}%`;

    const root = $('#ownerResultsList');
    root.innerHTML = '';

    if (!data.results?.length) {
      root.innerHTML =
        '<div class="loading">لسه محدش شارك في اختبارك. ابعت رابط المشاركة لأصحابك!</div>';
      return;
    }

    data.results.forEach((person, index) => {
      const row = document.createElement('div');
      row.className = 'result-row';

      const avatar = document.createElement('div');
      avatar.className = 'avatar';
      avatar.textContent = (person.name || '?').trim().charAt(0) || '?';

      const info = document.createElement('div');
      info.className = 'result-person';

      const strong = document.createElement('strong');
      strong.textContent = person.name;

      const small = document.createElement('span');
      small.textContent = `المشارك رقم ${index + 1}`;

      info.append(strong, small);

      const score = document.createElement('div');
      score.className = 'score-pill';
      score.textContent = `${person.score}%`;

      row.append(avatar, info, score);
      root.append(row);
    });
  } catch (e) {
    $('#ownerResultsList').innerHTML =
      `<div class="loading">${escapeHtml(niceError(e))}</div>`;

    toast(niceError(e));
  }
}

/* =========================
   Admin question editor
========================= */

function questionEditor(question = null) {
  const text = prompt(
    'اكتب نص السؤال:',
    question?.text || ''
  );

  if (text === null) return;

  const currentType =
    question?.type || question?.question_type || 'single';

  const typeHelp =
    'اختار نوع السؤال بكتابة الرقم:\n' +
    '1 = اختيار واحد\n' +
    '2 = اختيارات متعددة\n' +
    '3 = إجابة قصيرة مكتوبة\n' +
    '4 = صح أو غلط';

  const currentNumber = ({
    single: '1',
    multiple: '2',
    text: '3',
    true_false: '4'
  })[currentType] || '1';

  const typeNumber = prompt(typeHelp, currentNumber);

  if (typeNumber === null) return;

  const typeMap = {
    '1': 'single',
    '2': 'multiple',
    '3': 'text',
    '4': 'true_false'
  };

  const type = typeMap[typeNumber.trim()];

  if (!type) {
    toast('اكتب رقمًا من 1 إلى 4.');
    return;
  }

  let options = [];

  if (type === 'text') {
    options = [];
  } else if (type === 'true_false') {
    options = ['صح', 'غلط'];
  } else {
    const defaultOptions = (question?.options || []).join(' | ');

    const raw = prompt(
      'اكتب الاختيارات وافصل بينها بعلامة | مثال: أسود | أبيض | أزرق | أحمر',
      defaultOptions || 'اختيار أول | اختيار ثانٍ'
    );

    if (raw === null) return;

    options = raw.split('|').map(s => s.trim()).filter(Boolean);

    if (options.length < 2 || options.length > 8) {
      toast('أضف من اختيارين إلى 8 اختيارات.');
      return;
    }
  }

  if (text.trim().length < 3 || text.trim().length > 300) {
    toast('اكتب سؤالًا من 3 إلى 300 حرف.');
    return;
  }

  (async () => {
    try {
      await rpc('fc_admin_save_question', {
        p_id: question?.id || null,
        p_text: text.trim(),
        p_options: options,
        p_position: question?.position ?? 999,
        p_type: type
      });

      toast(question ? 'تم تعديل السؤال.' : 'تمت إضافة السؤال.');
      await refreshAdmin();
    } catch (e) {
      toast(niceError(e));
    }
  })();
}

/* =========================
   Admin question ordering
========================= */

async function moveQuestion(index, direction) {
  if (adminBusy) return;

  adminBusy = true;

  try {
    // تحميل أحدث ترتيب من قاعدة البيانات
    const data = await rpc('fc_admin_data');
    const ordered = [...(data.questions || [])];

    const target = index + direction;

    if (index < 0 || index >= ordered.length ||
        target < 0 || target >= ordered.length) {
      return;
    }

    // تبديل السؤال بمكان السؤال المجاور
    [ordered[index], ordered[target]] =
      [ordered[target], ordered[index]];

    // حفظ الترتيب الجديد في Supabase
    await rpc('fc_admin_reorder_questions', {
      p_ids: ordered.map(q => q.id)
    });

    // إعادة تحميل اللوحة بعد الحفظ
    await refreshAdmin();

    toast('تم حفظ ترتيب الأسئلة بنجاح.');
  } catch (e) {
    toast(niceError(e));
  } finally {
    adminBusy = false;
  }
}

/* =========================
   Admin dashboard
========================= */

async function refreshAdmin() {
  const data = await rpc('fc_admin_data');

  // ----- Question bank -----
  const questionsRoot = $('#adminQuestions');

  if (!questionsRoot) {
    throw new Error('لم يتم العثور على عنصر بنك الأسئلة #adminQuestions في HTML.');
  }

  questionsRoot.innerHTML = '';

  const questions = data.questions || [];

  if (!questions.length) {
    questionsRoot.innerHTML =
      '<div class="loading">لا توجد أسئلة.</div>';
  } else {
    questions.forEach((q, index) => {
      const item = document.createElement('div');
      item.className = 'admin-question';

      const top = document.createElement('div');
      top.className = 'admin-question-top';

      const title = document.createElement('strong');
      title.textContent = `${index + 1}. ${q.text}`;

      const actions = document.createElement('div');
      actions.className = 'admin-actions';

      // زر التحريك لأعلى
      const moveUp = document.createElement('button');
      moveUp.type = 'button';
      moveUp.className = 'btn btn-ghost';
      moveUp.textContent = '↑';
      moveUp.title = 'تحريك السؤال لأعلى';
      moveUp.setAttribute('aria-label', 'تحريك السؤال لأعلى');
      moveUp.disabled = index === 0 || adminBusy;
      moveUp.onclick = () => moveQuestion(index, -1);

      // زر التحريك لأسفل
      const moveDown = document.createElement('button');
      moveDown.type = 'button';
      moveDown.className = 'btn btn-ghost';
      moveDown.textContent = '↓';
      moveDown.title = 'تحريك السؤال لأسفل';
      moveDown.setAttribute('aria-label', 'تحريك السؤال لأسفل');
      moveDown.disabled = index === questions.length - 1 || adminBusy;
      moveDown.onclick = () => moveQuestion(index, 1);

      // زر تعديل السؤال
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'btn btn-ghost';
      edit.textContent = 'تعديل';
      edit.onclick = () => questionEditor(q);

      // زر حذف السؤال
      const del = document.createElement('button');
      del.type = 'button';
      del.className = 'btn btn-ghost';
      del.textContent = 'حذف';

      del.onclick = async () => {
        if (!confirm(
          'متأكد إنك عايز تحذف السؤال؟ الاختبارات القديمة ستظل محتفظة بنسخة أسئلتها.'
        )) return;

        try {
          await rpc('fc_admin_delete_question', {
            p_id: q.id
          });

          toast('تم حذف السؤال.');
          await refreshAdmin();
        } catch (e) {
          toast(niceError(e));
        }
      };

      actions.append(moveUp, moveDown, edit, del);
      top.append(title, actions);

      const kind = ({
        single: 'اختيار واحد',
        multiple: 'اختيارات متعددة',
        text: 'إجابة قصيرة',
        true_false: 'صح أو غلط'
      })[q.type || q.question_type || 'single'] || 'اختيار واحد';

      const opts = document.createElement('p');
      opts.className = 'admin-options';

      opts.textContent =
        `النوع: ${kind}` +
        ((q.options || []).length
          ? ' — الاختيارات: ' + q.options.join(' • ')
          : '');

      item.append(top, opts);

      // مهم: إضافة السؤال فعليًا إلى بنك الأسئلة
      questionsRoot.append(item);
    });
  }

  // ----- Quizzes and answers -----
  const quizzesRoot = $('#adminQuizzes');

  if (!quizzesRoot) {
    throw new Error('لم يتم العثور على عنصر الاختبارات #adminQuizzes في HTML.');
  }

  quizzesRoot.innerHTML = '';

  const quizzes = data.quizzes || [];

  if (!quizzes.length) {
    quizzesRoot.innerHTML =
      '<div class="loading">لا توجد اختبارات حتى الآن.</div>';
    return;
  }

  quizzes.forEach(q => {
    const item = document.createElement('div');
    item.className = 'admin-quiz';

    const title = document.createElement('strong');
    title.textContent = `${q.creator_name} — كود ${q.share_code}`;

    const meta = document.createElement('p');
    meta.textContent =
      `تاريخ الإنشاء: ${new Date(q.created_at).toLocaleString('ar-EG')} | المشاركون: ${(q.participants || []).length}`;

    const actions = document.createElement('div');
    actions.className = 'admin-actions';

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'btn btn-ghost';
    del.textContent = 'حذف الاختبار';

    del.onclick = async () => {
      if (!confirm('حذف الاختبار وكل ردوده نهائيًا؟')) return;

      try {
        await rpc('fc_admin_delete_quiz', {
          p_id: q.id
        });

        toast('تم حذف الاختبار وردوده.');
        await refreshAdmin();
      } catch (e) {
        toast(niceError(e));
      }
    };

    actions.append(del);

    const details = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = 'عرض الإجابات التفصيلية للأدمن';

    details.append(summary);

    // إجابات صاحب الاختبار
    const creatorBlock = document.createElement('p');
    creatorBlock.className = 'admin-options';

    const creatorAnswers = q.creator_answers || {};
    const snapshot = q.question_snapshot || [];

    const creatorText = snapshot.map(question => {
      const answer = creatorAnswers[question.id];

      const answerText = Array.isArray(answer)
        ? answer.join('، ')
        : answer ?? 'لا توجد إجابة محفوظة';

      return `${question.text}: ${answerText}`;
    }).join(' | ');

    creatorBlock.textContent =
      `إجابات صاحب الاختبار (${q.creator_name}): ${creatorText || 'لا توجد إجابات محفوظة.'}`;

    details.append(creatorBlock);

    // إجابات الأصدقاء
    (q.participants || []).forEach(p => {
      const block = document.createElement('p');

      const answersText = Object.entries(p.answers || {})
        .map(([id, answer]) => {
          const question = snapshot.find(
            x => String(x.id) === String(id)
          );

          const answerText = Array.isArray(answer)
            ? answer.join('، ')
            : answer ?? '';

          return `${question?.text || id}: ${answerText}`;
        })
        .join(' | ');

      block.textContent =
        `${p.name} — ${p.score}% — ${answersText}`;

      details.append(block);
    });

    item.append(title, meta, actions, details);
    quizzesRoot.append(item);
  });
}

/* =========================
   Admin login and logout
========================= */

async function adminLogin(event) {
  event.preventDefault();

  if (!requireConfig()) return;

  const button = $('#adminLoginForm button[type="submit"]');
  button.disabled = true;

  try {
    const { data, error } = await sb.auth.signInWithPassword({
      email: $('#adminEmail').value.trim(),
      password: $('#adminPassword').value
    });

    if (error) throw error;

    adminSession = data.session;

    // التحقق من صلاحيات الأدمن وجلب البيانات
    await rpc('fc_admin_data');

    $('#adminLoginMessage').textContent = 'تم تسجيل الدخول بنجاح.';
    $('#adminDashboard').classList.remove('hidden');
    $('#adminLoginForm').classList.add('hidden');

    await refreshAdmin();

    toast('أهلًا بالأدمن!');
  } catch (e) {
    $('#adminLoginMessage').textContent = niceError(e);
    toast(niceError(e));
  } finally {
    button.disabled = false;
  }
}

async function adminLogout() {
  if (sb) await sb.auth.signOut();

  adminSession = null;

  $('#adminDashboard').classList.add('hidden');
  $('#adminLoginForm').classList.remove('hidden');
  $('#adminPassword').value = '';

  toast('تم تسجيل الخروج.');
}

/* =========================
   Copy links
========================= */

async function copyInput(selector) {
  const input = $(selector);

  if (!input || !input.value) {
    toast('لا يوجد رابط لنسخه بعد.');
    return;
  }

  try {
    await navigator.clipboard.writeText(input.value);
    toast('تم نسخ الرابط 💗');
  } catch {
    input.focus();
    input.select();

    try {
      document.execCommand('copy');
      toast('تم نسخ الرابط.');
    } catch {
      toast('حدد الرابط وانسخه يدويًا.');
    }
  }
}

/* =========================
   Routing
========================= */

function routeFromHash() {
  const hash = decodeURIComponent(location.hash.slice(1));

  if (hash.startsWith('play=')) {
    loadPlay(hash.slice(5));
    return;
  }

  if (hash.startsWith('owner=')) {
    loadOwnerResults(hash.slice(6));
    return;
  }

  const page = hash || 'home';

  if ($('#' + page)?.classList.contains('page')) {
    showPage(page);
  } else {
    showPage('home');
  }
}

/* =========================
   Event listeners
========================= */

$('#startCreate').addEventListener('click', startCreator);

$('#adminOpen').addEventListener('click', () => {
  showPage('admin');
});

$('#howBtn').addEventListener('click', () => {
  alert(
    '1) جاوب عن الأسئلة.\n' +
    '2) انسخ رابط الأصدقاء وابعته لهم.\n' +
    '3) احتفظ برابط النتائج الخاص.\n' +
    '4) كل صديق يرى نسبة تطابقه فقط.'
  );
});

$('#creatorForm').addEventListener('submit', handleCreateQuiz);
$('#friendForm').addEventListener('submit', handleFriendSubmit);

$('#copyShare').addEventListener('click', () => {
  copyInput('#shareLink');
});

$('#copyOwner').addEventListener('click', () => {
  copyInput('#ownerLink');
});

$('#openOwner').addEventListener('click', () => {
  navigate('ownerResults');
});

$('#confirmResult').addEventListener('click', () => {
  toast('تم تأكيد النتيجة بنجاح!');
  navigate('home');
});

$$('.new-test-link').forEach(button => {
  button.addEventListener('click', () => {
    $('#creatorForm').reset();

    const destination = button.dataset.go || 'creator';
    navigate(destination);

    if (destination === 'creator') {
      startCreator();
    }
  });
});

$('#adminLoginForm').addEventListener('submit', adminLogin);

$('#addQuestion').addEventListener('click', () => {
  questionEditor();
});

$('#refreshAdmin').addEventListener('click', async () => {
  try {
    await refreshAdmin();
    toast('تم تحديث لوحة الأدمن.');
  } catch (e) {
    toast(niceError(e));
  }
});

$('#adminLogout').addEventListener('click', adminLogout);

window.addEventListener('hashchange', routeFromHash);

if (!sb) {
  console.info(
    'Friendship Challenge: تحقق من رابط Supabase والمفتاح العام.'
  );
}

routeFromHash();
