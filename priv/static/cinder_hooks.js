const CinderInfiniteStream = {
  mounted() {
    this.appliedSelectionState = null;
    this.syncSelection();
  },

  beforeUpdate() {
    const scroller = this.scrollContainer(this.el);
    const viewport = this.viewportBounds(scroller);

    this.viewportAnchors = Array.from(this.el.querySelectorAll("[data-item-id]"))
      .map((item) => {
        const bounds = item.getBoundingClientRect();

        return {
          id: item.dataset.itemId,
          offset: bounds.top - viewport.top,
          visible: bounds.bottom > viewport.top && bounds.top < viewport.bottom,
        };
      })
      .filter(({ visible }) => visible);
    this.viewportScroller = scroller;
  },

  updated() {
    this.syncSelection();
    cancelAnimationFrame(this.viewportAnchorFrame);
    this.viewportAnchorFrame = requestAnimationFrame(() => this.restoreViewportAnchor());
  },

  destroyed() {
    cancelAnimationFrame(this.viewportAnchorFrame);
  },

  syncSelection() {
    const signature = `${this.el.dataset.selectedIds || "[]"}\n${this.el.dataset.selectedClasses || "[]"}`;
    if (signature === this.appliedSelectionState) return;

    this.appliedSelectionState = signature;
    const selected = new Set(JSON.parse(this.el.dataset.selectedIds || "[]"));
    const selectedClasses = JSON.parse(this.el.dataset.selectedClasses || "[]");

    this.el.querySelectorAll("[data-item-id]").forEach((item) => {
      const isSelected = selected.has(item.dataset.itemId);
      const checkbox = item.querySelector("[data-cinder-selection-checkbox]");
      if (checkbox) checkbox.checked = isSelected;
      selectedClasses.forEach((name) => item.classList.toggle(name, isSelected));
    });
  },

  restoreViewportAnchor() {
    const anchors = this.viewportAnchors;
    const scroller = this.viewportScroller;
    this.viewportAnchors = null;
    this.viewportScroller = null;

    if (!anchors?.length || !scroller?.isConnected) return;

    const itemsById = new Map(
      Array.from(this.el.querySelectorAll("[data-item-id]"), (item) => [item.dataset.itemId, item]),
    );
    const anchor = anchors
      .map((position) => ({ position, item: itemsById.get(position.id) }))
      .find(({ item }) => item);

    if (!anchor) return;

    const viewport = this.viewportBounds(scroller);
    const currentOffset = anchor.item.getBoundingClientRect().top - viewport.top;
    const adjustment = currentOffset - anchor.position.offset;

    if (Math.abs(adjustment) > 0.5) scroller.scrollTop += adjustment;
  },

  scrollContainer(stream) {
    for (let element = stream; element; element = element.parentElement) {
      const { overflowY } = window.getComputedStyle(element);

      if (/(auto|scroll|overlay)/.test(overflowY) && element.scrollHeight > element.clientHeight) {
        return element;
      }
    }

    return document.scrollingElement;
  },

  viewportBounds(scroller) {
    if (scroller === document.scrollingElement) {
      return { top: 0, bottom: window.innerHeight };
    }

    const bounds = scroller.getBoundingClientRect();
    return { top: bounds.top, bottom: bounds.bottom };
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

  reconnected() {
    if (!this.triggered) this.observeAheadOfViewport();
  },

  observeAheadOfViewport() {
    if (this.triggered) return;

    this.observer?.disconnect();

    // Start the request one viewport before the sentinel becomes visible. The
    // prefetched DOM window can then absorb server/network latency without the
    // user reaching the end of the rendered rows first.
    const prefetchDistance = Math.max(window.innerHeight, 400);

    this.observer = new IntersectionObserver(
      async ([entry]) => {
        if (!entry?.isIntersecting || this.triggered) return;

        this.triggered = true;
        this.observer.disconnect();

        try {
          const results = await this.pushEventTo(this.el, "load_more", {});
          const failure = results.find(({ status }) => status === "rejected");

          if (results.length === 0) {
            throw new Error("no LiveView target accepted the load_more push");
          }

          if (failure) throw failure.reason;
        } catch (error) {
          this.triggered = false;
          console.error("Cinder infinite-scroll load_more push failed", error);
        }
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
