"use strict";

const labels = document.documentElement.lang === "ru" ? {
  title: "Запись звонка в Takt",
  choose: "Выбрать вкладку звонка",
  stop: "Остановить запись",
  waiting: "В диалоге Chrome выберите вкладку встречи и включите передачу её звука.",
  noTab: "Выберите вкладку Chrome и включите передачу звука вкладки.",
  microphone: "Разрешите Chrome доступ к микрофону и выберите вкладку снова.",
  recording: "Идёт запись. Можно вернуться к звонку. Оставьте эту страницу открытой.",
  paused: "Запись на паузе. Продолжить её можно из заметки в Takt.",
  finishing: "Сохраняем запись в Takt…",
  done: "Вернитесь в заметку в Takt. Эту вкладку можно закрыть.",
  lost: "Связь с Takt прервалась. Вернитесь в заметку, чтобы проверить запись."
} : {
  title: "Record a call in Takt",
  choose: "Choose the call tab",
  stop: "Stop recording",
  waiting: "In Chrome’s dialog, choose your meeting tab and share the tab audio.",
  noTab: "Choose a Chrome tab and turn on tab audio sharing.",
  microphone: "Allow Chrome to use the microphone, then choose the tab again.",
  recording: "Recording. You can return to the call. Keep this page open.",
  paused: "Paused. You can resume recording in the Takt note.",
  finishing: "Saving the recording in Takt…",
  done: "Return to the note in Takt. You can close this tab.",
  lost: "The connection to Takt was interrupted. Return to the note to check the recording."
};

const start = document.querySelector("#start");
const stop = document.querySelector("#stop");
const status = document.querySelector("#status");
document.querySelector("#heading").textContent = labels.title;
status.textContent = labels.waiting;
start.textContent = labels.choose;
stop.textContent = labels.stop;

let context, worklet, shared, microphone, poll;
let queue = Promise.resolve();
let pending = 0;
let sequence = 0;
let active = false;
let finishing = false;
let transportError = false;
let flushComplete;

async function request(path, body, number) {
  const headers = { "X-Takt-Call": "1" };
  if (number !== undefined) headers["X-Takt-Chunk"] = String(number);
  const response = await fetch(path, {
    method: body === undefined ? "GET" : "POST",
    headers,
    body,
    cache: "no-store",
    signal: AbortSignal.timeout(4000)
  });
  if (!response.ok) throw new Error("Takt connection");
  return response.text();
}

function releaseSources() {
  clearTimeout(poll);
  for (const stream of [shared, microphone]) stream?.getTracks().forEach(track => track.stop());
  if (context) void context.close().catch(() => {});
  shared = microphone = context = worklet = undefined;
}

function applyState(state) {
  if (finishing) return;
  if (state === "stopping") void finish();
  else if (state === "recording" || state === "paused") status.textContent = labels[state];
}

async function checkState() {
  if (!active || finishing) return;
  try {
    applyState(await request("state"));
    if (!finishing) poll = setTimeout(checkState, 750);
  } catch {
    transportError = true;
    void finish();
  }
}

function sendAudio(packet) {
  if (transportError) return;
  // Ограничиваем очередь при зависании локального соединения.
  if (pending >= 12) {
    transportError = true;
    void finish();
    return;
  }
  const number = sequence++;
  pending++;
  queue = queue.then(async () => {
    if (!transportError) {
      try { applyState(await request("chunk", packet, number)); }
      catch { transportError = true; void finish(); }
    }
  }).finally(() => { pending--; });
}

async function finish() {
  if (!active || finishing) return;
  finishing = true;
  stop.disabled = true;
  status.textContent = labels.finishing;
  if (worklet && !transportError) {
    await new Promise(resolve => {
      const limit = setTimeout(resolve, 1200);
      flushComplete = () => { clearTimeout(limit); resolve(); };
      worklet.port.postMessage("finish");
    });
  }
  releaseSources();
  await queue;
  try {
    await request(transportError ? "failed" : "finish", "");
    status.textContent = transportError ? labels.lost : labels.done;
  } catch {
    status.textContent = labels.lost;
  }
  active = false;
}

start.addEventListener("click", async () => {
  start.disabled = true;
  let failure = labels.noTab;
  try {
    // Chrome требует запуск своего диалога непосредственно из жеста пользователя.
    shared = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: "browser", frameRate: 1 },
      audio: { suppressLocalAudioPlayback: false },
      selfBrowserSurface: "exclude",
      systemAudio: "exclude",
      surfaceSwitching: "exclude"
    });
    const [video] = shared.getVideoTracks();
    const [tab] = shared.getAudioTracks();
    if (video?.getSettings().displaySurface !== "browser" || !tab) throw new Error("Expected tab audio");

    failure = labels.microphone;
    microphone = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true }, video: false });
    failure = labels.lost;
    if (!shared.active || tab.readyState !== "live" || video.readyState !== "live" || !microphone.active) {
      throw new Error("Source ended");
    }

    context = new AudioContext({ sampleRate: 24000 });
    await context.audioWorklet.addModule("processor.js");
    worklet = new AudioWorkletNode(context, "takt-call", { numberOfInputs: 2 });
    worklet.port.onmessage = ({ data }) => {
      if (data === "finished") flushComplete?.();
      else sendAudio(data);
    };
    const state = await request("begin", "");
    active = true;
    start.hidden = true;
    stop.hidden = false;
    if (state !== "recording" || [...shared.getTracks(), ...microphone.getTracks()].some(track => track.readyState !== "live")) {
      void finish();
      return;
    }
    for (const track of [...shared.getTracks(), ...microphone.getTracks()]) {
      track.addEventListener("ended", () => { void finish(); }, { once: true });
    }
    context.createMediaStreamSource(microphone).connect(worklet, 0, 0);
    context.createMediaStreamSource(new MediaStream([tab])).connect(worklet, 0, 1);
    // Выход процессора остаётся пустым, поэтому голос и звук звонка не воспроизводятся повторно.
    worklet.connect(context.destination);
    await context.resume();
    applyState(state);
    void checkState();
  } catch {
    if (active) {
      transportError = true;
      void finish();
    } else {
      releaseSources();
      status.textContent = failure;
      start.disabled = false;
    }
  }
});

stop.addEventListener("click", () => { void finish(); });
