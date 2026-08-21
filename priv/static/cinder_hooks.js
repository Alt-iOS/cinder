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

export const hooks = { CinderInfiniteStream };
