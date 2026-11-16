defmodule Ebox.Web.Js do
  @moduledoc false
  # The page's only script, served from the app itself (/app.js) so the
  # content security policy can stay at 'self'. It opens letters in the pane
  # without reloading the page, fades a letter in once it has loaded (no
  # flash), sends the pane's forms in the background, and moves on to the next
  # letter after filing. Without it every link and form still works.

  def source do
    ~S"""
    (() => {
      const list = document.getElementById('list');
      const pane = document.getElementById('pane');
      const desk = document.querySelector('.desk');
      const toastEl = document.getElementById('toast');
      if (!list || !pane) return;
      const wide = matchMedia('(min-width: 901px)');

      let toastTimer;
      function toast(text, bad) {
        if (!toastEl || !text) return;
        toastEl.textContent = text;
        toastEl.classList.toggle('bad', !!bad);
        toastEl.classList.add('show');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => toastEl.classList.remove('show'), bad ? 8000 : 3500);
      }
      if (toastEl && toastEl.classList.contains('show')) {
        toastTimer = setTimeout(() => toastEl.classList.remove('show'), 3500);
        const u = new URL(location.href);
        if (u.searchParams.has('msg')) { u.searchParams.delete('msg'); history.replaceState(history.state, '', u); }
      }

      const rows = () => [...list.querySelectorAll('a.row')].filter(r => r.offsetParent);
      const rowFor = key => list.querySelector(`a.row[data-key="${CSS.escape(key)}"]`);

      function select(key) {
        list.querySelectorAll('a.row.on').forEach(r => { r.classList.remove('on'); r.removeAttribute('aria-current'); });
        const r = key && rowFor(key);
        if (r) { r.classList.add('on'); r.setAttribute('aria-current', 'true'); r.scrollIntoView({block: 'nearest'}); }
      }

      // A letter's iframe stays invisible until it has loaded, over a sheet
      // that is already paper-coloured, then fades in; the previous letter
      // stays visible underneath until then.
      function arm(frame) {
        const sheet = frame.parentNode;
        sheet.latest = frame;
        frame.classList.add('pending');
        const show = () => {
          if (sheet.latest !== frame) { frame.remove(); return; }
          frame.classList.remove('pending');
          sheet.querySelectorAll('.sheetmsg').forEach(m => m.remove());
          setTimeout(() => sheet.querySelectorAll('iframe').forEach(f => { if (f !== frame) f.remove(); }), 250);
        };
        frame.addEventListener('load', show, {once: true});
        setTimeout(() => { if (frame.classList.contains('pending') && sheet.latest === frame) show(); }, 2500);
      }

      function swap(html, sameLetter) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html;
        const next = tpl.content.querySelector('.letter');
        const cur = pane.querySelector('.letter');
        const oldSheet = cur && cur.querySelector('.sheet');
        const newSheet = next && next.querySelector('.sheet');
        const newFrame = newSheet && newSheet.querySelector('iframe');

        if (cur && next && oldSheet && newFrame && oldSheet.querySelector('iframe')) {
          // Keep the sheet (and the letter showing in it); swap the rest.
          cur.querySelector('.dossier').replaceWith(next.querySelector('.dossier'));
          cur.querySelector('.sheetbar').replaceWith(next.querySelector('.sheetbar'));
          cur.dataset.key = next.dataset.key;
          cur.dataset.f = next.dataset.f;
          oldSheet.appendChild(newFrame);
          arm(newFrame);
        } else {
          pane.replaceChildren(tpl.content);
          const f = pane.querySelector('.sheet iframe');
          if (f) arm(f);
        }
        if (!sameLetter) { pane.scrollTop = 0; const d = pane.querySelector('.dossier'); if (d) d.scrollTop = 0; }
      }

      let seq = 0;
      async function open(key, {push = true, f = 0} = {}) {
        const my = ++seq;
        const cur = pane.querySelector('.letter');
        const same = cur && cur.dataset.key === key;
        select(key);
        desk.classList.add('has-letter');
        const url = `/letter/${key}` + (f ? `?f=${f}` : '');
        let res;
        try { res = await fetch(url + (f ? '&' : '?') + 'pane=1'); } catch { res = null; }
        if (my !== seq) return;
        if (!res || !res.ok) { toast(res ? 'That letter is no longer in the archive.' : 'The app does not answer. Is it still running?', true); return; }
        const html = await res.text();
        if (my !== seq) return;
        swap(html, same);
        if (push) history.pushState({key, f}, '', url);
        const s = pane.querySelector('.subject');
        document.title = s ? s.textContent : 'Post';
      }

      list.addEventListener('click', e => {
        const a = e.target.closest('a.row');
        if (!a || !wide.matches || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button) return;
        e.preventDefault();
        open(a.dataset.key);
      });

      pane.addEventListener('click', e => {
        if (!wide.matches || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button) return;
        const tab = e.target.closest('a.tab');
        const start = e.target.closest('a[data-open]');
        if (tab) {
          e.preventDefault();
          if (tab.hasAttribute('aria-current')) return;
          open(pane.querySelector('.letter').dataset.key, {f: Number(tab.dataset.f)});
        } else if (start) {
          e.preventDefault();
          open(start.dataset.open);
        }
      });

      function removeRow(row) {
        const group = row.closest('.group');
        row.classList.add('gone');
        setTimeout(() => {
          row.remove();
          if (!group) return;
          const n = group.querySelectorAll('a.row').length;
          const count = group.querySelector('h2 .n');
          if (count) count.textContent = n;
          if (n === 0) group.remove();
        }, 180);
      }

      pane.addEventListener('submit', async e => {
        const form = e.target.closest('form[data-ajax]');
        if (!form) return;
        e.preventDefault();
        const button = form.querySelector('button');
        const label = button.textContent;
        button.disabled = true;
        if (button.dataset.busy) button.textContent = button.dataset.busy;
        let data;
        try {
          const res = await fetch(form.action, {method: 'POST', body: new URLSearchParams(new FormData(form)), headers: {accept: 'application/json'}});
          data = await res.json();
        } catch {
          data = {ok: false, msg: 'The app does not answer. Is it still running?'};
        }
        button.disabled = false;
        button.textContent = label;
        toast(data.msg, !data.ok);
        if (!data.ok) return;
        const key = form.dataset.key;
        const cur = pane.querySelector('.letter');
        if (data.gone) {
          const row = rowFor(key);
          const all = rows();
          const i = row ? all.indexOf(row) : -1;
          const next = i >= 0 ? (all[i + 1] || all[i - 1]) : null;
          if (row) removeRow(row);
          if (next) open(next.dataset.key);
          else location.href = '/';
        } else if (cur && cur.dataset.key === key) {
          open(key, {push: false, f: Number(cur.dataset.f || 0)});
        }
      });

      addEventListener('popstate', () => {
        const m = location.pathname.match(/^\/letter\/([^/]+)$/);
        if (m) open(m[1], {push: false, f: Number(new URLSearchParams(location.search).get('f') || 0)});
        else location.reload();
      });

      document.addEventListener('keydown', e => {
        if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('input, select, textarea')) return;
        if (!wide.matches) return;
        const dir = e.key === 'j' ? 1 : e.key === 'k' ? -1 : 0;
        if (!dir) return;
        const all = rows();
        const i = all.findIndex(r => r.classList.contains('on'));
        const next = all[i < 0 ? 0 : i + dir];
        if (next) { e.preventDefault(); open(next.dataset.key); }
      });

      // Evaluation running in the background: keep the bar up to date.
      const job = document.getElementById('job');
      if (job && job.hasAttribute('data-running')) {
        const poll = setInterval(async () => {
          try {
            const s = await (await fetch('/jobs')).json();
            if (s.running) job.textContent = `Claude is reading: ${s.done} of ${s.total} done`;
            else {
              clearInterval(poll);
              job.innerHTML = 'Claude has finished reading. <a href="/">Show the results</a>';
            }
          } catch { /* the app restarts; try again */ }
        }, 4000);
      }

      const on = list.querySelector('a.row.on');
      if (on) on.scrollIntoView({block: 'center'});
      const f = pane.querySelector('.sheet iframe');
      if (f) history.replaceState({key: pane.querySelector('.letter').dataset.key}, '');
    })();
    """
  end
end
