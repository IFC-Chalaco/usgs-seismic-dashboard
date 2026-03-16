const DATA_URL = "./data/earthquakes_live_curated.json";
const META_URL = "./data/dashboard_meta.json";
const GEOJSON_URL = "./data/earthquakes_live.geojson";
const REFRESH_POLL_INTERVAL_MS = 10000;
const TOAST_LIFETIME_MS = 5000;
const DISPLAY_TIME_ZONE = "America/New_York";
const SOUND_STORAGE_KEY = "usgs-dashboard-sound-enabled";

const magnitudeBands = [
  { label: "M < 1", min: -Infinity, max: 1 },
  { label: "M 1-1.9", min: 1, max: 2 },
  { label: "M 2-2.9", min: 2, max: 3 },
  { label: "M 3-3.9", min: 3, max: 4 },
  { label: "M 4+", min: 4, max: Infinity },
];

const zoneAliases = {
  "CA": "California",
  "B.C.": "British Columbia",
  "MX": "Mexico",
  "Puerto Rico": "Puerto Rico",
  "Dominican Republic": "Dominican Republic",
  "U.S. Virgin Islands": "U.S. Virgin Islands",
};

const state = {
  windowHours: 168,
  minMagnitude: 0,
  status: "all",
  zone: "all",
  soundEnabled: false,
};

const elements = {
  syncStamp: document.getElementById("syncStamp"),
  coverageWindow: document.getElementById("coverageWindow"),
  scopeLabel: document.getElementById("scopeLabel"),
  heroEventCount: document.getElementById("heroEventCount"),
  heroStrongest: document.getElementById("heroStrongest"),
  heroLatest: document.getElementById("heroLatest"),
  magnitudeRange: document.getElementById("magnitudeRange"),
  magnitudeValue: document.getElementById("magnitudeValue"),
  statusFilter: document.getElementById("statusFilter"),
  zoneFilter: document.getElementById("zoneFilter"),
  soundToggle: document.getElementById("soundToggle"),
  quickRange: document.getElementById("quickRange"),
  statsGrid: document.getElementById("statsGrid"),
  activityChart: document.getElementById("activityChart"),
  activityTitle: document.getElementById("activityTitle"),
  activityNote: document.getElementById("activityNote"),
  magnitudeChart: document.getElementById("magnitudeChart"),
  zoneChart: document.getElementById("zoneChart"),
  scatterChart: document.getElementById("scatterChart"),
  strongestList: document.getElementById("strongestList"),
  recentTableBody: document.getElementById("recentTableBody"),
  chartTooltip: document.getElementById("chartTooltip"),
  toastStack: document.getElementById("toastStack"),
};

let allEvents = [];
let dashboardMeta = null;
let map = null;
let mapLayer = null;
let knownEventIds = new Set();
let toastQueue = [];
let toastTimerId = null;
let refreshTimerId = null;
let audioContext = null;
let audioUnlockBound = false;

init().catch((error) => {
  console.error(error);
  document.body.innerHTML =
    '<div class="page-shell"><section class="hero-card is-empty"><div><p class="eyebrow">USGS seismic dashboard</p><h1>Dashboard unavailable.</h1><p class="lede">The published dashboard data could not be loaded. Check the browser console for details.</p></div></section></div>';
});

async function init() {
  const [dataPayload, metaPayload] = await Promise.all([
    fetchJson(DATA_URL),
    fetchJson(META_URL),
  ]);

  allEvents = (dataPayload.events || []).map(normalizeEvent);
  dashboardMeta = metaPayload;
  knownEventIds = new Set(allEvents.map((event) => event.id));

  hydrateSoundPreference();
  bindControls();
  populateZoneFilter(allEvents);
  render();
  startAutoRefresh();
}

function bindControls() {
  elements.magnitudeRange.addEventListener("input", (event) => {
    state.minMagnitude = Number(event.target.value);
    render();
  });

  elements.statusFilter.addEventListener("change", (event) => {
    state.status = event.target.value;
    render();
  });

  elements.zoneFilter.addEventListener("change", (event) => {
    state.zone = event.target.value;
    render();
  });

  elements.soundToggle.addEventListener("click", async () => {
    setSoundEnabled(!state.soundEnabled);

    if (state.soundEnabled) {
      try {
        await ensureAudioContext();
      } catch (error) {
        console.warn("Unable to initialize dashboard alert sound.", error);
      }
    }
  });

  elements.quickRange.addEventListener("click", (event) => {
    const button = event.target.closest("[data-hours]");
    if (!button) {
      return;
    }

    state.windowHours = Number(button.dataset.hours);
    elements.quickRange
      .querySelectorAll("[data-hours]")
      .forEach((item) => item.classList.toggle("is-active", item === button));
    render();
  });
}

function hydrateSoundPreference() {
  try {
    state.soundEnabled = window.localStorage.getItem(SOUND_STORAGE_KEY) === "true";
  } catch (error) {
    console.warn("Unable to read dashboard sound preference.", error);
    state.soundEnabled = false;
  }

  updateSoundUi();

  if (state.soundEnabled) {
    armAudioUnlock();
  }
}

function setSoundEnabled(enabled) {
  state.soundEnabled = Boolean(enabled);

  try {
    window.localStorage.setItem(SOUND_STORAGE_KEY, String(state.soundEnabled));
  } catch (error) {
    console.warn("Unable to persist dashboard sound preference.", error);
  }

  if (state.soundEnabled) {
    armAudioUnlock();
  }

  updateSoundUi();
}

function updateSoundUi() {
  elements.soundToggle.textContent = state.soundEnabled ? "Alert sound on" : "Alert sound off";
  elements.soundToggle.setAttribute("aria-pressed", String(state.soundEnabled));
  elements.soundToggle.classList.toggle("is-on", state.soundEnabled);
}

function armAudioUnlock() {
  if (audioUnlockBound || !state.soundEnabled) {
    return;
  }

  const unlock = () => {
    ensureAudioContext().catch((error) => {
      console.warn("Dashboard alert sound is still blocked by the browser.", error);
    });
  };

  ["pointerdown", "keydown", "touchstart"].forEach((eventName) => {
    window.addEventListener(eventName, unlock, { once: true, passive: true });
  });

  audioUnlockBound = true;
}

async function ensureAudioContext() {
  if (!state.soundEnabled) {
    return null;
  }

  const AudioContextCtor = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextCtor) {
    return null;
  }

  if (!audioContext) {
    audioContext = new AudioContextCtor();
  }

  if (audioContext.state === "suspended") {
    await audioContext.resume();
  }

  return audioContext;
}

async function playToastCue(tone) {
  if (!state.soundEnabled) {
    return;
  }

  const context = await ensureAudioContext();
  if (!context) {
    return;
  }

  const profilesByTone = {
    low: { fundamental: 392.0, accent: 493.88, glow: 587.33 },
    mid: { fundamental: 440.0, accent: 554.37, glow: 659.25 },
    high: { fundamental: 493.88, accent: 622.25, glow: 739.99 },
  };
  const profile = profilesByTone[tone.key] || profilesByTone.low;
  const warmOscillator = context.createOscillator();
  const glowOscillator = context.createOscillator();
  const filterNode = context.createBiquadFilter();
  const gainNode = context.createGain();
  const startTime = context.currentTime;

  filterNode.type = "lowpass";
  filterNode.frequency.setValueAtTime(1800, startTime);
  filterNode.Q.setValueAtTime(0.75, startTime);

  warmOscillator.type = "triangle";
  warmOscillator.frequency.setValueAtTime(profile.fundamental, startTime);
  warmOscillator.frequency.linearRampToValueAtTime(profile.accent, startTime + 0.12);

  glowOscillator.type = "sine";
  glowOscillator.frequency.setValueAtTime(profile.glow, startTime);
  glowOscillator.detune.setValueAtTime(6, startTime);

  gainNode.gain.setValueAtTime(0.0001, startTime);
  gainNode.gain.exponentialRampToValueAtTime(0.03, startTime + 0.02);
  gainNode.gain.exponentialRampToValueAtTime(0.015, startTime + 0.16);
  gainNode.gain.exponentialRampToValueAtTime(0.0001, startTime + 0.34);

  warmOscillator.connect(filterNode);
  glowOscillator.connect(filterNode);
  filterNode.connect(gainNode);
  gainNode.connect(context.destination);

  warmOscillator.start(startTime);
  glowOscillator.start(startTime);
  warmOscillator.stop(startTime + 0.36);
  glowOscillator.stop(startTime + 0.36);
}

function render() {
  elements.magnitudeValue.textContent = `${state.minMagnitude.toFixed(1)}+`;

  const filteredEvents = getFilteredEvents();
  const stats = computeStats(filteredEvents);

  renderHero(stats);
  renderStats(stats);
  renderActivityChart(filteredEvents);
  renderMagnitudeChart(filteredEvents);
  renderZoneChart(filteredEvents);
  renderScatterChart(filteredEvents);
  renderStrongestList(filteredEvents);
  renderRecentTable(filteredEvents);
  renderMap(filteredEvents);
}

function fetchJson(url, options = {}) {
  const requestUrl = options.bypassCache ? withCacheBust(url) : url;

  return fetch(requestUrl, {
    cache: options.bypassCache ? "no-store" : "default",
  }).then((response) => {
    if (!response.ok) {
      throw new Error(`Unable to fetch ${url}: ${response.status}`);
    }

    return response.json();
  });
}

function normalizeEvent(event) {
  const magnitude = toNumber(event.magnitude);
  const depth = toNumber(event.depth_km);
  const significance = toNumber(event.significance);
  const feltReports = toNumber(event.felt_reports);
  const latitude = toNumber(event.latitude);
  const longitude = toNumber(event.longitude);
  const utcDate = event.time_utc ? new Date(event.time_utc) : null;
  const etDate = event.time_et ? new Date(event.time_et) : null;
  const zone = getZoneLabel(event);

  return {
    ...event,
    magnitude,
    depth,
    significance,
    feltReports,
    latitude,
    longitude,
    utcDate,
    etDate,
    zone,
  };
}

function getFilteredEvents() {
  const now = dashboardMeta?.generated_at_utc
    ? new Date(dashboardMeta.generated_at_utc)
    : new Date();
  const cutoff = new Date(now.getTime() - state.windowHours * 60 * 60 * 1000);

  return allEvents.filter((event) => {
    if (!event.utcDate || Number.isNaN(event.utcDate.getTime())) {
      return false;
    }
    if (event.utcDate < cutoff) {
      return false;
    }
    if (event.magnitude < state.minMagnitude) {
      return false;
    }
    if (state.status !== "all" && event.status !== state.status) {
      return false;
    }
    if (state.zone !== "all" && event.zone !== state.zone) {
      return false;
    }
    return true;
  });
}

function computeStats(events) {
  const strongest = [...events].sort(sortByMagnitude)[0] || null;
  const countries = new Set(events.map((event) => event.country).filter(Boolean));
  const reviewed = events.filter((event) => event.status === "reviewed").length;
  const automatic = events.filter((event) => event.status === "automatic").length;
  const avgDepth = events.length
    ? roundTo(events.reduce((sum, event) => sum + event.depth, 0) / events.length, 1)
    : 0;
  const avgMagnitude = events.length
    ? roundTo(events.reduce((sum, event) => sum + event.magnitude, 0) / events.length, 2)
    : 0;
  const recent24Cutoff = new Date(
    (dashboardMeta?.generated_at_utc ? new Date(dashboardMeta.generated_at_utc) : new Date()).getTime() -
      24 * 60 * 60 * 1000
  );
  const last24Hours = events.filter((event) => event.utcDate >= recent24Cutoff).length;
  const feltEvents = events.filter((event) => event.feltReports > 0).length;
  const shallowShare = events.length
    ? Math.round((events.filter((event) => event.depth < 70).length / events.length) * 100)
    : 0;

  return {
    totalEvents: events.length,
    strongest,
    countriesCount: countries.size,
    reviewed,
    automatic,
    avgDepth,
    avgMagnitude,
    last24Hours,
    feltEvents,
    shallowShare,
  };
}

function renderHero(stats) {
  const coverageStart = dashboardMeta?.earliest_event_time_et
    ? formatDateLabel(new Date(dashboardMeta.earliest_event_time_et))
    : "Unknown";
  const coverageEnd = dashboardMeta?.latest_event_time_et
    ? formatDateLabel(new Date(dashboardMeta.latest_event_time_et))
    : "Unknown";
  const generatedAt = dashboardMeta?.generated_at_utc
    ? formatDateTimeLabel(new Date(dashboardMeta.generated_at_utc), "ET")
    : "Unknown";

  elements.syncStamp.textContent = generatedAt;
  elements.coverageWindow.textContent = `${coverageStart} to ${coverageEnd}`;
  elements.scopeLabel.textContent = getScopeLabel(dashboardMeta?.source_map_url);
  elements.heroEventCount.textContent = formatNumber(stats.totalEvents);
  elements.heroStrongest.textContent = stats.strongest
    ? `M ${stats.strongest.magnitude.toFixed(1)} in ${stats.strongest.country || stats.strongest.zone}`
    : "No events in filter";
  elements.heroLatest.textContent = dashboardMeta?.latest_event_time_et
    ? formatDateTimeLabel(new Date(dashboardMeta.latest_event_time_et), "ET")
    : "Unknown";
}

function renderStats(stats) {
  const strongestPlace = stats.strongest ? stats.strongest.place : "No event in current filter";

  const cards = [
    {
      label: "Total events",
      value: formatNumber(stats.totalEvents),
      detail: `${formatNumber(stats.last24Hours)} in the last 24 hours`,
    },
    {
      label: "Strongest magnitude",
      value: stats.strongest ? `M ${stats.strongest.magnitude.toFixed(1)}` : "--",
      detail: strongestPlace,
    },
    {
      label: "Average magnitude",
      value: stats.avgMagnitude.toFixed(2),
      detail: "Public-facing cleaned magnitude field",
    },
    {
      label: "Average depth",
      value: `${stats.avgDepth.toFixed(1)} km`,
      detail: `${stats.shallowShare}% of filtered events are shallow`,
    },
    {
      label: "Reviewed events",
      value: formatNumber(stats.reviewed),
      detail: `${formatNumber(stats.automatic)} automatic records in filter`,
    },
    {
      label: "Geographies seen",
      value: formatNumber(stats.countriesCount),
      detail: `${formatNumber(stats.feltEvents)} events with felt reports`,
    },
  ];

  elements.statsGrid.innerHTML = cards
    .map(
      (card) => `
        <article class="stat-card">
          <span class="stat-label">${card.label}</span>
          <strong class="stat-value">${card.value}</strong>
          <p class="stat-detail">${card.detail}</p>
        </article>
      `
    )
    .join("");
}

function renderActivityChart(events) {
  const svg = elements.activityChart;
  clearSvg(svg);

  if (!events.length) {
    renderEmptySvg(svg, "No events for the selected filter window.");
    return;
  }

  const bucketConfig =
    state.windowHours <= 24
      ? { type: "hour", step: 2, label: "2-hour rhythm (ET)" }
      : state.windowHours <= 72
        ? { type: "hour", step: 6, label: "6-hour rhythm (ET)" }
        : { type: "day", step: 1, label: "Daily rhythm (ET)" };

  const buckets = bucketEvents(events, bucketConfig);
  elements.activityTitle.textContent =
    bucketConfig.type === "day" ? "Activity through the selected window" : "Short-window seismic rhythm";
  elements.activityNote.textContent = bucketConfig.label;

  const width = 720;
  const height = 320;
  const margin = { top: 18, right: 22, bottom: 44, left: 42 };
  const innerWidth = width - margin.left - margin.right;
  const innerHeight = height - margin.top - margin.bottom;
  const maxValue = Math.max(...buckets.map((bucket) => bucket.count), 1);

  const points = buckets.map((bucket, index) => {
    const x =
      buckets.length === 1
        ? margin.left + innerWidth / 2
        : margin.left + (index / (buckets.length - 1)) * innerWidth;
    const y = margin.top + innerHeight - (bucket.count / maxValue) * innerHeight;
    return { ...bucket, x, y };
  });

  for (let step = 0; step <= 4; step += 1) {
    const y = margin.top + (step / 4) * innerHeight;
    svg.appendChild(
      svgEl("line", {
        x1: margin.left,
        y1: y,
        x2: width - margin.right,
        y2: y,
        class: "chart-gridline",
      })
    );
  }

  const linePath = points
    .map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`)
    .join(" ");
  const areaPath = `${linePath} L ${points.at(-1).x} ${height - margin.bottom} L ${points[0].x} ${height - margin.bottom} Z`;

  svg.appendChild(svgEl("path", { d: areaPath, class: "line-fill" }));
  svg.appendChild(svgEl("path", { d: linePath, class: "line-stroke" }));

  points.forEach((point, index) => {
    const circle = svgEl("circle", {
      cx: point.x,
      cy: point.y,
      r: 4.8,
      class: "line-point",
    });
    attachTooltip(circle, `<strong>${point.label}</strong>${point.count} earthquakes`);
    svg.appendChild(circle);

    const showLabel =
      buckets.length <= 7 ||
      index === 0 ||
      index === buckets.length - 1 ||
      index % Math.max(1, Math.floor(buckets.length / 4)) === 0;

    if (showLabel) {
      svg.appendChild(
        svgEl(
          "text",
          {
            x: point.x,
            y: height - 18,
            "text-anchor": "middle",
            class: "axis-tick",
          },
          truncateLabel(point.shortLabel, 14)
        )
      );
    }
  });

  svg.appendChild(svgEl("text", { x: margin.left, y: 14, class: "axis-label" }, "Event count"));
}

function renderMagnitudeChart(events) {
  const svg = elements.magnitudeChart;
  clearSvg(svg);

  if (!events.length) {
    renderEmptySvg(svg, "No events for the selected filter window.");
    return;
  }

  const width = 720;
  const height = 320;
  const margin = { top: 26, right: 18, bottom: 46, left: 26 };
  const innerWidth = width - margin.left - margin.right;
  const innerHeight = height - margin.top - margin.bottom;
  const gap = 18;
  const barWidth = (innerWidth - gap * (magnitudeBands.length - 1)) / magnitudeBands.length;
  const counts = magnitudeBands.map((band) => ({
    ...band,
    count: events.filter((event) => event.magnitude >= band.min && event.magnitude < band.max).length,
  }));
  const maxCount = Math.max(...counts.map((band) => band.count), 1);

  const defs = svgEl("defs");
  const gradient = svgEl("linearGradient", {
    id: "warmBars",
    x1: "0%",
    y1: "0%",
    x2: "0%",
    y2: "100%",
  });
  gradient.appendChild(svgEl("stop", { offset: "0%", "stop-color": "#f5bb7c" }));
  gradient.appendChild(svgEl("stop", { offset: "100%", "stop-color": "#d85f2d" }));
  defs.appendChild(gradient);
  svg.appendChild(defs);

  counts.forEach((band, index) => {
    const x = margin.left + index * (barWidth + gap);
    const barHeight = (band.count / maxCount) * innerHeight;
    const y = margin.top + innerHeight - barHeight;

    const rect = svgEl("rect", {
      x,
      y,
      width: barWidth,
      height: barHeight,
      rx: 14,
      class: "bar-shape",
    });
    attachTooltip(rect, `<strong>${band.label}</strong>${band.count} earthquakes`);
    svg.appendChild(rect);
    svg.appendChild(
      svgEl("text", { x: x + barWidth / 2, y: y - 8, "text-anchor": "middle", class: "bar-value" }, `${band.count}`)
    );
    svg.appendChild(
      svgEl("text", { x: x + barWidth / 2, y: height - 18, "text-anchor": "middle", class: "bar-label" }, band.label)
    );
  });
}

function renderZoneChart(events) {
  const svg = elements.zoneChart;
  clearSvg(svg);

  if (!events.length) {
    renderEmptySvg(svg, "No events for the selected filter window.");
    return;
  }

  const width = 720;
  const height = 360;
  const margin = { top: 16, right: 32, bottom: 22, left: 170 };
  const innerWidth = width - margin.left - margin.right;
  const rowHeight = 34;

  const zoneData = groupCounts(events, (event) => event.zone)
    .slice(0, 8)
    .sort((left, right) => left.count - right.count);
  const maxCount = Math.max(...zoneData.map((entry) => entry.count), 1);

  const defs = svgEl("defs");
  const gradient = svgEl("linearGradient", {
    id: "coolBars",
    x1: "0%",
    y1: "0%",
    x2: "100%",
    y2: "0%",
  });
  gradient.appendChild(svgEl("stop", { offset: "0%", "stop-color": "#8fc6d6" }));
  gradient.appendChild(svgEl("stop", { offset: "100%", "stop-color": "#256c8f" }));
  defs.appendChild(gradient);
  svg.appendChild(defs);

  zoneData.forEach((entry, index) => {
    const y = margin.top + index * rowHeight;
    const barWidth = (entry.count / maxCount) * innerWidth;
    const rect = svgEl("rect", {
      x: margin.left,
      y,
      width: barWidth,
      height: 20,
      rx: 10,
      class: "zone-bar",
    });
    attachTooltip(rect, `<strong>${entry.label}</strong>${entry.count} earthquakes`);
    svg.appendChild(rect);
    svg.appendChild(
      svgEl("text", { x: margin.left - 10, y: y + 14, "text-anchor": "end", class: "zone-label" }, truncateLabel(entry.label, 22))
    );
    svg.appendChild(svgEl("text", { x: margin.left + barWidth + 10, y: y + 14, class: "bar-value" }, `${entry.count}`));
  });
}

function renderScatterChart(events) {
  const svg = elements.scatterChart;
  clearSvg(svg);

  if (!events.length) {
    renderEmptySvg(svg, "No events for the selected filter window.");
    return;
  }

  const width = 720;
  const height = 360;
  const margin = { top: 24, right: 24, bottom: 48, left: 48 };
  const innerWidth = width - margin.left - margin.right;
  const innerHeight = height - margin.top - margin.bottom;
  const maxDepth = Math.max(...events.map((event) => event.depth), 1);
  const maxMagnitude = Math.max(...events.map((event) => event.magnitude), 1);

  for (let step = 0; step <= 4; step += 1) {
    const y = margin.top + (step / 4) * innerHeight;
    svg.appendChild(
      svgEl("line", {
        x1: margin.left,
        y1: y,
        x2: width - margin.right,
        y2: y,
        class: "chart-gridline",
      })
    );
  }

  svg.appendChild(svgEl("line", { x1: margin.left, y1: height - margin.bottom, x2: width - margin.right, y2: height - margin.bottom, class: "chart-axis" }));
  svg.appendChild(svgEl("line", { x1: margin.left, y1: margin.top, x2: margin.left, y2: height - margin.bottom, class: "chart-axis" }));

  const sample = events.length > 450 ? sampleEvery(events, Math.ceil(events.length / 450)) : events;
  sample.forEach((event) => {
    const x = margin.left + (event.magnitude / maxMagnitude) * innerWidth;
    const y = margin.top + (event.depth / maxDepth) * innerHeight;
    const point = svgEl("circle", {
      cx: x,
      cy: y,
      r: 3 + Math.min(event.magnitude, 5) * 0.8,
      class: "scatter-point",
    });
    attachTooltip(point, `<strong>${event.title}</strong>${event.depth.toFixed(1)} km deep<br>${event.time_et || event.time_utc}`);
    svg.appendChild(point);
  });

  svg.appendChild(svgEl("text", { x: width / 2, y: height - 12, "text-anchor": "middle", class: "axis-label" }, "Magnitude"));
  svg.appendChild(
    svgEl("text", { x: 18, y: height / 2, transform: `rotate(-90 18 ${height / 2})`, "text-anchor": "middle", class: "axis-label" }, "Depth (km)")
  );
}

function renderStrongestList(events) {
  const strongest = [...events]
    .sort(sortByMagnitude)
    .slice(0, 6)
    .map(
      (event) => `
        <article class="event-strip">
          <div class="event-strip-header">
            <span class="event-strip-mag">M ${event.magnitude.toFixed(1)}</span>
            <span>${event.significance || 0} significance</span>
          </div>
          <p class="event-strip-place">${event.place}</p>
          <p class="event-strip-meta">
            ${event.country || event.zone} | ${event.depth.toFixed(1)} km deep | ${formatDateTimeLabel(event.etDate || event.utcDate, "ET")}
          </p>
        </article>
      `
    )
    .join("");

  elements.strongestList.innerHTML =
    strongest || '<div class="is-empty">No events for the current filter.</div>';
}

function renderRecentTable(events) {
  const rows = [...events]
    .sort((left, right) => right.utcDate - left.utcDate)
    .slice(0, 14)
    .map(
      (event) => `
        <tr>
          <td>${formatDateTimeLabel(event.etDate || event.utcDate, "ET")}</td>
          <td><span class="magnitude-badge">M ${event.magnitude.toFixed(1)}</span></td>
          <td><a href="${event.detail_url}" target="_blank" rel="noreferrer">${escapeHtml(event.place)}</a></td>
          <td>${escapeHtml(event.country || event.zone)}</td>
          <td>${event.depth.toFixed(1)} km</td>
          <td>${escapeHtml(event.status || "unknown")}</td>
        </tr>
      `
    )
    .join("");

  elements.recentTableBody.innerHTML =
    rows || '<tr><td colspan="6">No events for the current filter.</td></tr>';
}

function renderMap(events) {
  if (!map) {
    map = L.map("map", {
      scrollWheelZoom: false,
      zoomControl: true,
      renderer: L.canvas(),
    });

    L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", {
      attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
      maxZoom: 18,
    }).addTo(map);

    mapLayer = L.layerGroup().addTo(map);
  }

  mapLayer.clearLayers();

  if (!events.length) {
    map.setView([30, -100], 3);
    return;
  }

  const bounds = [];
  events.forEach((event) => {
    if (!Number.isFinite(event.latitude) || !Number.isFinite(event.longitude)) {
      return;
    }

    const marker = L.circleMarker([event.latitude, event.longitude], {
      radius: 3 + Math.min(Math.max(event.magnitude, 0), 5) * 1.8,
      weight: 1,
      color: "#ffffff",
      fillOpacity: 0.78,
      fillColor: magnitudeToColor(event.magnitude),
      opacity: 0.8,
    });
    marker.bindTooltip(
      `<strong>${escapeHtml(event.title)}</strong><br>${escapeHtml(event.country || event.zone)}<br>${event.depth.toFixed(1)} km deep`,
      { direction: "top", sticky: true }
    );
    marker.addTo(mapLayer);
    bounds.push([event.latitude, event.longitude]);
  });

  if (bounds.length) {
    map.fitBounds(bounds, { padding: [22, 22] });
  } else {
    map.setView([30, -100], 3);
  }
}

function populateZoneFilter(events) {
  const zones = [...new Set(events.map((event) => event.zone).filter(Boolean))].sort();
  const selectedZone = state.zone;

  elements.zoneFilter.innerHTML = '<option value="all">All zones</option>';
  zones.forEach((zone) => {
    const option = document.createElement("option");
    option.value = zone;
    option.textContent = zone;
    elements.zoneFilter.appendChild(option);
  });

  if (selectedZone !== "all" && zones.includes(selectedZone)) {
    elements.zoneFilter.value = selectedZone;
  } else {
    state.zone = "all";
    elements.zoneFilter.value = "all";
  }
}

function startAutoRefresh() {
  if (refreshTimerId) {
    clearInterval(refreshTimerId);
  }

  refreshTimerId = window.setInterval(() => {
    refreshPublishedFeed().catch((error) => {
      console.error("Background dashboard refresh failed.", error);
    });
  }, REFRESH_POLL_INTERVAL_MS);
}

async function refreshPublishedFeed() {
  const [dataPayload, metaPayload] = await Promise.all([
    fetchJson(DATA_URL, { bypassCache: true }),
    fetchJson(META_URL, { bypassCache: true }),
  ]);

  const nextEvents = (dataPayload.events || []).map(normalizeEvent);
  const nextEventIds = new Set(nextEvents.map((event) => event.id));
  const newEvents = nextEvents
    .filter((event) => event.id && !knownEventIds.has(event.id))
    .sort((left, right) => left.utcDate - right.utcDate);

  allEvents = nextEvents;
  dashboardMeta = metaPayload;
  knownEventIds = nextEventIds;
  populateZoneFilter(allEvents);
  render();

  if (newEvents.length) {
    queueToasts(newEvents);
  }
}

function bucketEvents(events, config) {
  const sorted = [...events].sort((left, right) => left.etDate - right.etDate);
  const startDate = sorted[0]?.etDate;
  const endDate = sorted.at(-1)?.etDate;
  const buckets = [];

  if (!startDate || !endDate) {
    return buckets;
  }

  const cursor = new Date(startDate);
  resetDate(cursor, config.type);

  while (cursor <= endDate) {
    const next = new Date(cursor);
    if (config.type === "hour") {
      next.setHours(next.getHours() + config.step, 0, 0, 0);
    } else {
      next.setDate(next.getDate() + config.step);
      next.setHours(0, 0, 0, 0);
    }

    const count = events.filter((event) => event.etDate >= cursor && event.etDate < next).length;
    const label =
      config.type === "hour"
        ? cursor.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric" })
        : cursor.toLocaleDateString("en-US", { month: "short", day: "numeric" });
    const shortLabel =
      config.type === "hour"
        ? cursor.toLocaleString("en-US", { hour: "numeric" })
        : cursor.toLocaleDateString("en-US", { month: "short", day: "numeric" });

    buckets.push({
      start: new Date(cursor),
      end: new Date(next),
      count,
      label,
      shortLabel,
    });

    cursor.setTime(next.getTime());
  }

  return buckets;
}

function groupCounts(items, getLabel) {
  const counts = new Map();
  items.forEach((item) => {
    const label = getLabel(item) || "Unspecified";
    counts.set(label, (counts.get(label) || 0) + 1);
  });

  return [...counts.entries()]
    .map(([label, count]) => ({ label, count }))
    .sort((left, right) => right.count - left.count);
}

function getZoneLabel(event) {
  if (!event.place) {
    return event.country || "Unspecified";
  }

  const parts = event.place.split(",");
  const rawZone = parts.length > 1 ? parts.at(-1).trim() : event.country || "Unspecified";
  return zoneAliases[rawZone] || rawZone;
}

function getScopeLabel(mapUrl) {
  if (!mapUrl) {
    return "Published feed";
  }

  return /(^|[?&])extent=/.test(mapUrl) ? "Configured map window" : "Global feed";
}

function resetDate(date, type) {
  if (type === "hour") {
    date.setMinutes(0, 0, 0);
    return;
  }

  date.setHours(0, 0, 0, 0);
}

function renderEmptySvg(svg, message) {
  svg.appendChild(svgEl("text", { x: 360, y: 170, "text-anchor": "middle", class: "empty-state" }, message));
}

function clearSvg(svg) {
  while (svg.firstChild) {
    svg.removeChild(svg.firstChild);
  }
}

function attachTooltip(target, html) {
  const tooltip = elements.chartTooltip;

  const show = (event) => {
    tooltip.innerHTML = html;
    tooltip.hidden = false;
    positionTooltip(event);
  };
  const move = (event) => {
    if (!tooltip.hidden) {
      positionTooltip(event);
    }
  };
  const hide = () => {
    tooltip.hidden = true;
  };

  target.addEventListener("mouseenter", show);
  target.addEventListener("mousemove", move);
  target.addEventListener("mouseleave", hide);
}

function queueToasts(events) {
  events.forEach((event) => {
    toastQueue.push(event);
  });

  if (!toastTimerId) {
    showNextToast();
  }
}

function showNextToast() {
  if (!toastQueue.length) {
    toastTimerId = null;
    return;
  }

  const event = toastQueue.shift();
  const tone = getToastTone(event.magnitude);
  const toast = document.createElement("article");
  toast.className = `toast toast-${tone.key}`;
  toast.innerHTML = `
    <span class="toast-kicker">${tone.label}</span>
    <strong class="toast-title">New earthquake: M ${event.magnitude.toFixed(1)}</strong>
    <span class="toast-copy">${escapeHtml(event.place)}<br>${escapeHtml(event.country || event.zone)} | ${event.depth.toFixed(1)} km deep</span>
  `;
  elements.toastStack.appendChild(toast);
  playToastCue(tone).catch((error) => {
    console.warn("Unable to play dashboard alert sound.", error);
  });

  toastTimerId = window.setTimeout(() => {
    toast.remove();
    toastTimerId = null;
    showNextToast();
  }, TOAST_LIFETIME_MS);
}

function positionTooltip(event) {
  elements.chartTooltip.style.left = `${event.clientX + 16}px`;
  elements.chartTooltip.style.top = `${event.clientY + 16}px`;
}

function svgEl(tagName, attributes, textContent) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tagName);
  Object.entries(attributes || {}).forEach(([name, value]) => node.setAttribute(name, value));
  if (textContent !== undefined) {
    node.textContent = textContent;
  }
  return node;
}

function magnitudeToColor(magnitude) {
  if (magnitude >= 4) {
    return "#c73f26";
  }
  if (magnitude >= 2) {
    return "#f08b3d";
  }
  return "#57b6c5";
}

function getToastTone(magnitude) {
  if (magnitude >= 4) {
    return { key: "high", label: "Higher magnitude" };
  }
  if (magnitude >= 2) {
    return { key: "mid", label: "Moderate activity" };
  }
  return { key: "low", label: "Micro event" };
}

function formatDateLabel(date) {
  return date.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: DISPLAY_TIME_ZONE,
  });
}

function formatDateTimeLabel(date, suffix) {
  if (!date || Number.isNaN(date.getTime())) {
    return "Unknown";
  }

  return `${date.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZone: DISPLAY_TIME_ZONE,
  })} ${suffix}`;
}

function formatNumber(value) {
  return new Intl.NumberFormat("en-US").format(value || 0);
}

function roundTo(value, digits) {
  return Number(value.toFixed(digits));
}

function truncateLabel(label, limit) {
  return label.length > limit ? `${label.slice(0, limit - 1)}...` : label;
}

function toNumber(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function sortByMagnitude(left, right) {
  if (right.magnitude !== left.magnitude) {
    return right.magnitude - left.magnitude;
  }
  return (right.significance || 0) - (left.significance || 0);
}

function sampleEvery(items, step) {
  return items.filter((_, index) => index % step === 0);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function withCacheBust(url) {
  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}t=${Date.now()}`;
}
