// Один такт AudioWorklet синхронизирует микрофон и звук вкладки.
class TaktCallProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new ArrayBuffer(12000 * 4);
    this.samples = new DataView(this.buffer);
    this.frames = 0;
    this.ended = false;
    this.port.onmessage = ({ data }) => {
      if (data === "finish") {
        this.flush();
        this.ended = true;
        this.port.postMessage("finished");
      }
    };
  }

  flush() {
    if (this.frames === 0) return;
    const packet = this.buffer.slice(0, this.frames * 4);
    this.port.postMessage(packet, [packet]);
    this.frames = 0;
  }

  process(inputs, outputs) {
    if (this.ended) return false;
    const frames = outputs[0][0].length;
    for (let index = 0; index < frames; index++) {
      for (let side = 0; side < 2; side++) {
        const channels = inputs[side];
        let sample = 0;
        for (const channel of channels) sample += channel[index] / channels.length;
        const value = Math.round(Math.max(-1, Math.min(32767 / 32768, sample)) * 32768);
        this.samples.setInt16(this.frames * 4 + side * 2, value, true);
      }
      this.frames++;
      if (this.frames === 12000) this.flush();
    }
    return true;
  }
}

registerProcessor("takt-call", TaktCallProcessor);
