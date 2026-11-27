"use strict";

const labels = document.documentElement.lang === "ru" ? {
  title: "Запись звонка в Takt",
  choose: "Выбрать вкладку звонка",
  stop: "Остановить запись",
  waiting: "В диалоге Chrome выберите вкладку встречи и включите передачу её звука.",
  preparing: "Подготавливаем звук выбранной вкладки…",
  chooseTab: "Выберите вкладку встречи в Chrome и подтвердите доступ.",
  sourceUnavailable: "Chrome не смог начать захват выбранной вкладки. Откройте вкладку встречи и выберите её ещё раз.",
  tabAudio: "Выберите вкладку встречи и включите передачу звука вкладки.",
  audioSetup: "Chrome не смог подготовить звук. Повторите выбор вкладки.",
  micPending: "Ожидаем разрешения на микрофон в Chrome.",
  micUnavailable: "Микрофон недоступен. Проверьте разрешение в Chrome и нажмите «Включить микрофон».",
  micRetry: "Включить микрофон",
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
  preparing: "Preparing audio from the selected tab…",
  chooseTab: "Select the meeting tab in Chrome and confirm sharing.",
  sourceUnavailable: "Chrome could not start capturing the selected tab. Open the meeting tab and select it again.",
  tabAudio: "Select the meeting tab and turn on tab audio sharing.",
  audioSetup: "Chrome could not prepare the audio. Select the tab again.",
  micPending: "Waiting for microphone permission in Chrome.",
  micUnavailable: "The microphone is unavailable. Check Chrome’s permission and click Enable microphone.",
  micRetry: "Enable microphone",
  recording: "Recording. You can return to the call. Keep this page open.",
  paused: "Paused. You can resume recording in the Takt note.",
  finishing: "Saving the recording in Takt…",
  done: "Return to the note in Takt. You can close this tab.",
  lost: "The connection to Takt was interrupted. Return to the note to check the recording."
};

const start = document.querySelector("#start");
const stop = document.querySelector("#stop");
const status = document.querySelector("#status");
const micStatus = document.querySelector("#mic-status");
const micRetry = document.querySelector("#mic-retry");
micRetry.textContent = labels.micRetry;
document.querySelector("#heading").textContent = labels.title;
status.textContent = labels.waiting;
start.textContent = labels.choose;
stop.textContent = labels.stop;

let context, worklet, shared, microphone, microphoneNode, poll;
let microphoneState = "pending";
let queue = Promise.resolve();
let pending = 0;
let sequence = 0;
let active = false;
let finishing = false;
let transportError = false;
let flushComplete;

async function request(path, body, number) {
  const headers = { "X-Takt-Call": "1" };
  if (number !== undefined) {
    headers["X-Takt-Chunk"] = String(number);
    headers["X-Takt-Microphone"] = microphoneState;
  }
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
  microphoneNode?.disconnect();
  microphoneNode = undefined;
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
  micStatus.hidden = micRetry.hidden = true;
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

function setMicrophoneState(state) {
  microphoneState = state;
  micStatus.hidden = state === "available";
  micStatus.textContent = state === "pending" ? labels.micPending : state === "unavailable" ? labels.micUnavailable : "";
  micRetry.hidden = state !== "unavailable";
}

async function enableMicrophone() {
  if (!active || finishing) return;
  setMicrophoneState("pending");
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true }, video: false });
    if (!active || finishing) {
      stream.getTracks().forEach(track => track.stop());
      return;
    }
    const [track] = stream.getAudioTracks();
    if (track?.readyState !== "live") throw new Error("Microphone ended");
    microphoneNode = context.createMediaStreamSource(stream);
    microphoneNode.connect(worklet, 0, 0);
    microphone = stream;
    setMicrophoneState("available");
    track.addEventListener("ended", () => {
      if (finishing || microphone !== stream) return;
      microphoneNode.disconnect();
      microphoneNode = microphone = undefined;
      setMicrophoneState("unavailable");
    }, { once: true });
  } catch {
    stream?.getTracks().forEach(track => track.stop());
    if (active && !finishing) setMicrophoneState("unavailable");
  }
}
micRetry.addEventListener("click", enableMicrophone);

start.addEventListener("click", async () => {
  start.disabled = true;
  let issue = "audioSetup";
  // Keep the native waiting session alive while the user is in Chrome's chooser.
  const waitingHeartbeat = setInterval(() => { void request("state").catch(() => {}); }, 20000);
  try {
    // Unlock Web Audio during the click, before the browser's permission dialogs.
    context = new AudioContext({ sampleRate: 24000 });
    const running = context.resume().then(() => true, () => false);
    issue = "chooseTab";
    const controller = typeof CaptureController === "function" ? new CaptureController() : undefined;
    controller?.setFocusBehavior?.("focus-capturing-application");
    shared = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: "browser", frameRate: 1 },
      audio: { suppressLocalAudioPlayback: false },
      controller,
      selfBrowserSurface: "exclude",
      systemAudio: "exclude",
      surfaceSwitching: "exclude"
    });
    const [video] = shared.getVideoTracks();
    const [tab] = shared.getAudioTracks();
    if (video?.getSettings().displaySurface !== "browser") throw new Error("Expected a browser tab");
    issue = "tabAudio";
    if (tab?.readyState !== "live") throw new Error("Missing tab audio");

    issue = "audioSetup";
    status.textContent = labels.preparing;
    if (!await Promise.race([running, new Promise(resolve => setTimeout(() => resolve(false), 4000))])) {
      throw new Error("Audio context suspended");
    }
    await context.audioWorklet.addModule("processor.js");
    worklet = new AudioWorkletNode(context, "takt-call", { numberOfInputs: 2 });
    worklet.port.onmessage = ({ data }) => {
      if (data === "finished") flushComplete?.();
      else if (active) sendAudio(data);
    };
    context.createMediaStreamSource(new MediaStream([tab])).connect(worklet, 0, 1);
    worklet.connect(context.destination);
    issue = "lost";
    const state = await request("begin", "");
    active = true;
    start.hidden = true;
    stop.hidden = false;
    if (state !== "recording" || shared.getTracks().some(track => track.readyState !== "live")) {
      void finish();
      return;
    }
    for (const track of shared.getTracks()) {
      track.addEventListener("ended", () => { void finish(); }, { once: true });
    }
    applyState(state);
    void checkState();
    void enableMicrophone();
  } catch (error) {
    if (issue === "chooseTab" && ["AbortError", "NotReadableError"].includes(error.name)) {
      issue = "sourceUnavailable";
    }
    if (active) {
      transportError = true;
      void finish();
    } else {
      releaseSources();
      status.textContent = labels[issue];
      if (issue !== "lost") {
        try { await request("setup", issue); } catch { status.textContent = labels.lost; }
      }
      start.disabled = false;
    }
  } finally {
    clearInterval(waitingHeartbeat);
  }
});

stop.addEventListener("click", () => { void finish(); });
