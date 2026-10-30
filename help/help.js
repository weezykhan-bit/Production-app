// Help page: switch between the crew and office videos, and jump to a step from the chapter list.
const tabs = [...document.querySelectorAll('[data-video]')];
const video = document.getElementById('guide-video'), frame = document.getElementById('frame'), list = document.getElementById('chapters');
const fmt = t => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
let chapters = [];

async function pick(name){
  tabs.forEach(b => b.setAttribute('aria-selected', String(b.dataset.video === name)));
  frame.className = 'frame ' + (name === 'crewdesk-office' ? 'land' : 'port');
  video.src = name + '.mp4'; video.poster = name + '.jpg';
  document.querySelectorAll('[data-for]').forEach(el => { el.hidden = el.dataset.for !== name; });
  list.innerHTML = '';
  try { chapters = await (await fetch(name + '.chapters.json')).json(); } catch { chapters = []; }
  list.innerHTML = chapters.map((c, i) => `<li><button type="button" data-i="${i}"><span class="n">${c.n}</span><span class="t">${c.title}</span><time>${fmt(c.t)}</time></button></li>`).join('');
  try { history.replaceState(null, '', name === 'crewdesk-office' ? '#office' : '#crew'); } catch {}
}
tabs.forEach(b => b.addEventListener('click', () => pick(b.dataset.video)));
list.addEventListener('click', e => {
  const b = e.target.closest('button[data-i]'); if (!b) return;
  video.currentTime = chapters[+b.dataset.i].t; video.play().catch(() => {});
  video.scrollIntoView({behavior:'smooth', block:'center'});
});
video.addEventListener('timeupdate', () => {
  let cur = -1; chapters.forEach((c, i) => { if (video.currentTime >= c.t) cur = i; });
  list.querySelectorAll('button').forEach((b, i) => b.classList.toggle('now', i === cur));
});
pick(location.hash === '#office' ? 'crewdesk-office' : 'crewdesk-setup');
