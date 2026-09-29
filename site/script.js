// Otto landing page: small progressive enhancements. The page works fully without this file.
(function () {
  "use strict";

  var root = document.documentElement;
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* Header: tuck the notch in slightly once the page scrolls. */
  var ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(function () {
      root.classList.toggle("is-scrolled", window.scrollY > 24);
      ticking = false;
    });
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* Reveal sections as they scroll into view. */
  var revealables = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window) || reduceMotion.matches) {
    revealables.forEach(function (el) { el.classList.add("is-visible"); });
  } else {
    var revealObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          revealObserver.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    revealables.forEach(function (el) { revealObserver.observe(el); });
  }

  /* Launch week: at the instant in data-ends-at, each buy button takes its regular label and link
     together, and each data-launch-only line hides. Checked once now and once by a single timeout for
     that instant; no countdown. A page without [data-ends-at] does nothing here. */
  function endLaunch(el) {
    if (el.hasAttribute("data-launch-only")) {
      el.hidden = true;
      return;
    }
    var href = el.getAttribute("data-href-regular");
    var label = el.getAttribute("data-label-regular");
    if (href) el.setAttribute("href", href);
    if (label) (el.querySelector(".btn__label") || el).textContent = label;
  }

  var launchGroups = {};
  Array.prototype.forEach.call(document.querySelectorAll("[data-ends-at]"), function (el) {
    var endsAt = Date.parse(el.getAttribute("data-ends-at"));
    if (isNaN(endsAt)) return;
    (launchGroups[endsAt] = launchGroups[endsAt] || []).push(el);
  });
  Object.keys(launchGroups).forEach(function (key) {
    var els = launchGroups[key];
    var wait = Number(key) - Date.now();
    var finish = function () { els.forEach(endLaunch); };
    if (wait <= 0) {
      finish();
    } else if (wait <= 2147483647) {
      // Longer waits would overflow setTimeout's 32-bit delay; a launch week never needs one.
      window.setTimeout(finish, wait);
    }
  });

  /* Promo video. The page ships it with native controls, preload="none" and no autoplay, so nothing
     downloads until the frame is on screen. Here the native controls give way to the pause/play
     button, and the loop starts the first time the frame scrolls into view, unless the visitor asked
     for less motion or less data (Save-Data or prefers-reduced-data), in which case it waits for the
     button. It pauses while off screen. */
  var video = document.getElementById("promo");
  var toggle = document.getElementById("promo-toggle");
  var toggleLabel = document.getElementById("promo-toggle-label");
  if (!video || !toggle) return;

  var reduceData = window.matchMedia("(prefers-reduced-data: reduce)");
  var connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  var saveData = !!(connection && connection.saveData) || reduceData.matches;

  // Held until the visitor presses play: no autoplay for reduced motion or reduced data.
  var userPaused = reduceMotion.matches || saveData;

  video.removeAttribute("controls");
  toggle.hidden = false;

  function syncToggle() {
    var paused = video.paused;
    toggle.setAttribute("aria-pressed", paused ? "true" : "false");
    toggleLabel.textContent = paused ? "Play video" : "Pause video";
  }

  function tryPlay() {
    var p = video.play();
    if (p && typeof p.catch === "function") p.catch(function () { syncToggle(); });
  }

  // If the video can't load, fall back to the poster (drawn as the frame's background) and hide
  // controls. The browser tries each <source> in turn and only the last one's error means none played.
  var sources = video.querySelectorAll("source");
  (sources.length ? sources[sources.length - 1] : video).addEventListener("error", function () {
    root.classList.add("no-video");
  });

  toggle.addEventListener("click", function () {
    if (video.paused) {
      userPaused = false;
      tryPlay();
    } else {
      userPaused = true;
      video.pause();
    }
  });
  video.addEventListener("play", syncToggle);
  video.addEventListener("pause", syncToggle);
  syncToggle();

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          if (!userPaused) tryPlay();
        } else if (!video.paused) {
          video.pause();
        }
      });
    }, { threshold: 0.15 }).observe(video);
  } else if (!userPaused) {
    tryPlay();
  }

  reduceMotion.addEventListener && reduceMotion.addEventListener("change", function (e) {
    if (e.matches) { userPaused = true; video.pause(); }
  });
})();
