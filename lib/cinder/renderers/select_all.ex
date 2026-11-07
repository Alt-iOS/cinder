# SPDX-FileCopyrightText: 2026 Cinder contributors <https://github.com/sevenseacat/cinder/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Cinder.Renderers.SelectAll do
  @moduledoc false

  use Phoenix.Component
  use Cinder.Messages

  alias Cinder.Selection

  attr :data, :any, required: true
  attr :id_field, :atom, required: true
  attr :loading, :boolean, required: true
  attr :label, :string, default: nil
  attr :myself, :any, required: true
  attr :selectable, :any, required: true
  attr :selected_ids, :any, required: true
  attr :theme, :map, required: true
  attr :show_label, :boolean, default: true

  def render(assigns) do
    selection_ids =
      assigns.data
      |> Enum.filter(&Selection.item_selectable?(assigns.selectable, &1))
      |> Enum.map(&to_string(Map.get(&1, assigns.id_field)))
      |> MapSet.new()

    assigns =
      assigns
      |> assign(:disabled, assigns.loading or MapSet.size(selection_ids) == 0)
      |> assign(:label, assigns.label || dgettext("cinder", "Select all visible items"))
      |> assign(:state, explicit_selection_state(assigns.selected_ids, selection_ids))

    ~H"""
    <label class={@theme.select_all_container_class} data-key="select_all_container_class">
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
          phx-disable-with=""
          phx-target={@myself}
        />
        <span
          :if={@state == :some}
          aria-hidden="true"
          class={@theme.selection_indeterminate_class}
          data-key="selection_indeterminate_class"
        >
        </span>
      </span>
      <span :if={@show_label}>{@label}</span>
    </label>
    """
  end

  defp explicit_selection_state(selected_ids, selection_ids) do
    cond do
      MapSet.size(selection_ids) == 0 -> :none
      MapSet.subset?(selection_ids, selected_ids) -> :all
      MapSet.disjoint?(selection_ids, selected_ids) -> :none
      true -> :some
    end
  end
end
