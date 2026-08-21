defmodule Cinder.Renderers.SelectAll do
  @moduledoc false

  use Phoenix.Component
  use Cinder.Messages

  alias Cinder.Selection

  attr :data, :any, required: true
  attr :id_field, :atom, required: true
  attr :loading, :boolean, required: true
  attr :myself, :any, required: true
  attr :selectable, :any, required: true
  attr :selected_ids, :any, required: true
  attr :theme, :map, required: true
  attr :show_label, :boolean, default: true

  def render(assigns) do
    state =
      Selection.page_state(
        assigns.selected_ids,
        assigns.data,
        assigns.id_field,
        assigns.selectable
      )

    page_ids = Selection.page_ids(assigns.data, assigns.id_field, assigns.selectable)

    assigns =
      assigns
      |> assign(:disabled, assigns.loading or MapSet.size(page_ids) == 0)
      |> assign(:label, dgettext("cinder", "Select all visible items"))
      |> assign(:state, state)

    ~H"""
    <label class="inline-flex items-center gap-2">
      <span class="relative inline-flex items-center justify-center">
        <input
          type="checkbox"
          aria-checked={if @state == :some, do: "mixed", else: to_string(@state == :all)}
          aria-label={@label}
          checked={@state == :all}
          class={@theme.selection_checkbox_class}
          data-indeterminate={@state == :some}
          data-key="selection_checkbox_class"
          data-selection-state={@state}
          disabled={@disabled}
          phx-click="toggle_select_all_page"
          phx-target={@myself}
        />
        <span
          :if={@state == :some}
          aria-hidden="true"
          style="position: absolute; z-index: 1; width: 0.5rem; height: 0.125rem; border-radius: 9999px; background: currentColor; pointer-events: none;"
        >
        </span>
      </span>
      <span :if={@show_label}>{@label}</span>
    </label>
    """
  end
end
