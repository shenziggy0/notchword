(() => {
  const key = "__notchwordSubtitlesV1";
  if (globalThis[key]) return;
  const states = new WeakMap();
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
      if (!video.__notchwordPlaybackObserver) {
        video.__notchwordPlaybackObserver = true;
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
      .filter(cue => cue.endTime >= current - 45 && cue.startTime <= current + 45)
      .slice(-80).map(cue => ({ text: clean(cue.text || ""), start: cue.startTime, end: cue.endTime }))
      .filter(cue => cue.text);
  }

  const selectors = [
    ["youtube.com", ".ytp-caption-segment"],
    ["netflix.com", ".player-timedtext-text-container"],
    ["bilibili.com", ".bpx-player-subtitle-panel-text, .bilibili-player-video-subtitle span"],
    ["primevideo.com", ".atvwebplayersdk-captions-text, .webPlayerSDKContainer .subtitles"],
    ["amazon.com", ".atvwebplayersdk-captions-text"]
  ];

  function captionText() {
    const host = location.hostname;
    const selector = selectors.find(([domain]) => host === domain || host.endsWith("." + domain))?.[1];
    const nodes = document.querySelectorAll(selector || "[class*='caption'] [class*='cue'], [class*='subtitle'] [class*='cue']");
    return clean(Array.from(nodes)
      .filter(node => node.getClientRects().length && getComputedStyle(node).visibility !== "hidden")
      .map(node => node.textContent).join(" "));
  }

  globalThis[key] = (command, expected) => {
    const video = currentVideo();
    if (!video) return JSON.stringify({ mode: "nosub" });
    const state = stateOf(video);
    const current = video.currentTime || 0;
    const protectedVideo = !!video.mediaKeys;
    const advertisement = !!video.closest(".ad-showing") || !!document.querySelector(".html5-video-player.ad-showing");
    if (command !== "state") {
      if (expected !== state.id || protectedVideo || advertisement) return "false";
      if (command === "pause" && !video.paused) {
        video.pause();
        state.owned = true;
        return "true";
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
    const english = tracks.find(track => /^en(?:-|$)/i.test(track.language) && track.mode !== "disabled") ||
      tracks.find(track => track.mode === "showing" && !track.language);
    const chinese = tracks.find(track => /^zh(?:-|$)/i.test(track.language) && track.mode !== "disabled");

    let primary = cues(english, current).filter(cue => cue.start <= current);
    if (!primary.length) {
      const text = captionText();
      const last = state.cues.at(-1);
      if (last && (current + 0.25 < last.start || current - last.end > 45)) state.cues = [];
      if (text && text !== state.cues.at(-1)?.text) {
        state.cues.push({ text, start: current, end: current });
        if (state.cues.length > 80) state.cues.shift();
      }
      primary = state.cues;
    }

    return JSON.stringify({
      mode: primary.length ? "dom" : "screen",
      videoID: state.id, cues: primary, chinese: cues(chinese, current), paused: video.paused
    });
  };
})();
