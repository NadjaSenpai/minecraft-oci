"use strict";

const $ = (s) => document.querySelector(s);

let toastTimer = null;
function toast(msg, ok = true) {
  const t = $("#toast");
  t.textContent = msg;
  t.style.borderColor = ok ? "#3a3f4d" : "#b03a3a";
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 3000);
}

async function api(method, path, body) {
  const opt = { method };
  if (body !== undefined) {
    opt.headers = { "Content-Type": "application/json" };
    opt.body = JSON.stringify(body);
  }
  const res = await fetch(path, opt);
  let data = null;
  try { data = await res.json(); } catch (_) {}
  if (!res.ok) throw new Error((data && data.error) || ("HTTP " + res.status));
  return data;
}

// --- status / power ----------------------------------------------------------

async function refreshStatus() {
  try {
    const s = await api("GET", "/api/status");
    const dot = $("#dot");
    dot.classList.toggle("on", s.running);
    dot.classList.toggle("off", !s.running);
    $("#state").textContent = s.state || "";
  } catch (e) {
    $("#state").textContent = "(状態取得失敗)";
  }
}

document.querySelectorAll("[data-power]").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const action = btn.getAttribute("data-power");
    btn.disabled = true;
    try {
      await api("POST", "/api/power/" + action);
      toast(action + " を指示しました");
    } catch (e) {
      toast(e.message, false);
    } finally {
      btn.disabled = false;
      setTimeout(refreshStatus, 1500);
    }
  });
});

// --- console -----------------------------------------------------------------

function initConsole() {
  const box = $("#console");
  const es = new EventSource("/api/console/stream");
  es.onmessage = (ev) => {
    const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
    const div = document.createElement("div");
    div.className = "l";
    div.textContent = ev.data;
    box.appendChild(div);
    while (box.childElementCount > 1000) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  };
  es.onerror = () => {}; // EventSource auto-reconnects

  async function send() {
    const inp = $("#cmd");
    const cmd = inp.value.trim();
    if (!cmd) return;
    try {
      await api("POST", "/api/console", { command: cmd });
      inp.value = "";
    } catch (e) {
      toast(e.message, false);
    }
  }
  $("#send").addEventListener("click", send);
  $("#cmd").addEventListener("keydown", (e) => { if (e.key === "Enter") send(); });
}

// --- config ------------------------------------------------------------------

const ENUMS = {
  difficulty: ["peaceful", "easy", "normal", "hard"],
  gamemode: ["survival", "creative", "adventure", "spectator"],
  pvp: ["true", "false"],
  hardcore: ["true", "false"],
};
const NUMS = ["max-players", "view-distance", "simulation-distance"];

async function loadConfig() {
  const data = await api("GET", "/api/config");
  const grid = $("#cfg");
  grid.innerHTML = "";
  const note = $("#cfg-note");
  note.textContent = data.modern
    ? "pvp は このバージョンではゲームルール (稼働中のみ反映・world 永続)。online-mode / white-list / auth-type は保護のため編集不可。"
    : "online-mode / white-list / auth-type は保護のため編集不可。";

  Object.keys(data.config).forEach((key) => {
    const val = data.config[key] || "";
    const label = document.createElement("div");
    label.textContent = key;

    let input;
    if (ENUMS[key]) {
      input = document.createElement("select");
      ENUMS[key].forEach((o) => {
        const opt = document.createElement("option");
        opt.value = o; opt.textContent = o;
        if (o === val) opt.selected = true;
        input.appendChild(opt);
      });
    } else {
      input = document.createElement("input");
      input.type = NUMS.includes(key) ? "number" : "text";
      input.value = val;
    }

    const save = document.createElement("button");
    save.textContent = "保存";
    save.addEventListener("click", async () => {
      save.disabled = true;
      try {
        const r = await api("POST", "/api/config", { key, value: String(input.value) });
        toast(key + ": " + (r.note || "保存"));
      } catch (e) {
        toast(e.message, false);
      } finally {
        save.disabled = false;
      }
    });

    grid.append(label, input, save);
  });
}

// --- whitelist ---------------------------------------------------------------

async function loadWhitelist() {
  const list = await api("GET", "/api/whitelist");
  const tb = $("#wl-list");
  tb.innerHTML = "";
  (list || []).forEach((e) => {
    const tr = document.createElement("tr");
    const n = document.createElement("td"); n.textContent = e.name;
    const u = document.createElement("td"); u.textContent = e.uuid; u.className = "muted";
    tr.append(n, u);
    tb.appendChild(tr);
  });
}

$("#wl-add").addEventListener("click", async () => {
  const name = $("#wl-name").value.trim();
  if (!name) return;
  const bedrock = $("#wl-bedrock").checked;
  $("#wl-add").disabled = true;
  try {
    const r = await api("POST", "/api/whitelist", { name, bedrock });
    toast("追加: " + r.name + (r.reloaded ? " (即反映)" : " (次回起動時)"));
    $("#wl-name").value = "";
    loadWhitelist();
  } catch (e) {
    toast(e.message, false);
  } finally {
    $("#wl-add").disabled = false;
  }
});

// --- backups -----------------------------------------------------------------

function fmtSize(n) {
  if (n > 1 << 30) return (n / (1 << 30)).toFixed(1) + " GB";
  if (n > 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB";
  return (n / 1024).toFixed(0) + " KB";
}

async function loadBackups() {
  const list = await api("GET", "/api/backups");
  const tb = $("#bk-list");
  tb.innerHTML = "";
  (list || []).forEach((b) => {
    const tr = document.createElement("tr");
    const n = document.createElement("td"); n.textContent = b.name;
    const s = document.createElement("td"); s.textContent = fmtSize(b.size); s.className = "muted";
    const d = document.createElement("td");
    const a = document.createElement("a");
    a.href = "/api/backups/" + encodeURIComponent(b.name);
    a.textContent = "ダウンロード";
    d.appendChild(a);
    tr.append(n, s, d);
    tb.appendChild(tr);
  });
}

$("#bk-run").addEventListener("click", async () => {
  const btn = $("#bk-run");
  btn.disabled = true;
  toast("バックアップ中...");
  try {
    await api("POST", "/api/backup");
    toast("バックアップ完了");
    loadBackups();
  } catch (e) {
    toast(e.message, false);
  } finally {
    btn.disabled = false;
  }
});

// --- players -----------------------------------------------------------------

async function loadPlayers() {
  const box = $("#players");
  const count = $("#players-count");
  try {
    const p = await api("GET", "/api/players");
    if (!p.available) {
      count.textContent = "(サーバー停止中)";
      box.innerHTML = "";
      return;
    }
    count.textContent = p.online + " / " + p.max;
    box.innerHTML = "";
    const names = p.players || [];
    if (names.length === 0) {
      const span = document.createElement("span");
      span.className = "muted";
      span.textContent = p.online > 0 ? "(名前サンプルなし)" : "誰もいません";
      box.appendChild(span);
      return;
    }
    names.forEach((n) => {
      const chip = document.createElement("span");
      chip.textContent = n;
      chip.style.cssText = "background:#2f3340;border:1px solid #3a3f4d;border-radius:6px;padding:4px 10px;font-size:13px";
      box.appendChild(chip);
    });
  } catch (e) {
    count.textContent = "(取得失敗)";
  }
}

// --- boot --------------------------------------------------------------------

initConsole();
refreshStatus();
loadConfig().catch((e) => toast(e.message, false));
loadWhitelist().catch(() => {});
loadBackups().catch(() => {});
loadPlayers().catch(() => {});
setInterval(refreshStatus, 5000);
setInterval(loadPlayers, 10000);
