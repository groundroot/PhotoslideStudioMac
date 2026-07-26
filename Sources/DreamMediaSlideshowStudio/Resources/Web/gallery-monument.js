window.__dreamSlideshow = { phase: "loading", lastError: "" };
window.addEventListener("error", (event) => {
  window.__dreamSlideshow.lastError = String(event.message || event.error || "unknown-error");
});
window.addEventListener("unhandledrejection", (event) => {
  window.__dreamSlideshow.lastError = String(event.reason || "unhandled-rejection");
});

const slug = document.body.dataset.projectSlug;
const query = new URLSearchParams(window.location.search);
const viewMode = query.get("view") || "browser";
const previewScope = query.get("previewScope") || "selected";
const previewEventID = query.get("eventID") || "";
const previewMuted = query.get("previewMuted") === "1";
const previewDebug = query.get("previewDebug") === "1";
document.body.dataset.viewMode = viewMode;

const overlay = document.getElementById("overlay");
const overlayTitle = document.getElementById("overlayTitle");
const overlaySubtitle = document.getElementById("overlaySubtitle");
const logoLayer = document.getElementById("logoLayer");
const logoImage = document.getElementById("logoImage");
const focusDebug = document.getElementById("focusDebug");
const focusDebugLabel = document.getElementById("focusDebugLabel");
const fullscreenToggle = document.getElementById("fullscreenToggle");
const backgroundAudio = document.getElementById("backgroundAudio");
const backgroundAudioVideo = document.getElementById("backgroundAudioVideo");
const emptyState = document.getElementById("emptyState");
const emptyStateEyebrow = document.getElementById("emptyStateEyebrow");
const emptyStateTitle = document.getElementById("emptyStateTitle");
const emptyStateSubtitle = document.getElementById("emptyStateSubtitle");
const slides = [
  document.getElementById("slideA"),
  document.getElementById("slideB")
];
const fxLayers = {
  "floating-particles": document.getElementById("fxParticles"),
  "light-leaks": document.getElementById("fxLightLeaks"),
  "glass-orbs": document.getElementById("fxGlassOrbs"),
  "gradient-mesh": document.getElementById("fxGradientMesh"),
  "paper-grain": document.getElementById("fxPaperGrain"),
  "prism-lines": document.getElementById("fxPrismLines")
};
const TARGET_FPS = 60;
const PROJECT_REFRESH_MS = 30000;
const MAX_PRELOADED_ASSETS = 6;
const MAX_SUBJECT_FOCUS_CACHE_ENTRIES = 256;

const WEB_SLIDE_LANGUAGE = {
  motion: {
    "none": { key: "none", label: "기본 슬라이드" },
    "ken-burns": { key: "ken-burns", label: "캔번스" }
  },
  transition: {
    "none": { key: "none", label: "없음" },
    "crossfade": { key: "crossfade", label: "디졸브" },
    "page-left": { key: "page-left", label: "책장넘기기 좌" },
    "page-right": { key: "page-right", label: "책장넘기기 우" },
    "page-up": { key: "page-up", label: "책장넘기기 상" },
    "page-down": { key: "page-down", label: "책장넘기기 하" },
    "slide-left": { key: "slide-left", label: "슬라이드(밀어내기) 좌" },
    "slide-right": { key: "slide-right", label: "슬라이드(밀어내기) 우" },
    "slide-up": { key: "slide-up", label: "슬라이드(밀어내기) 상" },
    "slide-down": { key: "slide-down", label: "슬라이드(밀어내기) 하" }
  },
  fx: {
    "none": { key: "none", label: "None" },
    "floating-particles": { key: "floating-particles", label: "Floating Particles" },
    "light-leaks": { key: "light-leaks", label: "Light Leaks" },
    "glass-orbs": { key: "glass-orbs", label: "Glass Orbs" },
    "gradient-mesh": { key: "gradient-mesh", label: "Gradient Mesh" },
    "paper-grain": { key: "paper-grain", label: "Paper Grain" },
    "prism-lines": { key: "prism-lines", label: "Prism Lines" }
  },
  timing(payload, item) {
    const configuredSlideMs = Math.round(safeDurationSeconds(payload.slideSeconds, 8) * 1000);
    const videoDurationMs = item?.type === "video"
      ? Math.max(600, Math.round(safeDurationSeconds(item.durationSeconds, payload.slideSeconds || 8) * 1000))
      : configuredSlideMs;
    const contentMs = item?.type === "video" ? videoDurationMs : configuredSlideMs;
    const transitionKey = WEB_SLIDE_LANGUAGE.transition[payload.transitionEffect]?.key || "crossfade";
    if (transitionKey === "none") {
      return {
        slideMs: contentMs,
        transitionMs: 0,
        overlapMs: 0,
        advanceMs: Math.max(600, contentMs),
        motionMs: contentMs
      };
    }

    const rawTransitionMs = Math.round(safeDurationSeconds(payload.transitionSeconds, 2.6) * 1000);
    // 트랜지션은 전환 주기(사진 표시 시간)를 넘을 수 없다.
    const transitionMs = item?.type === "video" ? rawTransitionMs : Math.min(rawTransitionMs, contentMs);
    const overlapMs = 0;
    // 사진의 "표시 시간"은 사진 전환 주기를 의미하도록 트랜지션 시간을 차감한다.
    // (표시 8초·전환 4초면 12초가 아니라 8초마다 다음 사진으로 넘어간다)
    // 영상은 끝까지 재생한 뒤 전환한다.
    const advanceMs = item?.type === "video"
      ? Math.max(600, contentMs)
      : Math.max(600, contentMs - transitionMs);
    const motionMs = contentMs + transitionMs;

    return {
      slideMs: contentMs,
      transitionMs,
      overlapMs,
      advanceMs,
      motionMs
    };
  }
};

const state = {
  payload: null,
  payloadVersion: "",
  queue: [],
  assetCache: new Map(),
  activeSlot: 0,
  transitionTimer: 0,
  refreshTimer: 0,
  playbackToken: 0,
  installedFontSignatures: {},
  backgroundAudioSignature: "",
  activeContext: null,
  fullscreenHideTimer: 0
};
const subjectFocusCache = new Map();
const subjectFocusPending = new Map();

function isFullscreenActive() {
  return Boolean(document.fullscreenElement || document.webkitFullscreenElement);
}

async function enterFullscreen() {
  const target = document.documentElement;
  if (target.requestFullscreen) {
    await target.requestFullscreen({ navigationUI: "hide" });
    return;
  }
  if (target.webkitRequestFullscreen) {
    target.webkitRequestFullscreen();
  }
}

async function exitFullscreen() {
  if (document.exitFullscreen) {
    await document.exitFullscreen();
    return;
  }
  if (document.webkitExitFullscreen) {
    document.webkitExitFullscreen();
  }
}

function syncFullscreenButton() {
  if (!fullscreenToggle) {
    return;
  }
  if (viewMode === "signage") {
    fullscreenToggle.hidden = true;
    fullscreenToggle.classList.remove("is-auto-hidden");
    return;
  }
  fullscreenToggle.hidden = false;
  fullscreenToggle.textContent = isFullscreenActive() ? "전체화면 종료" : "전체화면";
  fullscreenToggle.setAttribute("aria-pressed", String(isFullscreenActive()));
  fullscreenToggle.classList.remove("is-auto-hidden");
  if (isFullscreenActive()) {
    scheduleFullscreenButtonHide();
  } else {
    clearFullscreenButtonHideTimer();
  }
}

function clearFullscreenButtonHideTimer() {
  if (state.fullscreenHideTimer) {
    window.clearTimeout(state.fullscreenHideTimer);
    state.fullscreenHideTimer = 0;
  }
}

function scheduleFullscreenButtonHide() {
  clearFullscreenButtonHideTimer();
  if (!fullscreenToggle || !isFullscreenActive() || viewMode === "signage") {
    return;
  }
  state.fullscreenHideTimer = window.setTimeout(() => {
    fullscreenToggle?.classList.add("is-auto-hidden");
    state.fullscreenHideTimer = 0;
  }, 3000);
}

function reviveFullscreenButton() {
  if (!fullscreenToggle || !isFullscreenActive() || viewMode === "signage") {
    return;
  }
  fullscreenToggle.classList.remove("is-auto-hidden");
  scheduleFullscreenButtonHide();
}

async function toggleFullscreen() {
  try {
    if (isFullscreenActive()) {
      await exitFullscreen();
    } else {
      await enterFullscreen();
    }
  } catch (_) {
  } finally {
    syncFullscreenButton();
  }
}

function stopBackgroundAudio() {
  backgroundAudio.pause();
  backgroundAudio.removeAttribute("src");
  backgroundAudio.load();

  backgroundAudioVideo.pause();
  backgroundAudioVideo.removeAttribute("src");
  backgroundAudioVideo.load();

  state.backgroundAudioSignature = "";
}

function retryBackgroundAudioPlayback() {
  if (previewMuted) {
    return;
  }

  if (backgroundAudio.getAttribute("src")) {
    const playPromise = backgroundAudio.play();
    if (playPromise?.catch) {
      playPromise.catch(() => {});
    }
  }

  if (backgroundAudioVideo.getAttribute("src")) {
    const playPromise = backgroundAudioVideo.play();
    if (playPromise?.catch) {
      playPromise.catch(() => {});
    }
  }
}

function configureBackgroundMediaElement(element, sourceURL, volume) {
  element.loop = true;
  element.volume = previewMuted ? 0 : volume;
  element.muted = previewMuted;
  if (element.getAttribute("src") !== sourceURL) {
    element.setAttribute("src", sourceURL);
    element.load();
  }
  const playPromise = element.play();
  if (playPromise?.catch) {
    playPromise.catch(() => {});
  }
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function deterministicUnit(seed) {
  let hash = 2166136261;
  const text = String(seed || "");
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return ((hash >>> 0) % 10000) / 10000;
}

function focusCacheKey(item) {
  return String(item?.url || item?.name || "");
}

function assetCacheKey(item) {
  return `${item?.type || "image"}:${String(item?.url || "")}`;
}

function markMapEntryAsRecentlyUsed(map, key) {
  if (!map.has(key)) {
    return null;
  }
  const value = map.get(key);
  map.delete(key);
  map.set(key, value);
  return value;
}

function rememberSubjectFocus(key, focusPoint) {
  if (!key) {
    return;
  }
  subjectFocusCache.delete(key);
  subjectFocusCache.set(key, focusPoint);
  while (subjectFocusCache.size > MAX_SUBJECT_FOCUS_CACHE_ENTRIES) {
    const oldestKey = subjectFocusCache.keys().next().value;
    if (!oldestKey) {
      break;
    }
    subjectFocusCache.delete(oldestKey);
  }
}

function releasePreloadedAsset(asset) {
  if (asset instanceof HTMLVideoElement) {
    asset.pause();
    asset.removeAttribute("src");
    asset.load();
    return;
  }

  if (asset instanceof HTMLImageElement) {
    asset.removeAttribute("src");
  }
}

function retainedAssetCacheKeys(extraKeys = []) {
  const keys = new Set(extraKeys.filter(Boolean));
  if (state.activeContext?.item) {
    keys.add(assetCacheKey(state.activeContext.item));
  }
  const nextContext = peekNextItemContext();
  if (nextContext?.item) {
    keys.add(assetCacheKey(nextContext.item));
  }
  return keys;
}

function pruneAssetCache(extraRetainedKeys = []) {
  const retainedKeys = retainedAssetCacheKeys(extraRetainedKeys);
  if (state.assetCache.size <= MAX_PRELOADED_ASSETS) {
    return;
  }

  for (const key of [...state.assetCache.keys()]) {
    if (state.assetCache.size <= MAX_PRELOADED_ASSETS) {
      break;
    }
    if (retainedKeys.has(key)) {
      continue;
    }
    const pendingAsset = state.assetCache.get(key);
    state.assetCache.delete(key);
    pendingAsset?.then?.(releasePreloadedAsset).catch?.(() => {});
  }
}

function clearAssetCache() {
  for (const pendingAsset of state.assetCache.values()) {
    pendingAsset?.then?.(releasePreloadedAsset).catch?.(() => {});
  }
  state.assetCache.clear();
}

function clampFocusPoint(focusPoint) {
  return {
    x: clamp(Number(focusPoint?.x ?? 50), 28, 72),
    y: clamp(Number(focusPoint?.y ?? 50), 28, 72),
    source: String(focusPoint?.source || "fallback-center")
  };
}

function nativeFocusPointForItem(item) {
  if (!item?.focusPoint) {
    return null;
  }
  return clampFocusPoint(item.focusPoint);
}

function estimateSubjectFocusFromImage(image) {
  try {
    const width = 64;
    const height = 64;
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) {
      return { x: 50, y: 50 };
    }

    context.drawImage(image, 0, 0, width, height);
    const pixels = context.getImageData(0, 0, width, height).data;
    let sumX = 0;
    let sumY = 0;
    let totalWeight = 0;

    for (let y = 1; y < height - 1; y += 1) {
      for (let x = 1; x < width - 1; x += 1) {
        const index = (y * width + x) * 4;
        const rightIndex = (y * width + (x + 1)) * 4;
        const downIndex = ((y + 1) * width + x) * 4;
        const luminance = (pixels[index] * 0.299) + (pixels[index + 1] * 0.587) + (pixels[index + 2] * 0.114);
        const luminanceRight = (pixels[rightIndex] * 0.299) + (pixels[rightIndex + 1] * 0.587) + (pixels[rightIndex + 2] * 0.114);
        const luminanceDown = (pixels[downIndex] * 0.299) + (pixels[downIndex + 1] * 0.587) + (pixels[downIndex + 2] * 0.114);
        const edgeWeight = Math.abs(luminance - luminanceRight) + Math.abs(luminance - luminanceDown);
        const dx = (x / width) - 0.5;
        const dy = (y / height) - 0.5;
        const centerBias = 1 - (Math.min(1, Math.hypot(dx, dy) / 0.707) * 0.45);
        const weight = (edgeWeight * centerBias) + 0.0001;
        sumX += x * weight;
        sumY += y * weight;
        totalWeight += weight;
      }
    }

    if (totalWeight <= 0.0001) {
      return { x: 50, y: 50 };
    }

    return clampFocusPoint({
      x: (sumX / totalWeight / width) * 100,
      y: (sumY / totalWeight / height) * 100
    });
  } catch (_) {
    return { x: 50, y: 50 };
  }
}

async function refineSubjectFocusWithFaceDetector(item, image) {
  if (!("FaceDetector" in window)) {
    return null;
  }

  try {
    const detector = new window.FaceDetector({ fastMode: true, maxDetectedFaces: 3 });
    const faces = await detector.detect(image);
    if (!faces?.length) {
      return null;
    }

    const largestFace = faces.reduce((largest, current) => {
      const currentArea = current.boundingBox.width * current.boundingBox.height;
      const largestArea = largest.boundingBox.width * largest.boundingBox.height;
      return currentArea > largestArea ? current : largest;
    });

    return clampFocusPoint({
      x: ((largestFace.boundingBox.x + (largestFace.boundingBox.width / 2)) / image.naturalWidth) * 100,
      y: ((largestFace.boundingBox.y + (largestFace.boundingBox.height / 2)) / image.naturalHeight) * 100
    });
  } catch (_) {
    return null;
  }
}

function primeSubjectFocus(item, image) {
  const key = focusCacheKey(item);
  if (!key || subjectFocusCache.has(key) || subjectFocusPending.has(key)) {
    return;
  }

  const nativeFocusPoint = nativeFocusPointForItem(item);
  if (nativeFocusPoint) {
    rememberSubjectFocus(key, nativeFocusPoint);
    refreshActiveSubjectFocusIfNeeded(item);
    return;
  }

  const heuristicFocus = estimateSubjectFocusFromImage(image);
  rememberSubjectFocus(key, heuristicFocus);

  const pending = refineSubjectFocusWithFaceDetector(item, image)
    .then((faceFocus) => {
      if (faceFocus) {
        rememberSubjectFocus(key, faceFocus);
        refreshActiveSubjectFocusIfNeeded(item);
      }
    })
    .catch(() => {})
    .finally(() => {
      subjectFocusPending.delete(key);
    });

  subjectFocusPending.set(key, pending);
}

function shuffle(items) {
  const clone = [...items];
  for (let index = clone.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    [clone[index], clone[swapIndex]] = [clone[swapIndex], clone[index]];
  }
  return clone;
}

function safeDurationSeconds(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? clamp(parsed, 0.4, 120) : fallback;
}

function safeColor(value, fallback) {
  return /^#[0-9a-f]{6}$/i.test(String(value || "")) ? value : fallback;
}

function kenBurnsFocusPoint(event, item) {
  if (event?.kenBurnsFocusMode === "subject") {
    return subjectFocusCache.get(focusCacheKey(item))
      || nativeFocusPointForItem(item)
      || { x: 50, y: 50, source: "fallback-center" };
  }

  if (event?.kenBurnsFocusMode !== "random") {
    return { x: 50, y: 50 };
  }

  const seedBase = `${event?.id || event?.name || "event"}:${item?.url || item?.name || "item"}`;
  return {
    x: 30 + deterministicUnit(`${seedBase}:x`) * 40,
    y: 30 + deterministicUnit(`${seedBase}:y`) * 40,
    source: "random"
  };
}

function kenBurnsPanBudgetPercent(amount, fitMode) {
  switch (fitMode) {
    case "fit":
      return amount * 22;
    case "stretch":
      return amount * 10;
    case "force-16-9":
      return amount * 42;
    case "fill":
    default:
      return amount * 50;
  }
}

function kenBurnsTranslationForFocus(focusPoint, amount, fitMode) {
  const budget = kenBurnsPanBudgetPercent(amount, fitMode);
  const normalizedX = clamp((50 - focusPoint.x) / 20, -1, 1);
  const normalizedY = clamp((50 - focusPoint.y) / 20, -1, 1);

  return {
    x: normalizedX * budget,
    y: normalizedY * budget
  };
}

function mediaTransform(translation, scale) {
  return `translate3d(${translation.x.toFixed(3)}%, ${translation.y.toFixed(3)}%, 0) scale(${scale.toFixed(4)})`;
}

function applyKenBurnsMotion(element, event, item, timing) {
  const amount = clamp(Number(event?.kenBurnsScalePercent ?? 3), 0, 20) / 100;
  const direction = event?.kenBurnsDirection === "zoom-out" ? "zoom-out" : "zoom-in";
  const focusPoint = kenBurnsFocusPoint(event, item);
  const fitMode = item?.mediaFitMode || event?.mediaFitMode || "fill";
  const startScale = direction === "zoom-out" ? 1 + amount : 1;
  const endScale = direction === "zoom-out" ? 1 : 1 + amount;
  const focusTranslation =
    event?.kenBurnsFocusMode && event.kenBurnsFocusMode !== "center"
      ? kenBurnsTranslationForFocus(focusPoint, amount, fitMode)
      : { x: 0, y: 0 };
  const startTranslation = direction === "zoom-out" ? focusTranslation : { x: 0, y: 0 };
  const endTranslation = direction === "zoom-out" ? { x: 0, y: 0 } : focusTranslation;
  const keyframes = [
    { transform: mediaTransform(startTranslation, startScale) },
    { transform: mediaTransform(endTranslation, endScale) }
  ];

  cancelOwnAnimations(element);
  element.dataset.motion = "ken-burns";
  element.style.animation = "none";
  element.style.transformOrigin = "50% 50%";
  element.style.transform = keyframes[0].transform;

  return element.animate(keyframes, {
    duration: timing.motionMs,
    easing: "linear",
    fill: "forwards"
  });
}

function shouldShowFocusDebug(event, item) {
  return previewDebug
    && event?.imageMotionEffect === "ken-burns"
    && event?.kenBurnsFocusMode === "subject"
    && item?.type !== "video";
}

function hideFocusDebugMarker() {
  if (!focusDebug) {
    return;
  }
  focusDebug.hidden = true;
}

function updateFocusDebugMarker(event, item) {
  if (!focusDebug) {
    return;
  }

  if (!shouldShowFocusDebug(event, item)) {
    hideFocusDebugMarker();
    return;
  }

  const focusPoint = subjectFocusCache.get(focusCacheKey(item))
    || nativeFocusPointForItem(item)
    || { x: 50, y: 50, source: "fallback-center" };
  const source = String(focusPoint.source || "fallback-center");
  focusDebug.hidden = false;
  focusDebug.style.left = `${focusPoint.x}%`;
  focusDebug.style.top = `${focusPoint.y}%`;
  if (focusDebugLabel) {
    focusDebugLabel.textContent = {
      "vision-face": "Vision 얼굴",
      "vision-group": "Vision 그룹",
      "fallback-center": "중앙 대체"
    }[source] || "얼굴/피사체";
  }
}

function refreshActiveSubjectFocusIfNeeded(item) {
  const activeContext = state.activeContext;
  if (!activeContext || focusCacheKey(activeContext.item) !== focusCacheKey(item)) {
    return;
  }

  updateFocusDebugMarker(activeContext.event, activeContext.item);
  if (activeContext.event?.imageMotionEffect !== "ken-burns" || activeContext.event?.kenBurnsFocusMode !== "subject") {
    return;
  }

  const activeSlide = slides[state.activeSlot];
  const mediaElement = activeContext.item?.type === "video"
    ? activeSlide?.querySelector(".slide__video")
    : activeSlide?.querySelector(".slide__image");

  if (!mediaElement) {
    return;
  }

  // 얼굴 좌표가 늦게 도착해 모션을 다시 적용할 때, 진행 시간을 보존해
  // 줌이 처음(줌아웃이면 최대 확대)으로 튀지 않게 한다.
  const runningAnimation = mediaElement.getAnimations().find((animation) => animation.effect);
  const elapsed = typeof runningAnimation?.currentTime === "number" ? runningAnimation.currentTime : 0;
  const nextAnimation = applyKenBurnsMotion(mediaElement, activeContext.event, activeContext.item, activeContext.timing);
  if (nextAnimation && elapsed > 0) {
    nextAnimation.currentTime = elapsed;
  }
}

function applyMediaMotion(element, item, event, timing) {
  const motionKey = WEB_SLIDE_LANGUAGE.motion[event?.imageMotionEffect]?.key || "ken-burns";

  cancelOwnAnimations(element);
  element.dataset.motion = "";
  element.style.animation = "none";
  element.style.transform = "";
  element.style.transformOrigin = "";
  void element.offsetWidth;
  element.style.animation = "";

  if (motionKey === "none") {
    element.dataset.motion = "none";
    element.style.transform = "translate3d(0, 0, 0) scale(1.02)";
    return;
  }

  if (motionKey === "ken-burns") {
    // '맞춤(fit)'·'16:9 강제'는 object-fit: contain이라 이미지가 화면을 가득
    // 채우지 않는다(의도된 정적 여백). 이 모드에서 Ken Burns 줌/팬을 적용하면
    // 여백 위로 움직임이 더해져 빈 공간이 드러나므로, 모션 없이 정지 표시한다.
    // 채움(fill)·늘림(stretch)은 화면을 덮으므로 Ken Burns를 그대로 적용한다.
    const fitMode = item?.mediaFitMode || event?.mediaFitMode || "fill";
    if (fitMode !== "fill" && fitMode !== "stretch") {
      element.dataset.motion = "none";
      element.style.transform = "translate3d(0, 0, 0) scale(1.02)";
      return;
    }
    applyKenBurnsMotion(element, event, item, timing);
    return;
  }

  element.dataset.motion = motionKey;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}

function hexToRgb(hex) {
  const safe = safeColor(hex, "#FFFFFF").slice(1);
  return {
    r: Number.parseInt(safe.slice(0, 2), 16),
    g: Number.parseInt(safe.slice(2, 4), 16),
    b: Number.parseInt(safe.slice(4, 6), 16)
  };
}

function strokeColorFor(hex) {
  const { r, g, b } = hexToRgb(hex);
  const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  return luminance > 0.58 ? "rgba(0, 0, 0, 0.46)" : "rgba(255, 255, 255, 0.42)";
}

function textShadow(style, fallbackAlpha) {
  if (!style?.shadowEnabled) {
    return "none";
  }

  const strength = clamp(Number(style.shadowStrength || 0.25), 0.05, 1);
  const opacity = clamp(Number(style.shadowOpacity ?? fallbackAlpha * strength), 0, 1);
  const distance = Math.round(Math.max(0, Number(style.shadowDistance ?? (6 + strength * 24))));
  const blur = Math.round(Math.max(0, Number(style.shadowBlur ?? (12 + strength * 30))));
  const feather = Math.round(Math.max(0, Number(style.shadowFeather ?? (strength * 14))));
  const alphaA = Math.max(0.08, opacity);
  const alphaB = Math.max(0.04, opacity * 0.38);
  return `0 ${distance}px ${blur}px rgba(0, 0, 0, ${alphaA}), 0 ${Math.round(distance * 0.5)}px ${blur + feather}px rgba(0, 0, 0, ${alphaB})`;
}

function installFontFaces(style, styleKey) {
  const fontFaces = Array.isArray(style?.fontFaces) ? style.fontFaces : [];
  const styleId = `dynamic-font-${styleKey}`;
  const signature = JSON.stringify(fontFaces);
  if (state.installedFontSignatures[styleKey] === signature) {
    return fontFaces.length
      ? `"${fontFaces[0].familyAlias}", ${style?.fontFamily || "sans-serif"}`
      : style?.fontFamily || "\"Pretendard Variable\", sans-serif";
  }

  if (!fontFaces.length) {
    state.installedFontSignatures[styleKey] = signature;
    return style?.fontFamily || "\"Pretendard Variable\", sans-serif";
  }

  const alias = fontFaces[0].familyAlias;
  const rules = fontFaces.map((face) => {
    return `@font-face { font-family: "${alias}"; src: url("${face.url}") format("${face.format}"); font-weight: ${face.weight}; font-style: normal; font-display: swap; }`;
  }).join("\n");

  const existing = document.getElementById(styleId);
  if (existing) {
    existing.remove();
  }

  const styleElement = document.createElement("style");
  styleElement.id = styleId;
  styleElement.textContent = rules;
  document.head.appendChild(styleElement);
  state.installedFontSignatures[styleKey] = signature;
  return `"${alias}", ${style?.fontFamily || "sans-serif"}`;
}

function setTimingVariables(timing) {
  const root = document.documentElement;
  root.style.setProperty("--transition-ms", `${timing.transitionMs}ms`);
  root.style.setProperty("--motion-ms", `${timing.motionMs}ms`);
}

function setEventStyleVariables(event) {
  const root = document.documentElement;
  const titleStyle = event.titleStyle || {};
  const subtitleStyle = event.subtitleStyle || {};
  const titleFont = installFontFaces(titleStyle, "title");
  const subtitleFont = installFontFaces(subtitleStyle, "subtitle");
  const titleSize = clamp(Number(titleStyle.size || 50), 1, 200);
  const subtitleSize = clamp(Number(subtitleStyle.size || 30), 1, 200);
  const dominantTextSize = Math.max(titleSize, subtitleSize);

  root.style.setProperty("--title-font", titleFont);
  root.style.setProperty("--subtitle-font", subtitleFont);
  root.style.setProperty("--title-size", `${titleSize}px`);
  root.style.setProperty("--subtitle-size", `${subtitleSize}px`);
  root.style.setProperty("--title-color", safeColor(titleStyle.color, "#FFFFFF"));
  root.style.setProperty("--subtitle-color", safeColor(subtitleStyle.color, "#FFFFFF"));
  root.style.setProperty("--title-weight", String(titleStyle.weight || 800));
  root.style.setProperty("--subtitle-weight", String(subtitleStyle.weight || 600));
  root.style.setProperty("--title-font-style", titleStyle.italicEnabled ? "italic" : "normal");
  root.style.setProperty("--subtitle-font-style", subtitleStyle.italicEnabled ? "italic" : "normal");
  root.style.setProperty("--title-letter-spacing", `${Number(titleStyle.letterSpacing || 0).toFixed(2)}px`);
  root.style.setProperty("--subtitle-letter-spacing", `${Number(subtitleStyle.letterSpacing || 0).toFixed(2)}px`);
  root.style.setProperty("--title-line-height", String(clamp(Number(titleStyle.lineHeight || 0.9), 0.7, 2.4)));
  root.style.setProperty("--subtitle-line-height", String(clamp(Number(subtitleStyle.lineHeight || 1.2), 0.8, 2.6)));
  root.style.setProperty("--title-shadow", textShadow(titleStyle, 0.52));
  root.style.setProperty("--subtitle-shadow", textShadow(subtitleStyle, 0.44));
  root.style.setProperty("--title-stroke-color", strokeColorFor(titleStyle.color || "#FFFFFF"));
  root.style.setProperty("--subtitle-stroke-color", strokeColorFor(subtitleStyle.color || "#FFFFFF"));
  root.style.setProperty("--title-stroke-width", `${clamp(titleSize / 95, 0, 1.2).toFixed(2)}px`);
  root.style.setProperty("--subtitle-stroke-width", `${clamp(subtitleSize / 110, 0, 0.9).toFixed(2)}px`);
  root.style.setProperty("--overlay-content-padding-inline", `${clamp(Math.round(dominantTextSize * 0.34), 14, 34)}px`);
  root.style.setProperty("--overlay-content-padding-block", `${clamp(Math.round(dominantTextSize * 0.18), 10, 22)}px`);
  root.style.setProperty("--overlay-content-gap", `${clamp(Math.round(dominantTextSize * 0.14), 8, 18)}px`);
  root.style.setProperty("--overlay-content-radius", `${clamp(Math.round(dominantTextSize * 0.34), 16, 28)}px`);
}

function applyEventPresentation(event, timing) {
  setTimingVariables(timing);
  setEventStyleVariables(event);
  applyOverlay(event);
  applyLogo(event.logo || null);
  applyBackgroundAudioForEvent(event);
  applySpecialEffect(event.specialEffect || "none");
}

function applyOverlay(event) {
  const positions = [
    "topLeft", "topCenter", "topRight",
    "middleLeft", "center", "middleRight",
    "bottomLeft", "bottomCenter", "bottomRight"
  ];
  const position = positions.includes(event.overlayPosition) ? event.overlayPosition : "bottomLeft";
  const textEnabled = event.textEnabled !== false;
  const backgroundEffect = ["clean", "drop-shadow", "blur-bar"].includes(event.textBackgroundEffect)
    ? event.textBackgroundEffect
    : "blur-bar";

  overlay.hidden = !textEnabled;
  overlay.className = `overlay overlay--${position}`;
  overlay.dataset.backgroundEffect = backgroundEffect;
  document.documentElement.style.setProperty("--overlay-offset-x", `${Math.round(Number(event.overlayOffsetX || 0))}px`);
  document.documentElement.style.setProperty("--overlay-offset-y", `${Math.round(Number(event.overlayOffsetY || 0))}px`);
  overlayTitle.innerHTML = escapeHtml(event.title || event.name || "");
  overlaySubtitle.innerHTML = escapeHtml(event.displaySubtitle || event.subtitle || "");
  overlaySubtitle.hidden = !String(event.displaySubtitle || event.subtitle || "").trim();
}

function applyLogo(logo) {
  const positions = [
    "topLeft", "topCenter", "topRight",
    "middleLeft", "center", "middleRight",
    "bottomLeft", "bottomCenter", "bottomRight"
  ];
  const position = positions.includes(logo?.position) ? logo.position : "topRight";
  const enabled = Boolean(logo?.enabled && logo?.url);

  logoLayer.className = `logo-layer logo-layer--${position}`;
  logoLayer.hidden = !enabled;
  document.documentElement.style.setProperty("--logo-width", `${Math.round(clamp(Number(logo?.size ?? 160), 40, 520))}px`);
  document.documentElement.style.setProperty("--logo-offset-x", `${Math.round(Number(logo?.offsetX || 0))}px`);
  document.documentElement.style.setProperty("--logo-offset-y", `${Math.round(Number(logo?.offsetY || 0))}px`);
  document.documentElement.style.setProperty("--logo-opacity", String(clamp(Number(logo?.opacity ?? 1), 0, 1)));

  if (!enabled) {
    logoImage.removeAttribute("src");
    return;
  }

  const nextURL = String(logo.url);
  if (logoImage.getAttribute("src") !== nextURL) {
    logoImage.setAttribute("src", nextURL);
  }
}

function applyBackgroundAudioForEvent(event) {
  const audioConfig = event?.backgroundAudio || {};
  const sourceKind = String(audioConfig.sourceKind || "none");
  const sourceURL = String(audioConfig.url || "");
  const mediaType = String(audioConfig.mediaType || "audio");
  const volume = clamp(Number(audioConfig.volume ?? 0.72), 0, 1);
  const signature = [sourceKind, sourceURL, mediaType, volume.toFixed(3)].join("|");

  if (signature === state.backgroundAudioSignature) {
    backgroundAudio.volume = previewMuted ? 0 : volume;
    backgroundAudio.muted = previewMuted;
    backgroundAudioVideo.volume = previewMuted ? 0 : volume;
    backgroundAudioVideo.muted = previewMuted;
    return;
  }

  stopBackgroundAudio();

  if (sourceKind === "local-file" && sourceURL) {
    if (mediaType === "video") {
      configureBackgroundMediaElement(backgroundAudioVideo, sourceURL, volume);
    } else {
      configureBackgroundMediaElement(backgroundAudio, sourceURL, volume);
    }
    state.backgroundAudioSignature = signature;
    return;
  }
}

function applySpecialEffect(effect) {
  const activeKey = WEB_SLIDE_LANGUAGE.fx[effect]?.key || "none";
  document.body.dataset.fx = activeKey;
  Object.entries(fxLayers).forEach(([key, element]) => {
    element.classList.toggle("is-active", key === activeKey);
  });
}

function applyEmptyState(payload) {
  emptyStateEyebrow.textContent = "";
  emptyStateTitle.textContent = payload?.emptyStateTitle || "이벤트에 미디어를 추가해주세요.";
  emptyStateSubtitle.textContent = payload?.emptyStateSubtitle || "프로젝트 안 이벤트들이 하나의 URL에서 연속 재생됩니다.";
}

function orderedEvents(payload) {
  let events = [...(payload?.events || [])].filter((event) =>
    (Array.isArray(event.items) && event.items.length > 0) || youtubePlaylistID(event.youtubePlaylist)
  );
  if (viewMode === "browser" && previewScope !== "playlist" && previewEventID) {
    events = events.filter((event) => String(event.id) === previewEventID);
  }
  switch (payload?.eventPlaybackMode) {
    case "random":
      return shuffle(events);
    case "sequential":
      return events.sort((lhs, rhs) => (lhs.createdAt || 0) - (rhs.createdAt || 0));
    case "playlist":
    default:
      return events;
  }
}

function orderedItemsForEvent(event) {
  const items = [...(event?.items || [])];
  return event?.playbackOrder === "random" ? shuffle(items) : items;
}

function buildQueue(payload) {
  return orderedEvents(payload).flatMap((event) => {
    const playlistID = youtubePlaylistID(event.youtubePlaylist);
    if (playlistID) {
      return [{
        event,
        item: { type: "youtube", playlistID, name: event.name || "YouTube" }
      }];
    }
    return orderedItemsForEvent(event).map((item) => ({
      event,
      item: {
        ...item,
        mediaFitMode: event.mediaFitMode || "fill"
      }
    }));
  });
}

function youtubePlaylistID(rawURL) {
  const value = String(rawURL || "").trim();
  if (!value) {
    return null;
  }
  const listMatch = value.match(/[?&]list=([\w-]+)/);
  if (listMatch) {
    return listMatch[1];
  }
  // 재생목록 ID를 그대로 붙여넣은 경우 (PL/UU/OL/FL 접두)
  if (/^(PL|UU|OL|FL|RD)[\w-]{10,}$/.test(value)) {
    return value;
  }
  return null;
}

function ensureQueue() {
  if (!state.payload?.events?.length) {
    state.queue = [];
    return;
  }

  if (state.queue.length === 0) {
    state.queue = buildQueue(state.payload);
  }
}

function nextItemContext() {
  ensureQueue();
  return state.queue.shift() ?? null;
}

function peekNextItemContext() {
  ensureQueue();
  return state.queue[0] ?? null;
}

function warmNextItem() {
  const context = peekNextItemContext();
  if (!context?.item) {
    return;
  }

  const key = assetCacheKey(context.item);
  preload(context.item).catch(() => {});
  pruneAssetCache([key]);
}

function preload(item) {
  const key = assetCacheKey(item);
  if (state.assetCache.has(key)) {
    return markMapEntryAsRecentlyUsed(state.assetCache, key);
  }

  const pending = new Promise((resolve, reject) => {
    if (item?.type === "video") {
      const video = document.createElement("video");
      video.preload = "auto";
      video.muted = true;
      video.playsInline = true;
      video.crossOrigin = "anonymous";
      const complete = () => {
        cleanup();
        resolve(video);
      };
      const fail = () => {
        cleanup();
        reject(new Error("video-preload-failed"));
      };
      const cleanup = () => {
        video.onloadeddata = null;
        video.oncanplay = null;
        video.onerror = null;
      };
      video.oncanplay = complete;
      video.onloadeddata = complete;
      video.onerror = fail;
      video.src = item.url;
      video.load();
      return;
    }

    const image = new Image();
    image.decoding = "async";
    image.onload = async () => {
      try {
        if (image.decode) {
          await image.decode();
        }
      } catch (_) {
      }
      primeSubjectFocus(item, image);
      resolve(image);
    };
    image.onerror = reject;
    image.src = item.url;
  });

  state.assetCache.set(key, pending);
  pruneAssetCache([key]);
  return pending.catch((error) => {
    state.assetCache.delete(key);
    throw error;
  });
}

function ensureImageReady(element, item) {
  return new Promise((resolve, reject) => {
    const complete = async () => {
      try {
        if (element.decode) {
          await element.decode();
        }
      } catch (_) {
      }
      cleanup();
      resolve();
    };
    const fail = () => {
      cleanup();
      reject(new Error(`image-hydrate-failed:${item?.url || ""}`));
    };
    const cleanup = () => {
      element.onload = null;
      element.onerror = null;
    };

    if (element.complete && element.naturalWidth > 0) {
      complete();
      return;
    }

    element.onload = () => {
      complete();
    };
    element.onerror = fail;
  });
}

function ensureVideoReady(element, item) {
  return new Promise((resolve, reject) => {
    const ready = () => {
      cleanup();
      resolve();
    };
    const fail = () => {
      cleanup();
      reject(new Error(`video-hydrate-failed:${item?.url || ""}`));
    };
    const cleanup = () => {
      element.oncanplay = null;
      element.onloadeddata = null;
      element.onerror = null;
    };

    if (element.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA) {
      ready();
      return;
    }

    element.oncanplay = ready;
    element.onloadeddata = ready;
    element.onerror = fail;
  });
}

function resetSlide(slide) {
  slide.getAnimations?.().forEach((animation) => animation.cancel());
  slide.classList.remove("is-active", "is-entering", "is-leaving");
  slide.dataset.transition = "";
  slide.style.transform = "";
  slide.style.opacity = "";
  slide.style.filter = "";
  slide.style.clipPath = "";
  slide.style.transition = "";
  slide.style.zIndex = "";
  slide.dataset.fit = "";
  const image = slide.querySelector(".slide__image");
  const video = slide.querySelector(".slide__video");
  image.getAnimations?.().forEach((animation) => animation.cancel());
  video.getAnimations?.().forEach((animation) => animation.cancel());
  image.removeAttribute("src");
  image.style.display = "none";
  image.style.animation = "none";
  image.style.transform = "";
  image.style.transformOrigin = "";
  image.dataset.motion = "";
  void image.offsetWidth;
  image.style.animation = "";
  video.pause();
  video.removeAttribute("src");
  video.load();
  video.style.display = "none";
  video.style.animation = "none";
  video.style.transform = "";
  video.style.transformOrigin = "";
  video.dataset.motion = "";
  void video.offsetWidth;
  video.style.animation = "";
  slide.dataset.itemType = "";
}

async function hydrateSlide(slide, item, event, timing) {
  const image = slide.querySelector(".slide__image");
  const video = slide.querySelector(".slide__video");
  slide.dataset.transition = WEB_SLIDE_LANGUAGE.transition[event?.transitionEffect]?.key || "crossfade";
  slide.dataset.itemType = item.type || "image";
  slide.dataset.fit = item.mediaFitMode || "fill";

  if (item.type === "video") {
    image.style.display = "none";
    image.removeAttribute("src");
    video.pause();
    video.currentTime = 0;
    video.style.display = "block";
    if (video.getAttribute("src") !== item.url) {
      video.setAttribute("src", item.url);
      video.load();
    }
    await ensureVideoReady(video, item);
    applyMediaMotion(video, item, event, timing);
    return;
  }

  video.pause();
  video.removeAttribute("src");
  video.load();
  video.style.display = "none";
  image.style.display = "block";
  if (image.getAttribute("src") !== item.url) {
    image.setAttribute("src", item.url);
  }
  await ensureImageReady(image, item);
  applyMediaMotion(image, item, event, timing);
}

const youtubeLayer = document.getElementById("youtubeLayer");
let youtubePlayer = null;
let youtubeAPIPromise = null;
let youtubeSession = 0;

function ensureYouTubeAPI() {
  if (window.YT && window.YT.Player) {
    return Promise.resolve();
  }
  if (!youtubeAPIPromise) {
    youtubeAPIPromise = new Promise((resolve) => {
      const previous = window.onYouTubeIframeAPIReady;
      window.onYouTubeIframeAPIReady = () => {
        if (typeof previous === "function") {
          previous();
        }
        resolve();
      };
      const script = document.createElement("script");
      script.src = "https://www.youtube.com/iframe_api";
      document.head.appendChild(script);
    });
  }
  return youtubeAPIPromise;
}

function hideYouTubeLayer() {
  youtubeSession += 1;
  if (youtubeLayer) {
    youtubeLayer.hidden = true;
  }
  if (youtubePlayer) {
    try { youtubePlayer.destroy(); } catch (_) {}
    youtubePlayer = null;
    const host = document.createElement("div");
    host.id = "youtubePlayerHost";
    youtubeLayer?.replaceChildren(host);
  }
}

// 유튜브 플레이리스트를 순서대로 재생한다. 큐에 다른 항목이 없으면 무한 반복,
// 다른 이벤트가 있으면 재생목록이 끝났을 때 다음 항목으로 넘어간다.
async function playYouTubeItem(context, token) {
  const { item } = context;
  const loopForever = state.queue.length === 0; // 이 항목이 유일한 재생 대상
  await ensureYouTubeAPI();
  if (token !== state.playbackToken) {
    return;
  }

  youtubeSession += 1;
  const session = youtubeSession;
  youtubeLayer.hidden = false;

  const finishAndAdvance = () => {
    if (token !== state.playbackToken || session !== youtubeSession) {
      return;
    }
    hideYouTubeLayer();
    state.activeContext = null;
    scheduleAdvance(token, 200);
  };

  const host = document.createElement("div");
  host.id = "youtubePlayerHost";
  youtubeLayer.replaceChildren(host);
  if (youtubePlayer) {
    try { youtubePlayer.destroy(); } catch (_) {}
    youtubePlayer = null;
  }

  let hasUnmutedThisSession = false;
  let autoplayRetryTimer = 0;

  youtubePlayer = new YT.Player("youtubePlayerHost", {
    width: "100%",
    height: "100%",
    playerVars: {
      listType: "playlist",
      list: item.playlistID,
      autoplay: 1,
      mute: 1,
      // 화면에 재생 화면만 남기고 유튜브 UI(제목·채널·공유·워터마크·자막)는 최대한 숨긴다.
      controls: 0,
      disablekb: 1,
      fs: 0,
      iv_load_policy: 3,
      modestbranding: 1,
      rel: 0,
      cc_load_policy: 0,
      playsinline: 1,
      loop: loopForever ? 1 : 0,
      origin: window.location.origin
    },
    events: {
      onReady: (event) => {
        if (token !== state.playbackToken || session !== youtubeSession) {
          return;
        }
        event.target.mute();
        event.target.playVideo();

        // 일부 브라우저는 iframe이 막 준비된 시점에 자동재생 명령을 놓친다 —
        // 잠시 후 실제 재생 상태가 아니면 한 번 더 재생을 시도한다.
        window.clearTimeout(autoplayRetryTimer);
        autoplayRetryTimer = window.setTimeout(() => {
          if (token !== state.playbackToken || session !== youtubeSession) {
            return;
          }
          const currentState = event.target.getPlayerState?.();
          if (currentState !== YT.PlayerState.PLAYING && currentState !== YT.PlayerState.BUFFERING) {
            event.target.mute();
            event.target.playVideo();
          }
        }, 1200);
      },
      onStateChange: (event) => {
        if (token !== state.playbackToken || session !== youtubeSession) {
          return;
        }
        // 실제 재생이 시작된 뒤에만 음소거를 해제한다 — 재생 시작 전에 풀면
        // 브라우저 자동재생 정책에 막혀 재생 자체가 멈추는 경우가 있다.
        if (event.data === YT.PlayerState.PLAYING && !hasUnmutedThisSession) {
          hasUnmutedThisSession = true;
          if (!previewMuted) {
            event.target.unMute();
            event.target.setVolume(100);
          }
        }
        if (event.data === YT.PlayerState.ENDED && !loopForever) {
          const playlist = event.target.getPlaylist() || [];
          const index = event.target.getPlaylistIndex();
          if (playlist.length === 0 || index >= playlist.length - 1) {
            finishAndAdvance();
          }
        }
      },
      onError: () => {
        if (token !== state.playbackToken || session !== youtubeSession) {
          return;
        }
        if (loopForever) {
          return; // 다음 영상으로 자동 스킵됨
        }
        finishAndAdvance();
      }
    }
  });
}

function clearPlaybackTimer() {
  window.clearTimeout(state.transitionTimer);
}

function clearTimers() {
  clearPlaybackTimer();
  window.clearTimeout(state.refreshTimer);
}

function startMediaPlaybackForSlide(slide, item) {
  if (item?.type !== "video") {
    return;
  }
  const video = slide?.querySelector(".slide__video");
  if (!video) {
    return;
  }
  video.currentTime = 0;
  const playPromise = video.play();
  if (playPromise?.catch) {
    playPromise.catch(() => {});
  }
}

function scheduleAdvance(token, delayMs) {
  clearPlaybackTimer();
  state.transitionTimer = window.setTimeout(() => {
    runTransition(token);
  }, delayMs);
}

function cancelOwnAnimations(element) {
  const animations = element.getAnimations?.() ?? [];
  animations.forEach((animation) => {
    if (animation.effect?.target === element) {
      animation.cancel();
    }
  });
}

// Safari는 전체화면 전환 중 문서의 애니메이션 타임라인이 일시 정지되면서
// 진행 중이던 Web Animations API의 `finished` 프로미스가 끝내 resolve되지
// 않는 경우가 있다. 그 상태로 멈추면 재귀적으로 스스로를 재예약하는 슬라이드
// 타이머 체인이 영원히 끊기므로, 트랜지션 시간 기준의 타임아웃으로 항상
// 다음 슬라이드로 진행되도록 보장한다.
function waitForAnimations(animations, timeoutMs) {
  const settle = Promise.allSettled(animations.map((animation) => animation.finished));
  const timeout = new Promise((resolve) => window.setTimeout(resolve, timeoutMs));
  return Promise.race([settle, timeout]);
}

const SLIDE_TRANSITION_VECTORS = {
  "slide-left": { x: -1, y: 0 },
  "slide-right": { x: 1, y: 0 },
  "slide-up": { x: 0, y: -1 },
  "slide-down": { x: 0, y: 1 }
};

// 밀어내기 트랜지션: 나가는 슬라이드와 들어오는 슬라이드가 같은 방향으로 이동한다.
async function performSlidePush(outgoingSlide, incomingSlide, timing, token, key) {
  const vector = SLIDE_TRANSITION_VECTORS[key] || SLIDE_TRANSITION_VECTORS["slide-left"];
  const animationOptions = {
    duration: timing.transitionMs,
    easing: "ease-in-out",
    fill: "forwards"
  };

  cancelOwnAnimations(outgoingSlide);
  cancelOwnAnimations(incomingSlide);

  outgoingSlide.style.opacity = "1";
  outgoingSlide.style.zIndex = "2";
  outgoingSlide.classList.add("is-active");

  incomingSlide.style.opacity = "1";
  incomingSlide.style.zIndex = "3";
  incomingSlide.classList.add("is-active");

  const outX = vector.x * 100;
  const outY = vector.y * 100;
  const slideOut = outgoingSlide.animate(
    [
      { transform: "translate3d(0, 0, 0)" },
      { transform: `translate3d(${outX}%, ${outY}%, 0)` }
    ],
    animationOptions
  );
  const slideIn = incomingSlide.animate(
    [
      { transform: `translate3d(${-outX}%, ${-outY}%, 0)` },
      { transform: "translate3d(0, 0, 0)" }
    ],
    animationOptions
  );

  await waitForAnimations([slideOut, slideIn], timing.transitionMs + 400);

  if (token !== state.playbackToken) {
    return false;
  }

  incomingSlide.style.opacity = "";
  incomingSlide.style.zIndex = "";
  incomingSlide.style.transform = "";
  outgoingSlide.style.transform = "";
  return true;
}

async function performTransition(outgoingSlide, incomingSlide, timing, token, key) {
  if (SLIDE_TRANSITION_VECTORS[key]) {
    return performSlidePush(outgoingSlide, incomingSlide, timing, token, key);
  }
  return performCrossfade(outgoingSlide, incomingSlide, timing, token);
}

async function performCrossfade(outgoingSlide, incomingSlide, timing, token) {
  const animationOptions = {
    duration: timing.transitionMs,
    // 초반에 변화가 몰리는 곡선이면 4초 트랜지션이 1초처럼 보인다 —
    // 설정한 시간만큼 고르게 체감되도록 대칭 이징을 쓴다.
    easing: "ease-in-out",
    fill: "forwards"
  };

  cancelOwnAnimations(outgoingSlide);
  cancelOwnAnimations(incomingSlide);

  outgoingSlide.style.transform = "none";
  outgoingSlide.style.filter = "none";
  outgoingSlide.style.clipPath = "none";
  outgoingSlide.style.opacity = "1";
  outgoingSlide.style.zIndex = "2";
  outgoingSlide.classList.add("is-active");

  incomingSlide.style.transform = "none";
  incomingSlide.style.filter = "none";
  incomingSlide.style.clipPath = "none";
  incomingSlide.style.opacity = "0";
  incomingSlide.style.zIndex = "3";
  incomingSlide.classList.add("is-active");

  const fadeIn = incomingSlide.animate(
    [{ opacity: 0 }, { opacity: 1 }],
    animationOptions
  );
  const fadeOut = outgoingSlide.animate(
    [{ opacity: 1 }, { opacity: 0 }],
    animationOptions
  );

  await waitForAnimations([fadeIn, fadeOut], timing.transitionMs + 400);

  if (token !== state.playbackToken) {
    return false;
  }

  incomingSlide.style.opacity = "";
  incomingSlide.style.zIndex = "";
  return true;
}

async function showInitialSlide(token) {
  const payload = state.payload;
  if (!payload?.events?.length) {
    slides.forEach(resetSlide);
    stopBackgroundAudio();
    state.activeContext = null;
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }

  const context = nextItemContext();
  if (!context) {
    stopBackgroundAudio();
    state.activeContext = null;
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }
  const { event, item } = context;

  if (item.type === "youtube") {
    applyEventPresentation(event, WEB_SLIDE_LANGUAGE.timing(event, { type: "image" }));
    state.activeContext = { event, item, asset: null };
    hideFocusDebugMarker();
    await playYouTubeItem(context, token);
    return;
  }

  hideYouTubeLayer();
  let loadedAsset = null;

  try {
    loadedAsset = await preload(item);
  } catch (_) {
    stopBackgroundAudio();
    state.activeContext = null;
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }

  if (token !== state.playbackToken) {
    return;
  }

  const timing = WEB_SLIDE_LANGUAGE.timing(event, item);
  const initialSlide = slides[0];
  const spareSlide = slides[1];
  resetSlide(initialSlide);
  resetSlide(spareSlide);
  applyEventPresentation(event, timing);
  try {
    await hydrateSlide(initialSlide, item, event, timing);
  } catch (_) {
    stopBackgroundAudio();
    state.activeContext = null;
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }
  initialSlide.classList.add("is-active");
  startMediaPlaybackForSlide(initialSlide, item);
  state.activeSlot = 0;
  state.activeContext = { event, item, asset: loadedAsset, timing };
  updateFocusDebugMarker(event, item);
  emptyState.hidden = true;
  pruneAssetCache();
  scheduleAdvance(token, timing.advanceMs);
  warmNextItem();
}

async function runTransition(token) {
  if (token !== state.playbackToken) {
    return;
  }

  const payload = state.payload;
  if (!payload?.events?.length) {
    stopBackgroundAudio();
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }

  const context = nextItemContext();
  if (!context) {
    stopBackgroundAudio();
    state.activeContext = null;
    hideFocusDebugMarker();
    emptyState.hidden = false;
    return;
  }
  const { event, item } = context;

  if (item.type === "youtube") {
    applyEventPresentation(event, WEB_SLIDE_LANGUAGE.timing(event, { type: "image" }));
    state.activeContext = { event, item, asset: null };
    hideFocusDebugMarker();
    await playYouTubeItem(context, token);
    return;
  }

  hideYouTubeLayer();
  let loadedAsset = null;

  try {
    loadedAsset = await preload(item);
  } catch (_) {
    scheduleAdvance(token, 700);
    return;
  }

  if (token !== state.playbackToken) {
    return;
  }

  const timing = WEB_SLIDE_LANGUAGE.timing(event, item);
  const outgoingSlide = slides[state.activeSlot];
  const incomingSlide = slides[(state.activeSlot + 1) % slides.length];
  const transitionKey = WEB_SLIDE_LANGUAGE.transition[event.transitionEffect]?.key || "crossfade";
  const nextContext = { event, item, asset: loadedAsset };

  resetSlide(incomingSlide);
  setTimingVariables(timing);
  try {
    await hydrateSlide(incomingSlide, item, event, timing);
  } catch (_) {
    scheduleAdvance(token, 700);
    return;
  }
  outgoingSlide.dataset.transition = transitionKey;

  if (transitionKey === "none") {
    resetSlide(outgoingSlide);
    incomingSlide.classList.add("is-active");
    startMediaPlaybackForSlide(incomingSlide, item);
    applyEventPresentation(event, timing);
    state.activeSlot = (state.activeSlot + 1) % slides.length;
    state.activeContext = { ...nextContext, timing };
    updateFocusDebugMarker(event, item);
    pruneAssetCache();
    scheduleAdvance(token, timing.advanceMs);
    warmNextItem();
    return;
  }

  const crossfadeCompleted = await performTransition(outgoingSlide, incomingSlide, timing, token, transitionKey);
  if (!crossfadeCompleted) {
    return;
  }

  applyEventPresentation(event, timing);
  resetSlide(outgoingSlide);
  startMediaPlaybackForSlide(incomingSlide, item);
  state.activeSlot = (state.activeSlot + 1) % slides.length;
  state.activeContext = { ...nextContext, timing };
  updateFocusDebugMarker(event, item);
  pruneAssetCache();
  scheduleAdvance(token, timing.advanceMs);
  warmNextItem();
}

function startPlayback() {
  state.playbackToken += 1;
  const token = state.playbackToken;
  clearPlaybackTimer();
  hideYouTubeLayer();
  document.documentElement.style.setProperty("--target-frame-ms", `${1000 / TARGET_FPS}ms`);
  window.__dreamSlideshow.phase = "playback";
  showInitialSlide(token);
}

function render(payload) {
  clearAssetCache();
  state.payload = payload;
  state.payloadVersion = String(payload?.version || "");
  state.queue = buildQueue(payload);
  if (!state.queue.length) {
    stopBackgroundAudio();
    hideFocusDebugMarker();
  }
  applyEmptyState(payload);
  startPlayback();
}

async function fetchPayload() {
  const apiURL = new URL(`/api/project/${encodeURIComponent(slug)}`, window.location.origin);
  if (viewMode === "browser") {
    apiURL.searchParams.set("view", viewMode);
    apiURL.searchParams.set("previewScope", previewScope);
    if (previewEventID) {
      apiURL.searchParams.set("eventID", previewEventID);
    }
  }

  const response = await fetch(apiURL, {
    cache: "no-store"
  });

  if (!response.ok) {
    throw new Error(`Failed to load project: ${response.status}`);
  }

  return response.json();
}

async function boot() {
  try {
    window.__dreamSlideshow.phase = "fetch";
    const payload = await fetchPayload();
    render(payload);
    window.__dreamSlideshow.phase = "rendered";
  } catch (_) {
    stopBackgroundAudio();
    emptyState.hidden = false;
    emptyStateEyebrow.textContent = "MEDIA SLIDESHOW";
    emptyStateTitle.textContent = "슬라이드쇼를 불러오지 못했습니다.";
    emptyStateSubtitle.textContent = "프로젝트 데이터를 다시 확인해주세요.";
    window.__dreamSlideshow.phase = "failed";
  }
}

function scheduleRefresh() {
  window.clearTimeout(state.refreshTimer);
  state.refreshTimer = window.setTimeout(async () => {
    try {
      const payload = await fetchPayload();
      const nextVersion = String(payload?.version || "");
      if (nextVersion !== state.payloadVersion) {
        render(payload);
      }
    } catch (_) {
    } finally {
      scheduleRefresh();
    }
  }, PROJECT_REFRESH_MS);
}

window.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    boot();
    scheduleRefresh();
  }
});

window.addEventListener("beforeunload", () => {
  clearTimers();
  state.playbackToken += 1;
  stopBackgroundAudio();
  clearFullscreenButtonHideTimer();
  clearAssetCache();
  subjectFocusPending.clear();
});

fullscreenToggle?.addEventListener("click", () => {
  toggleFullscreen();
});

document.addEventListener("fullscreenchange", syncFullscreenButton);
document.addEventListener("webkitfullscreenchange", syncFullscreenButton);
window.addEventListener("pointermove", reviveFullscreenButton, { passive: true });
window.addEventListener("keydown", (event) => {
  if (viewMode !== "signage" && event.key?.toLowerCase() === "f") {
    toggleFullscreen();
  }
  if (event.key === "Escape" || event.key === "Esc") {
    clearFullscreenButtonHideTimer();
  } else {
    reviveFullscreenButton();
  }
  retryBackgroundAudioPlayback();
});

["pointerdown", "touchstart", "mousedown"].forEach((type) => {
  window.addEventListener(type, retryBackgroundAudioPlayback, { passive: true });
});

boot().finally(() => {
  syncFullscreenButton();
  scheduleRefresh();
});
