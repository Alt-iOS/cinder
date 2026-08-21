const CinderInfiniteStream = {
  mounted() {
    this.selectionObserver = new MutationObserver(() => this.syncSelection());
    this.selectionObserver.observe(this.el, {
      attributes: true,
      attributeFilter: ["data-selected-ids", "data-selected-classes"],
    });
    this.syncSelection();
  },

  updated() {
    this.syncSelection();
  },

  destroyed() {
    this.selectionObserver?.disconnect();
  },

  syncSelection() {
    const state = this.el;
    const root = state.closest("[data-cinder-infinite-root]");
    if (!root) return;

    const selected = new Set(JSON.parse(state.dataset.selectedIds || "[]"));
    const selectedClasses = JSON.parse(state.dataset.selectedClasses || "[]");

    root.querySelectorAll("[data-item-id]").forEach((item) => {
      const isSelected = selected.has(item.dataset.itemId);
      const checkbox = item.querySelector("[data-cinder-selection-checkbox]");
      if (checkbox) checkbox.checked = isSelected;
      selectedClasses.forEach((name) => item.classList.toggle(name, isSelected));
    });
  },
};

const CinderInfiniteSentinel = {
  mounted() {
    this.triggered = false;
    this.observeAheadOfViewport();

    this.handleResize = () => this.observeAheadOfViewport();
    window.addEventListener("resize", this.handleResize, { passive: true });
  },

  destroyed() {
    this.observer?.disconnect();
    window.removeEventListener("resize", this.handleResize);
  },

  observeAheadOfViewport() {
    if (this.triggered) return;

    this.observer?.disconnect();

    // Start the request one viewport before the sentinel becomes visible. The
    // prefetched DOM window can then absorb server/network latency without the
    // user reaching the end of the rendered rows first.
    const prefetchDistance = Math.max(window.innerHeight, 400);

    this.observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry?.isIntersecting || this.triggered) return;

        this.triggered = true;
        this.observer.disconnect();
        this.pushEventTo(this.el, "load_more", {});
      },
      {
        root: null,
        rootMargin: `0px 0px ${prefetchDistance}px 0px`,
        threshold: 0,
      },
    );

    this.observer.observe(this.el);
  },
};

export const hooks = { CinderInfiniteSentinel, CinderInfiniteStream };
