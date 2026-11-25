(() => {
  const key = "__notchwordSubtitlesV2";
  if (globalThis[key]) return;
  const states = new WeakMap();
  const observed = new WeakSet();
  const documentID = Date.now().toString(36) + Math.random().toString(36).slice(2);
  let sequence = 0;

  function currentVideo() {
    return Array.from(document.querySelectorAll("video"))
      .map(video => {
        const bounds = video.getBoundingClientRect();
        const area = Math.max(0, Math.min(bounds.right, innerWidth) - Math.max(bounds.left, 0)) *
          Math.max(0, Math.min(bounds.bottom, innerHeight) - Math.max(bounds.top, 0));
        return [video, area];
      })
      .filter(([video, area]) => area > 0 && getComputedStyle(video).visibility !== "hidden")
      .sort((a, b) => b[1] - a[1])[0]?.[0];
  }

  function clean(text) {
    return text.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim().slice(0, 800);
  }

  function stateOf(video) {
    let state = states.get(video);
    if (!state || state.source !== video.currentSrc) {
      state = { id: documentID + "-" + ++sequence, source: video.currentSrc, cues: [], owned: false };
      states.set(video, state);
      if (!observed.has(video)) {
        observed.add(video);
        const clearOwnership = () => { states.get(video).owned = false; };
        video.addEventListener("play", clearOwnership);
        video.addEventListener("seeking", clearOwnership);
      }
    }
    if (state.owned && !video.paused) state.owned = false;
    return state;
  }

  function cues(track, current) {
    if (!track || !track.cues) return [];
    return Array.from(track.cues)
      .filter(cue => Number.isFinite(cue.startTime) && Number.isFinite(cue.endTime)
        && cue.endTime >= current - 45 && cue.startTime <= current + 45)
      .slice(-80).map(cue => ({ text: clean(cue.text || ""), start: cue.startTime, end: cue.endTime }))
      .filter(cue => cue.text);
  }

  const selectors = [
    ["youtube.com", ".ytp-caption-segment"],
    ["bilibili.com", ".bpx-player-subtitle-panel-text, .bilibili-player-video-subtitle span"]
  ];

  function captionText() {
    const host = location.hostname;
    const selector = selectors.find(([domain]) => host === domain || host.endsWith("." + domain))?.[1];
    const nodes = document.querySelectorAll(selector || "[class*='caption'] [class*='cue'], [class*='subtitle'] [class*='cue']");
    return clean(Array.from(nodes)
      .filter(node => node.getClientRects().length && getComputedStyle(node).visibility !== "hidden")
      .map(node => node.textContent).join(" "));
  }

  function canSeek(video, start, end) {
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start) return false;
    for (let i = 0; i < video.seekable.length; i++) {
      if (start >= video.seekable.start(i) && end <= video.seekable.end(i)) return true;
    }
    return false;
  }

  function replay(video, state, start, end) {
    if (!canSeek(video, start, end)) return "false";
    if (state.cancelReplay) return "busy";
    state.replayError = false;
    const wasPaused = video.paused;
    const wasOwned = state.owned;
    state.owned = false;
    const cancel = () => {
      video.removeEventListener("timeupdate", check);
      video.removeEventListener("seeking", seeking);
      video.removeEventListener("pause", paused);
      video.removeEventListener("emptied", cancel);
      if (state.cancelReplay === cancel) state.cancelReplay = null;
    };
    const paused = () => { if (video.paused) cancel(); };
    const seeking = () => {
      if (Math.abs(video.currentTime - start) > 0.2) cancel();
    };
    const source = video.currentSrc;
    const check = () => {
      if (currentVideo() !== video || video.currentSrc !== source) return cancel();
      if (video.currentTime < end) return;
      cancel();
      if (wasPaused) {
        video.pause();
        state.owned = wasOwned;
      }
    };
    state.cancelReplay = cancel;
    video.currentTime = start;
    video.addEventListener("timeupdate", check);
    video.addEventListener("seeking", seeking);
    video.addEventListener("pause", paused);
    video.addEventListener("emptied", cancel);
    void video.play().catch(() => {
      if (state.cancelReplay !== cancel) return;
      state.replayError = true;
      cancel();
    });
    return "true";
  }

  globalThis[key] = (command, expected, start, end) => {
    const video = currentVideo();
    if (!video) return JSON.stringify({ mode: "nosub" });
    const state = stateOf(video);
    const current = video.currentTime || 0;
    const protectedVideo = !!video.mediaKeys;
    const advertisement = !!video.closest(".ad-showing") || !!document.querySelector(".html5-video-player.ad-showing");
    if (command !== "state") {
      if (expected !== state.id || protectedVideo || advertisement) return "false";
      if (command === "replay") return replay(video, state, start, end);
      if (command === "pause" && !video.paused) {
        video.pause();
        state.owned = true;
        return "true";
      }
      if (command === "play" && state.cancelReplay) {
        state.cancelReplay();
        if (!video.paused) return "true";
      }
      if (command === "play" && state.owned && video.paused) {
        state.owned = false;
        void video.play().catch(() => {});
        return "true";
      }
      return "false";
    }
    if (protectedVideo || advertisement) return JSON.stringify({ mode: protectedVideo ? "drm" : "ad", videoID: state.id });

    const tracks = Array.from(video.textTracks || []).filter(track => ["captions", "subtitles"].includes(track.kind));
    const english = tracks.find(track => /^(?:en|eng)(?:[-_]|$)/i.test(track.language) && track.mode !== "disabled") ||
      tracks.find(track => track.mode === "showing" && !track.language);
    const chinese = tracks.find(track => /^(?:zh|zho|chi)(?:[-_]|$)/i.test(track.language) && track.mode !== "disabled");

    // 先滤已播条目，再取最近 80 条，避免已播内容被空白片段挤掉
    let primary = cues(english, current).filter(cue => cue.start <= current).slice(-80);
    const timed = primary.length > 0;
    if (!primary.length) {
      const text = captionText();
      const last = state.cues.at(-1);
      if (last && (current + 0.25 < last.start || current - last.end > 45)) state.cues = [];
      if (text && text === state.cues.at(-1)?.text) {
        // 同一句仍在屏上：延长结束时间，供合句与时间对齐使用
        state.cues.at(-1).end = current;
      } else if (text) {
        state.cues.push({ text, start: current, end: current + 1.5 });
        if (state.cues.length > 80) state.cues.shift();
      }
      primary = state.cues;
    }

    return JSON.stringify({
      mode: primary.length ? "dom" : "screen",
      videoID: state.id, cues: primary, chinese: cues(chinese, current), paused: video.paused,
      replaying: !!state.cancelReplay, replayError: !!state.replayError,
      seekable: timed ? Array.from({ length: video.seekable.length }, (_, i) =>
        [video.seekable.start(i), video.seekable.end(i)]).filter(pair => pair.every(Number.isFinite)) : [],
      videoRef: timed && ["youtube.com", "www.youtube.com"].includes(location.hostname) &&
        location.pathname === "/watch" && /^[A-Za-z0-9_-]{11}$/.test(new URLSearchParams(location.search).get("v") || "")
        ? "youtube:" + new URLSearchParams(location.search).get("v") : null
    });
  };
})();
