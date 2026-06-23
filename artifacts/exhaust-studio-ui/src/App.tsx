import { useState, useRef, useEffect, useCallback } from "react";

// ─────────────────────────────────────────────────────────────────────────────
// Types & constants
// ─────────────────────────────────────────────────────────────────────────────
type TuningMode = "manual" | "presets";
type AudioMode  = "original" | "enhanced";

interface FilterParams {
  hpfHz: number; lpfHz: number;
  eq1Gain: number; eq2Gain: number;
  compThresh: number; compRatio: number;
  volDb: number; limDb: number;
}

const DEFAULT_PARAMS: FilterParams = {
  hpfHz: 120, lpfHz: 6500,
  eq1Gain: 6.0, eq2Gain: 3.0,
  compThresh: -12, compRatio: 4.0,
  volDb: 2.0, limDb: -1.0,
};

interface Preset { name: string; desc: string; params: FilterParams; custom?: boolean; }

const BUILT_IN_PRESETS: Preset[] = [
  { name: "Default",      desc: "Balanced for most bikes",         params: DEFAULT_PARAMS },
  { name: "Track Day",    desc: "Aggressive bark, tight noise",     params: { hpfHz: 180, lpfHz: 5000,  eq1Gain: 9.0,  eq2Gain: 5.0, compThresh: -10, compRatio: 6.0, volDb: 3.0, limDb: -0.5 } },
  { name: "Deep Rumble",  desc: "Maximum bass, full exhaust tone",  params: { hpfHz: 70,  lpfHz: 6000,  eq1Gain: 12.0, eq2Gain: 2.0, compThresh: -14, compRatio: 5.0, volDb: 4.0, limDb: -0.5 } },
  { name: "Street Cruise",desc: "Everyday riding, smooth & natural",params: { hpfHz: 100, lpfHz: 7500,  eq1Gain: 5.0,  eq2Gain: 3.0, compThresh: -12, compRatio: 3.5, volDb: 2.0, limDb: -1.5 } },
  { name: "Wet Road",     desc: "Gentle cleanup, natural sound",    params: { hpfHz: 80,  lpfHz: 8500,  eq1Gain: 3.0,  eq2Gain: 1.5, compThresh: -18, compRatio: 2.5, volDb: 1.0, limDb: -2.0 } },
  { name: "Race Mode",    desc: "Maximum presence, competition",    params: { hpfHz: 200, lpfHz: 4500,  eq1Gain: 10.0, eq2Gain: 6.0, compThresh:  -8, compRatio: 8.0, volDb: 4.0, limDb: -0.5 } },
];

function buildFilterChain(p: FilterParams, ncLevel: number) {
  const stages = [
    `highpass=f=${p.hpfHz}`,
    `lowpass=f=${p.lpfHz}`,
    `equalizer=f=200:width_type=h:width=50:g=${p.eq1Gain.toFixed(1)}`,
    `equalizer=f=2500:width_type=h:width=200:g=${p.eq2Gain.toFixed(1)}`,
    `acompressor=threshold=${p.compThresh.toFixed(0)}dB:ratio=${p.compRatio.toFixed(1)}:attack=5:release=50`,
    `volume=volume=${p.volDb.toFixed(1)}dB`,
    `alimiter=limit=${p.limDb.toFixed(1)}dB`,
  ];
  if (ncLevel > 0) {
    const loGain = -(18 * ncLevel / 100).toFixed(1);
    const hiGain = -(30 * ncLevel / 100).toFixed(1);
    stages.push(`equalizer=f=80:width_type=o:width=2:g=${loGain}`);
    stages.push(`equalizer=f=8000:width_type=o:width=2:g=${hiGain}`);
  }
  return stages.join(", ");
}

const C = {
  bg: "#000000", surface: "#111111", border: "#222222",
  dim: "#303030", mid: "#555555", muted: "#888888", text: "#E8E8E8",
  orange: "#FF6B00", amber: "#FFAA00", green: "#00E676", appBar: "#000000",
};

// ─────────────────────────────────────────────────────────────────────────────
// Audio engine — built once, persists for the session
// NC nodes are always in the enhanced chain; gain=0 when NC is off.
// Analyser sits at the tail of every chain so FFT sees the final signal.
// The canvas that draws FFT is a pure visual overlay — not part of any
// MediaRecorder capture or downloaded file.
// ─────────────────────────────────────────────────────────────────────────────
interface AudioEngine {
  ctx:       AudioContext;
  source:    MediaElementAudioSourceNode;
  hpf:       BiquadFilterNode;
  lpf:       BiquadFilterNode;
  eq1:       BiquadFilterNode;
  eq2:       BiquadFilterNode;
  comp:      DynamicsCompressorNode;
  vol:       GainNode;
  lim:       DynamicsCompressorNode;
  ncLoShelf: BiquadFilterNode;   // targets sub-bass road rumble (<80Hz)
  ncHiShelf: BiquadFilterNode;   // targets wind/hiss above exhaust range (>6500Hz)
  analyser:  AnalyserNode;
}

function buildEngine(ctx: AudioContext, source: MediaElementAudioSourceNode): AudioEngine {
  const hpf  = ctx.createBiquadFilter(); hpf.type = "highpass";
  const lpf  = ctx.createBiquadFilter(); lpf.type = "lowpass";
  const eq1  = ctx.createBiquadFilter(); eq1.type = "peaking";  eq1.frequency.value = 200;  eq1.Q.value = 1;
  const eq2  = ctx.createBiquadFilter(); eq2.type = "peaking";  eq2.frequency.value = 2500; eq2.Q.value = 1;
  const comp = ctx.createDynamicsCompressor(); comp.attack.value = 0.005; comp.release.value = 0.05; comp.knee.value = 6;
  const vol  = ctx.createGain();
  const lim  = ctx.createDynamicsCompressor(); lim.ratio.value = 20; lim.attack.value = 0.001; lim.release.value = 0.05; lim.knee.value = 0;
  // NC nodes — gain=0 means transparent (passthrough)
  const ncLoShelf = ctx.createBiquadFilter(); ncLoShelf.type = "lowshelf";  ncLoShelf.frequency.value = 80;   ncLoShelf.gain.value = 0;
  const ncHiShelf = ctx.createBiquadFilter(); ncHiShelf.type = "highshelf"; ncHiShelf.frequency.value = 6500; ncHiShelf.gain.value = 0;
  // Analyser for FFT — smoothed, 512-point
  const analyser = ctx.createAnalyser(); analyser.fftSize = 512; analyser.smoothingTimeConstant = 0.82;
  return { ctx, source, hpf, lpf, eq1, eq2, comp, vol, lim, ncLoShelf, ncHiShelf, analyser };
}

function applyParams(e: AudioEngine, p: FilterParams) {
  e.hpf.frequency.value  = p.hpfHz;
  e.lpf.frequency.value  = p.lpfHz;
  e.eq1.gain.value       = p.eq1Gain;
  e.eq2.gain.value       = p.eq2Gain;
  e.comp.threshold.value = p.compThresh;
  e.comp.ratio.value     = p.compRatio;
  e.vol.gain.value       = Math.pow(10, p.volDb / 20);
  e.lim.threshold.value  = p.limDb;
}

function applyNC(e: AudioEngine, ncLevel: number) {
  const t = ncLevel / 100;
  e.ncLoShelf.gain.value = -(18 * t);
  e.ncHiShelf.gain.value = -(30 * t);
}

function disconnectAll(e: AudioEngine) {
  [e.source, e.hpf, e.lpf, e.eq1, e.eq2, e.comp, e.vol, e.lim, e.ncLoShelf, e.ncHiShelf, e.analyser]
    .forEach(n => { try { n.disconnect(); } catch (_) {} });
}

function connectOriginal(e: AudioEngine) {
  disconnectAll(e);
  // original path: source → analyser → out (FFT still works, no processing)
  e.source.connect(e.analyser);
  e.analyser.connect(e.ctx.destination);
}

function connectEnhanced(e: AudioEngine, p: FilterParams, ncLevel: number, ncOrder: "before" | "after") {
  disconnectAll(e);
  applyParams(e, p);
  applyNC(e, ncLevel);
  // NC before tuning:  source → ncLo → ncHi → hpf → lpf → eq1 → eq2 → comp → vol → lim → analyser → out
  // NC after tuning:   source → hpf → lpf → eq1 → eq2 → comp → vol → lim → ncLo → ncHi → analyser → out
  if (ncOrder === "before") {
    e.source.connect(e.ncLoShelf);
    e.ncLoShelf.connect(e.ncHiShelf);
    e.ncHiShelf.connect(e.hpf);
  } else {
    e.source.connect(e.hpf);
  }
  e.hpf.connect(e.lpf);
  e.lpf.connect(e.eq1);
  e.eq1.connect(e.eq2);
  e.eq2.connect(e.comp);
  e.comp.connect(e.vol);
  e.vol.connect(e.lim);
  if (ncOrder === "after") {
    e.lim.connect(e.ncLoShelf);
    e.ncLoShelf.connect(e.ncHiShelf);
    e.ncHiShelf.connect(e.analyser);
  } else {
    e.lim.connect(e.analyser);
  }
  e.analyser.connect(e.ctx.destination);
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT
// ─────────────────────────────────────────────────────────────────────────────
export default function App() {
  const videoRef  = useRef<HTMLVideoElement>(null);
  const fileRef   = useRef<HTMLInputElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const engineRef = useRef<AudioEngine | null>(null);
  const rafRef    = useRef<number>(0);

  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [playing,  setPlaying]  = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [audioMode, setAudioMode] = useState<AudioMode>("original");

  const [params,          setParams]          = useState<FilterParams>(DEFAULT_PARAMS);
  const [tuningMode,      setTuningMode]      = useState<TuningMode>("presets");
  const [selectedPreset,  setSelectedPreset]  = useState<string>("Default");
  const [manualParams,    setManualParams]    = useState<FilterParams>(DEFAULT_PARAMS);
  const [customPresets,   setCustomPresets]   = useState<Preset[]>(() => {
    try { return JSON.parse(localStorage.getItem("exhaustStudioPresets") || "[]"); } catch { return []; }
  });
  const [saveName,      setSaveName]      = useState("");
  const [showSaveInput, setShowSaveInput] = useState(false);
  const [showSaveSheet, setShowSaveSheet] = useState(false);

  // Noise cancellation: 0 = off, 1–100 = active; order controls chain position
  const [ncLevel, setNcLevel] = useState(0);
  const [ncOrder, setNcOrder] = useState<"before" | "after">("before");

  // ── Audio engine init ──────────────────────────────────────────────────────
  const initEngine = useCallback(() => {
    if (engineRef.current || !videoRef.current) return;
    const ctx    = new AudioContext();
    const source = ctx.createMediaElementSource(videoRef.current);
    engineRef.current = buildEngine(ctx, source);
    if (audioMode === "original") connectOriginal(engineRef.current);
    else                          connectEnhanced(engineRef.current, params, ncLevel, ncOrder);
  }, [audioMode, params, ncLevel, ncOrder]);

  // ── Sync filter params live ────────────────────────────────────────────────
  useEffect(() => {
    const e = engineRef.current;
    if (!e || audioMode !== "enhanced") return;
    applyParams(e, params);
  }, [params, audioMode]);

  // ── Sync NC live (level update only) ──────────────────────────────────────
  useEffect(() => {
    const e = engineRef.current;
    if (!e || audioMode !== "enhanced") return;
    applyNC(e, ncLevel);
  }, [ncLevel, audioMode]);

  // ── Rewire chain when NC order changes ────────────────────────────────────
  useEffect(() => {
    const e = engineRef.current;
    if (!e || audioMode !== "enhanced") return;
    connectEnhanced(e, params, ncLevel, ncOrder);
  }, [ncOrder]);

  // ── FFT animation loop — canvas overlay only, no impact on audio/video ────
  useEffect(() => {
    const e      = engineRef.current;
    const canvas = canvasRef.current;
    if (!playing || !e || !canvas) { cancelAnimationFrame(rafRef.current); return; }

    const ctx2d  = canvas.getContext("2d")!;
    const data   = new Uint8Array(e.analyser.frequencyBinCount);
    const isEnh  = audioMode === "enhanced";

    function draw() {
      e!.analyser.getByteFrequencyData(data);
      const W = canvas!.width; const H = canvas!.height;
      ctx2d.clearRect(0, 0, W, H);

      const barCount = Math.floor(data.length / 2); // use lower half (more musical)
      const barW = W / barCount - 0.5;

      for (let i = 0; i < barCount; i++) {
        const amp = data[i] / 255;
        const h   = amp * H * 0.9;
        if (h < 1) continue;
        const alpha = 0.25 + amp * 0.65;
        if (isEnh) {
          const g = ctx2d.createLinearGradient(0, H - h, 0, H);
          g.addColorStop(0, `rgba(255,170,0,${alpha})`);
          g.addColorStop(1, `rgba(255,80,0,${alpha * 0.5})`);
          ctx2d.fillStyle = g;
        } else {
          ctx2d.fillStyle = `rgba(200,200,200,${alpha * 0.5})`;
        }
        ctx2d.fillRect(i * (barW + 0.5), H - h, barW, h);
      }
      rafRef.current = requestAnimationFrame(draw);
    }
    rafRef.current = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(rafRef.current); ctx2d.clearRect(0, 0, canvas.width, canvas.height); };
  }, [playing, audioMode]);

  // ── Mode switch ────────────────────────────────────────────────────────────
  function switchAudioMode(mode: AudioMode) {
    setAudioMode(mode);
    const e = engineRef.current;
    if (!e) return;
    if (mode === "original") connectOriginal(e);
    else                     connectEnhanced(e, params, ncLevel, ncOrder);
  }

  // ── Video ──────────────────────────────────────────────────────────────────
  function togglePlay() {
    const v = videoRef.current;
    if (!v) return;
    initEngine();
    if (engineRef.current?.ctx.state === "suspended") engineRef.current.ctx.resume();
    if (v.paused) { v.play(); setPlaying(true); }
    else          { v.pause(); setPlaying(false); }
  }

  function pickVideo(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    if (!f) return;
    setVideoUrl(URL.createObjectURL(f));
    setPlaying(false); setPosition(0);
    if (fileRef.current) fileRef.current.value = "";
  }

  // ── Tuning ─────────────────────────────────────────────────────────────────
  function switchToManual() { setTuningMode("manual"); setManualParams(params); }

  function switchToPresets() {
    setTuningMode("presets");
    const all = [...BUILT_IN_PRESETS, ...customPresets];
    const hit = all.find(p => p.name === selectedPreset) ?? BUILT_IN_PRESETS[0];
    setSelectedPreset(hit.name); setParams(hit.params);
  }

  function applyPreset(preset: Preset) {
    setSelectedPreset(preset.name); setParams(preset.params); setManualParams(preset.params);
  }

  function setManualParam(patch: Partial<FilterParams>) {
    const next = { ...manualParams, ...patch }; setManualParams(next); setParams(next);
  }

  // ── Custom presets ─────────────────────────────────────────────────────────
  function saveCustomPreset() {
    const name = saveName.trim();
    if (!name) return;
    if ([...BUILT_IN_PRESETS, ...customPresets].some(p => p.name === name)) { alert(`"${name}" already exists.`); return; }
    const preset: Preset = { name, desc: "Custom preset", params: { ...params }, custom: true };
    const updated = [...customPresets, preset];
    setCustomPresets(updated);
    localStorage.setItem("exhaustStudioPresets", JSON.stringify(updated));
    setSaveName(""); setShowSaveInput(false); setSelectedPreset(name); setTuningMode("presets");
  }

  function deleteCustomPreset(name: string) {
    const updated = customPresets.filter(p => p.name !== name);
    setCustomPresets(updated);
    localStorage.setItem("exhaustStudioPresets", JSON.stringify(updated));
    if (selectedPreset === name) { setSelectedPreset("Default"); setParams(DEFAULT_PARAMS); }
  }

  const fmt = (s: number) => `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

  const ncStages: [string, string, string][] = ncLevel > 0 ? [
    ["NC·L", `−${(18 * ncLevel / 100).toFixed(1)}dB@80Hz`,  "Road rumble suppression (below exhaust)"],
    ["NC·H", `−${(30 * ncLevel / 100).toFixed(1)}dB@8kHz`,  "Wind & hiss suppression (above exhaust)"],
  ] : [];

  const mainStages: [string, string, string][] = [
    ["HPF",  `${params.hpfHz}Hz cut`,          "Removes wind buffet & chassis rumble"],
    ["LPF",  `${params.lpfHz}Hz cut`,          "Strips tyre hiss & valve tick"],
    ["EQ1",  `${params.eq1Gain >= 0 ? "+" : ""}${params.eq1Gain.toFixed(1)}dB@200Hz`, "Mid-bass harmonic body"],
    ["EQ2",  `${params.eq2Gain >= 0 ? "+" : ""}${params.eq2Gain.toFixed(1)}dB@2500Hz`, "Engine bark & firing snap"],
    ["COMP", `${params.compThresh.toFixed(0)}dB / ${params.compRatio.toFixed(1)}:1`, "Broadcast-density compression"],
    ["VOL",  `${params.volDb >= 0 ? "+" : ""}${params.volDb.toFixed(1)}dB`, "Output level trim"],
    ["LIM",  `${params.limDb.toFixed(1)}dBFS ceiling`, "Hard limiter — zero clip"],
  ];

  const pipelineStages: [string, string, string][] =
    ncOrder === "before" ? [...ncStages, ...mainStages] : [...mainStages, ...ncStages];

  // ─────────────────────────────────────────────────────────────────────────
  return (
    <>
      <AppBar title="EXHAUST STUDIO" />
      <div style={{ padding: "16px 16px 120px" }}>

        {/* ── VIDEO PLAYER ── */}
        {!videoUrl ? (
          <div onClick={() => fileRef.current?.click()}
            style={{ aspectRatio: "16/9", background: C.surface, border: `1.5px dashed ${C.dim}`, borderRadius: 8, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", cursor: "pointer", marginBottom: 20, gap: 14 }}>
            <div style={{ width: 64, height: 64, borderRadius: "50%", border: `1.5px solid ${C.border}`, display: "flex", alignItems: "center", justifyContent: "center" }}>
              <span style={{ fontSize: 28, color: C.mid }}>+</span>
            </div>
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: 13, color: C.mid, letterSpacing: 1.2 }}>Upload Ride Video</div>
              <div style={{ fontSize: 11, color: C.dim, marginTop: 5 }}>tap to select from gallery</div>
            </div>
          </div>
        ) : (
          <div style={{ marginBottom: 20 }}>
            {/* Video container */}
            <div style={{ position: "relative", aspectRatio: "16/9", background: "#000", borderRadius: "8px 8px 0 0", overflow: "hidden" }}>
              <video ref={videoRef} src={videoUrl} loop style={{ width: "100%", height: "100%", objectFit: "cover" }}
                onTimeUpdate={e => setPosition((e.target as HTMLVideoElement).currentTime)}
                onLoadedMetadata={e => setDuration((e.target as HTMLVideoElement).duration)}
                onEnded={() => setPlaying(false)} />

              {/* FFT canvas — purely visual overlay, pointer-events none so clicks pass through.
                  This canvas is never captured by any recorder or download. */}
              <canvas ref={canvasRef} width={512} height={80}
                style={{ position: "absolute", bottom: 0, left: 0, right: 0, width: "100%", height: 80, pointerEvents: "none", opacity: playing ? 1 : 0, transition: "opacity 0.3s" }} />

              {/* Play overlay */}
              <div onClick={togglePlay} style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}>
                {!playing && (
                  <div style={{ width: 60, height: 60, borderRadius: "50%", background: "rgba(0,0,0,0.65)", border: `2px solid ${C.orange}88`, display: "flex", alignItems: "center", justifyContent: "center" }}>
                    <span style={{ fontSize: 26, color: C.orange, marginLeft: 4 }}>▶</span>
                  </div>
                )}
              </div>

              {/* Replace */}
              <button onClick={e => { e.stopPropagation(); fileRef.current?.click(); }}
                style={{ position: "absolute", top: 8, right: 8, background: "rgba(0,0,0,0.7)", border: `1px solid ${C.border}`, borderRadius: 3, padding: "3px 8px", fontSize: 10, color: "#AAA", fontFamily: "monospace", letterSpacing: 1, cursor: "pointer", zIndex: 2 }}>REPLACE</button>

              {/* ORIGINAL / ENHANCED toggle */}
              <div style={{ position: "absolute", top: 8, left: 8, display: "flex", gap: 1, zIndex: 2 }}>
                <div style={{ padding: "3px 8px", background: audioMode === "original" ? "#fff" : "rgba(0,0,0,0.6)", borderRadius: "3px 0 0 3px", fontSize: 9, fontFamily: "monospace", fontWeight: 700, letterSpacing: 1, color: audioMode === "original" ? "#000" : "#555", cursor: "pointer" }}
                  onClick={() => switchAudioMode("original")}>ORIGINAL</div>
                <div style={{ padding: "3px 8px", background: audioMode === "enhanced" ? C.orange : "rgba(0,0,0,0.6)", borderRadius: "0 3px 3px 0", fontSize: 9, fontFamily: "monospace", fontWeight: 700, letterSpacing: 1, color: audioMode === "enhanced" ? "#000" : "#555", cursor: "pointer" }}
                  onClick={() => switchAudioMode("enhanced")}>ENHANCED ▲</div>
              </div>
            </div>

            {/* Seek bar */}
            <div style={{ background: "#080808", borderRadius: "0 0 8px 8px", padding: "8px 14px 10px" }}>
              <input type="range" min={0} max={duration || 100} step={0.05} value={position}
                onChange={e => { const v = videoRef.current; if (v) v.currentTime = +e.target.value; setPosition(+e.target.value); }}
                style={{ width: "100%", accentColor: C.orange, cursor: "pointer", display: "block", marginBottom: 4 }} />
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span style={{ fontSize: 10, color: "#444", fontFamily: "monospace" }}>{fmt(position)}</span>
                <span style={{ fontSize: 10, color: "#444", fontFamily: "monospace" }}>{fmt(duration)}</span>
              </div>
            </div>

            {/* Hint */}
            {audioMode === "original" ? (
              <div style={{ marginTop: 10, padding: "8px 12px", background: C.surface, border: `1px solid ${C.border}`, borderRadius: 6, display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ fontSize: 13 }}>👂</span>
                <span style={{ fontSize: 10, color: C.mid }}>Original audio. Tap <b style={{ color: C.orange }}>ENHANCED ▲</b> to compare.</span>
              </div>
            ) : (
              <div style={{ marginTop: 10, padding: "8px 12px", background: "rgba(255,107,0,0.05)", border: `1px solid ${C.orange}33`, borderRadius: 6, display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ fontSize: 13 }}>🔊</span>
                <span style={{ fontSize: 10, color: C.orange }}>Live processing active — spectrum shows processed audio</span>
              </div>
            )}
          </div>
        )}

        <input ref={fileRef} type="file" accept="video/*" style={{ display: "none" }} onChange={pickVideo} />

        {/* ── NOISE CANCELLATION ── */}
        <SectionLabel label="NOISE CANCELLATION" />
        <div style={{ marginTop: 14, background: C.surface, border: `1px solid ${ncLevel > 0 ? C.orange + "55" : C.border}`, borderRadius: 8, padding: "14px 16px", transition: "border-color 0.2s" }}>

          {/* Level row */}
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
            <button onClick={() => setNcLevel(0)}
              style={{ padding: "5px 12px", borderRadius: 4, border: `1px solid ${ncLevel === 0 ? "#666" : C.border}`, background: ncLevel === 0 ? "#2A2A2A" : "transparent", color: ncLevel === 0 ? "#CCC" : C.mid, fontFamily: "monospace", fontSize: 10, fontWeight: 700, letterSpacing: 1.5, cursor: "pointer", flexShrink: 0 }}>OFF</button>
            <input type="range" min={0} max={100} step={1} value={ncLevel}
              onChange={e => setNcLevel(+e.target.value)}
              style={{ flex: 1, accentColor: C.orange, cursor: "pointer" }} />
            <span style={{ fontSize: 13, fontWeight: 700, color: ncLevel > 0 ? C.orange : C.mid, fontFamily: "monospace", minWidth: 32, textAlign: "right" }}>{ncLevel > 0 ? ncLevel : "—"}</span>
          </div>

          {/* Sequence toggle */}
          <div style={{ display: "flex", background: "#0A0A0A", border: `1px solid ${C.border}`, borderRadius: 5, padding: 2, marginBottom: 12, gap: 2 }}>
            {(["before", "after"] as const).map(o => (
              <button key={o} onClick={() => setNcOrder(o)}
                style={{ flex: 1, padding: "6px 0", border: "none", borderRadius: 3, cursor: "pointer", fontFamily: "monospace", fontSize: 10, fontWeight: 700, letterSpacing: 1.2, transition: "all 0.15s",
                  background: ncOrder === o ? (ncLevel > 0 ? C.orange : "#2A2A2A") : "transparent",
                  color: ncOrder === o ? (ncLevel > 0 ? "#000" : "#CCC") : C.mid }}>
                {o === "before" ? "BEFORE TUNING" : "AFTER TUNING"}
              </button>
            ))}
          </div>

          {ncLevel > 0 ? (
            <div style={{ display: "flex", gap: 8 }}>
              <div style={{ flex: 1, background: "#0A0A0A", border: `1px solid ${C.border}`, borderRadius: 4, padding: "8px 10px" }}>
                <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.2, marginBottom: 4 }}>SUB-BASS RUMBLE</div>
                <div style={{ fontSize: 11, color: C.orange, fontFamily: "monospace" }}>−{(18 * ncLevel / 100).toFixed(1)}dB @ 80Hz</div>
                <div style={{ fontSize: 9, color: "#444", marginTop: 3 }}>road / wind below exhaust</div>
              </div>
              <div style={{ flex: 1, background: "#0A0A0A", border: `1px solid ${C.border}`, borderRadius: 4, padding: "8px 10px" }}>
                <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.2, marginBottom: 4 }}>WIND & HISS</div>
                <div style={{ fontSize: 11, color: C.orange, fontFamily: "monospace" }}>−{(30 * ncLevel / 100).toFixed(1)}dB @ 8kHz</div>
                <div style={{ fontSize: 9, color: "#444", marginTop: 3 }}>camera / wind above exhaust</div>
              </div>
            </div>
          ) : (
            <div style={{ fontSize: 10, color: "#383838", letterSpacing: 0.5, lineHeight: 1.6 }}>
              Targets sub-bass road rumble (&lt;80Hz) and wind/hiss above exhaust range (&gt;6.5kHz) — independent of HPF/LPF/EQ settings
            </div>
          )}
        </div>

        {/* ── TUNING PROFILE ── */}
        <SectionLabel label="TUNING PROFILE" />
        <div style={{ marginTop: 14 }}>
          {/* Tab switcher */}
          <div style={{ display: "flex", background: C.surface, border: `1px solid ${C.border}`, borderRadius: 6, padding: 3, marginBottom: 20, gap: 3 }}>
            {(["presets", "manual"] as TuningMode[]).map(mode => (
              <button key={mode} onClick={mode === "manual" ? switchToManual : switchToPresets}
                style={{ flex: 1, padding: "9px 0", borderRadius: 4, border: "none", cursor: "pointer", fontFamily: "monospace", fontSize: 11, fontWeight: 700, letterSpacing: 1.5, transition: "all 0.18s",
                  background: tuningMode === mode ? C.orange : "transparent",
                  color: tuningMode === mode ? "#000" : C.muted }}>
                {mode === "manual" ? "MANUAL TUNING" : "PRESETS"}
              </button>
            ))}
          </div>

          {/* PRESETS panel */}
          {tuningMode === "presets" && (
            <div>
              <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.5, marginBottom: 12 }}>BUILT-IN</div>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 20 }}>
                {BUILT_IN_PRESETS.map(preset => (
                  <PresetCard key={preset.name} preset={preset} isSelected={selectedPreset === preset.name} onSelect={() => applyPreset(preset)} />
                ))}
              </div>
              {customPresets.length > 0 && (
                <>
                  <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.5, marginBottom: 12 }}>MY PRESETS</div>
                  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 20 }}>
                    {customPresets.map(preset => (
                      <PresetCard key={preset.name} preset={preset} isSelected={selectedPreset === preset.name} onSelect={() => applyPreset(preset)} onDelete={() => deleteCustomPreset(preset.name)} />
                    ))}
                  </div>
                </>
              )}
              {!showSaveInput ? (
                <button onClick={() => setShowSaveInput(true)}
                  style={{ width: "100%", padding: "10px", background: "transparent", border: `1px dashed ${C.border}`, borderRadius: 6, color: C.mid, fontFamily: "monospace", fontSize: 11, letterSpacing: 1.5, cursor: "pointer" }}>
                  + SAVE CURRENT SETTINGS AS PRESET
                </button>
              ) : (
                <div style={{ display: "flex", gap: 8 }}>
                  <input autoFocus value={saveName} onChange={e => setSaveName(e.target.value)}
                    onKeyDown={e => { if (e.key === "Enter") saveCustomPreset(); if (e.key === "Escape") { setShowSaveInput(false); setSaveName(""); } }}
                    placeholder="Preset name…"
                    style={{ flex: 1, background: C.surface, border: `1px solid ${C.orange}`, borderRadius: 4, padding: "9px 12px", color: C.text, fontFamily: "monospace", fontSize: 12, outline: "none" }} />
                  <button onClick={saveCustomPreset} style={{ padding: "9px 16px", background: C.orange, border: "none", borderRadius: 4, color: "#000", fontFamily: "monospace", fontSize: 12, fontWeight: 800, cursor: "pointer" }}>SAVE</button>
                  <button onClick={() => { setShowSaveInput(false); setSaveName(""); }} style={{ padding: "9px 12px", background: "transparent", border: `1px solid ${C.border}`, borderRadius: 4, color: C.mid, fontFamily: "monospace", cursor: "pointer" }}>✕</button>
                </div>
              )}
            </div>
          )}

          {/* MANUAL panel */}
          {tuningMode === "manual" && (
            <div>
              <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.5, marginBottom: 16 }}>
                EDIT PARAMETERS · based on <span style={{ color: selectedPreset ? C.orange : "#555" }}>{selectedPreset || "default"}</span>
              </div>
              <ParamSlider label="HPF FREQUENCY"   valueStr={`${manualParams.hpfHz} Hz`}  value={manualParams.hpfHz}  min={60}   max={300}   step={1}   onChange={v => setManualParam({ hpfHz: v })} />
              <ParamSlider label="LPF FREQUENCY"   valueStr={`${manualParams.lpfHz} Hz`}  value={manualParams.lpfHz}  min={1000} max={20000} step={100} onChange={v => setManualParam({ lpfHz: v })} />
              <ParamSlider label="EQ 200Hz GAIN"   valueStr={`${manualParams.eq1Gain >= 0 ? "+" : ""}${manualParams.eq1Gain.toFixed(1)} dB`}  value={manualParams.eq1Gain}  min={-12} max={12} step={0.5} onChange={v => setManualParam({ eq1Gain: v })} />
              <ParamSlider label="EQ 2500Hz GAIN"  valueStr={`${manualParams.eq2Gain >= 0 ? "+" : ""}${manualParams.eq2Gain.toFixed(1)} dB`}  value={manualParams.eq2Gain}  min={-12} max={12} step={0.5} onChange={v => setManualParam({ eq2Gain: v })} />
              <ParamSlider label="COMP THRESHOLD"  valueStr={`${manualParams.compThresh.toFixed(0)} dB`}          value={manualParams.compThresh} min={-40} max={0}  step={1}   onChange={v => setManualParam({ compThresh: v })} />
              <ParamSlider label="COMP RATIO"      valueStr={`${manualParams.compRatio.toFixed(1)} : 1`}          value={manualParams.compRatio}  min={1}   max={20} step={0.5} onChange={v => setManualParam({ compRatio: v })} />
              <ParamSlider label="VOLUME BOOST"    valueStr={`${manualParams.volDb >= 0 ? "+" : ""}${manualParams.volDb.toFixed(1)} dB`}      value={manualParams.volDb}    min={-12} max={12} step={0.5} onChange={v => setManualParam({ volDb: v })} />
              <ParamSlider label="LIMITER CEILING" valueStr={`${manualParams.limDb.toFixed(1)} dBFS`}             value={manualParams.limDb}    min={-12} max={0}  step={0.1} onChange={v => setManualParam({ limDb: +v.toFixed(1) })} />
              <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
                <button onClick={() => { setManualParams(DEFAULT_PARAMS); setParams(DEFAULT_PARAMS); }}
                  style={{ padding: "8px 14px", background: "transparent", border: `1px solid ${C.border}`, borderRadius: 4, color: C.mid, fontFamily: "monospace", fontSize: 10, letterSpacing: 1.2, cursor: "pointer" }}>RESET</button>
                <button onClick={() => { setShowSaveInput(true); setTuningMode("presets"); }}
                  style={{ flex: 1, padding: "8px 14px", background: "transparent", border: `1px dashed ${C.border}`, borderRadius: 4, color: C.mid, fontFamily: "monospace", fontSize: 10, letterSpacing: 1.2, cursor: "pointer" }}>+ SAVE AS PRESET</button>
              </div>
            </div>
          )}
        </div>

        {/* ── PIPELINE ── */}
        <SectionLabel label="PIPELINE" />
        <div style={{ marginTop: 12 }}>
          {pipelineStages.map(([tag, val, desc], i) => (
            <div key={tag} style={{ display: "flex", gap: 12 }}>
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center", width: 44 }}>
                <div style={{ border: `1px solid ${tag.startsWith("NC") ? C.orange + "66" : C.border}`, borderRadius: 2, padding: "2px 3px", background: tag.startsWith("NC") ? "rgba(255,107,0,0.08)" : C.surface, width: "100%", textAlign: "center" }}>
                  <span style={{ fontSize: 9, fontWeight: 700, color: tag.startsWith("NC") ? C.amber : C.orange, letterSpacing: 0.5 }}>{tag}</span>
                </div>
                {i < pipelineStages.length - 1 && <div style={{ width: 1, height: 20, background: C.border }} />}
              </div>
              <div style={{ paddingTop: 2, paddingBottom: 18 }}>
                <div style={{ fontSize: 11, color: "#E0E0E0", letterSpacing: 0.3 }}>{val}</div>
                <div style={{ fontSize: 11, color: C.mid, marginTop: 2, lineHeight: 1.3 }}>{desc}</div>
              </div>
            </div>
          ))}
        </div>

        {/* FFmpeg command */}
        <div style={{ background: "#080808", border: `1px solid ${C.border}`, borderRadius: 4, padding: "10px 12px", marginBottom: 24, overflowX: "auto" }}>
          <code style={{ fontSize: 9, color: "#3A3A3A", letterSpacing: 0.3, whiteSpace: "pre" }}>
            {`-y -i input.mp4 -c:v copy -af "${buildFilterChain(params, ncLevel)}" output.mp4`}
          </code>
        </div>

        {/* ── SAVE button ── */}
        {videoUrl && (
          <button onClick={() => setShowSaveSheet(true)}
            style={{ width: "100%", height: 56, background: C.orange, color: "#000", border: "none", borderRadius: 4, cursor: "pointer", fontSize: 14, fontWeight: 800, letterSpacing: 1.6, fontFamily: "monospace", display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
            <span>⬇</span> SAVE TO GALLERY
          </button>
        )}
      </div>

      {/* ── Save sheet ── */}
      {showSaveSheet && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.8)", display: "flex", alignItems: "flex-end", justifyContent: "center", zIndex: 100 }} onClick={() => setShowSaveSheet(false)}>
          <div onClick={e => e.stopPropagation()} style={{ background: "#111", width: "100%", maxWidth: 480, borderRadius: "12px 12px 0 0", padding: "24px 24px 40px" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 16 }}>
              <span style={{ fontSize: 18 }}>📱</span>
              <span style={{ fontSize: 13, fontWeight: 800, letterSpacing: 2, color: C.orange, fontFamily: "monospace" }}>SAVE WITH ANDROID APP</span>
            </div>
            <p style={{ color: "#999", lineHeight: 1.6, fontSize: 13, marginBottom: 14 }}>
              The web preview lets you hear live A/B audio comparison — saving a processed video requires the <b style={{ color: "#CCC" }}>ExhaustStudio 650 Android app</b> which runs the full FFmpeg pipeline.
            </p>
            <div style={{ background: "#080808", border: `1px solid ${C.border}`, borderRadius: 6, padding: "12px 14px", marginBottom: 20 }}>
              <div style={{ fontSize: 9, color: C.mid, letterSpacing: 1.5, marginBottom: 8 }}>CURRENT SETTINGS WILL EXPORT AS</div>
              <code style={{ fontSize: 9, color: "#555", lineHeight: 1.7, display: "block", wordBreak: "break-all" }}>
                {buildFilterChain(params, ncLevel)}
              </code>
            </div>
            <button onClick={() => setShowSaveSheet(false)}
              style={{ width: "100%", padding: "14px", background: C.orange, border: "none", borderRadius: 4, color: "#000", fontFamily: "monospace", fontSize: 13, fontWeight: 800, letterSpacing: 1.5, cursor: "pointer" }}>
              GOT IT
            </button>
          </div>
        </div>
      )}
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED COMPONENTS
// ─────────────────────────────────────────────────────────────────────────────
function AppBar({ title }: { title: string }) {
  return (
    <div style={{ background: C.appBar, padding: "14px 16px", display: "flex", alignItems: "center", gap: 10, position: "sticky", top: 0, zIndex: 10, borderBottom: `1px solid ${C.border}` }}>
      <span style={{ fontSize: 16, color: C.orange }}>≡</span>
      <span style={{ fontSize: 14, fontWeight: 700, letterSpacing: 1.6, color: C.orange }}>{title}</span>
      <span style={{ fontSize: 10, border: `1px solid ${C.orange}`, color: C.orange, padding: "1px 5px", borderRadius: 2, letterSpacing: 1 }}>650</span>
    </div>
  );
}

function SectionLabel({ label }: { label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 28 }}>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 2.5, color: C.mid }}>{label}</span>
      <div style={{ flex: 1, height: 1, background: "#1A1A1A" }} />
    </div>
  );
}

function ParamSlider({ label, valueStr, value, min, max, step, onChange }: {
  label: string; valueStr: string; value: number; min: number; max: number; step: number; onChange(v: number): void;
}) {
  return (
    <div style={{ marginBottom: 18 }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}>
        <span style={{ fontSize: 10, letterSpacing: 1.2, color: C.muted }}>{label}</span>
        <span style={{ fontSize: 11, color: C.orange, fontWeight: 700 }}>{valueStr}</span>
      </div>
      <input type="range" min={min} max={max} step={step} value={value} onChange={e => onChange(+e.target.value)}
        style={{ width: "100%", accentColor: C.orange, cursor: "pointer" }} />
      <div style={{ display: "flex", justifyContent: "space-between", paddingInline: 12 }}>
        <span style={{ fontSize: 9, color: "#333" }}>{min}</span>
        <span style={{ fontSize: 9, color: "#333" }}>{max}</span>
      </div>
    </div>
  );
}

function PresetCard({ preset, isSelected, onSelect, onDelete }: {
  preset: Preset; isSelected: boolean; onSelect(): void; onDelete?(): void;
}) {
  return (
    <div onClick={onSelect} style={{ border: `1.5px solid ${isSelected ? C.orange : C.border}`, borderRadius: 6, padding: "12px 12px 10px", cursor: "pointer", background: isSelected ? "rgba(255,107,0,0.06)" : C.surface, position: "relative", transition: "border-color 0.15s, background 0.15s" }}>
      {onDelete && (
        <button onClick={e => { e.stopPropagation(); onDelete(); }}
          style={{ position: "absolute", top: 6, right: 6, background: "none", border: "none", color: "#444", cursor: "pointer", fontSize: 14, padding: "0 2px", lineHeight: 1 }}>×</button>
      )}
      <div style={{ fontSize: 11, fontWeight: 700, color: isSelected ? C.orange : "#CCC", letterSpacing: 1.1, marginBottom: 4, paddingRight: onDelete ? 16 : 0 }}>{preset.name}</div>
      <div style={{ fontSize: 10, color: C.mid, lineHeight: 1.4, marginBottom: 6 }}>{preset.desc}</div>
      <div style={{ fontSize: 9, color: "#383838", fontFamily: "monospace" }}>
        {preset.params.hpfHz}Hz · {preset.params.eq1Gain >= 0 ? "+" : ""}{preset.params.eq1Gain.toFixed(1)}dB · {preset.params.compRatio.toFixed(1)}:1
      </div>
    </div>
  );
}
