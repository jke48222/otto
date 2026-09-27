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

  /* Promo video: honour reduced motion, offer pause/play, and pause while off screen. */
  var video = document.getElementById("promo");
  var toggle = document.getElementById("promo-toggle");
  var toggleLabel = document.getElementById("promo-toggle-label");
  if (!video || !toggle) return;

  var userPaused = false;

  function syncToggle() {
    var paused = video.paused;
    toggle.setAttribute("aria-pressed", paused ? "true" : "false");
    toggleLabel.textContent = paused ? "Play video" : "Pause video";
  }

  function tryPlay() {
    var p = video.play();
    if (p && typeof p.catch === "function") p.catch(function () { syncToggle(); });
  }

  if (reduceMotion.matches) {
    userPaused = true;
    video.removeAttribute("autoplay");
    video.pause();
  }

  // If the video can't load, fall back to the poster (drawn as the frame's background) and hide controls.
  var source = video.querySelector("source");
  (source || video).addEventListener("error", function () {
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
  }

  reduceMotion.addEventListener && reduceMotion.addEventListener("change", function (e) {
    if (e.matches) { userPaused = true; video.pause(); }
  });
})();
