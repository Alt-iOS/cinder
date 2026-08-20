defmodule Cinder.Renderers.BulkActions do
  @moduledoc """
  Shared bulk actions component used by Table, List, and Grid renderers.

  Supports themed buttons via `label`/`variant` attributes, or custom rendering
  via inner content. See the [Advanced Features guide](advanced.md#selection--bulk-actions)
  for comprehensive documentation.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @doc """
  Renders bulk action buttons when selectable is enabled and slots are provided.

  ## Required assigns
  - `selectable` - Boolean indicating if selection is enabled
  - `selected_ids` - MapSet of selected record IDs
  - `bulk_action_slots` - List of bulk_action slot definitions
  - `theme` - Theme configuration map
  - `myself` - LiveComponent reference for event targeting
  """
  def render(assigns) do
    selectable = Map.get(assigns, :selectable, false)
    slots = Map.get(assigns, :bulk_action_slots, [])

    if Cinder.Selection.enabled?(selectable) and slots != [] do
      render_bulk_actions(assigns)
    else
      ~H""
    end
  end

  defp render_bulk_actions(assigns) do
    selected_ids = Map.get(assigns, :selected_ids, MapSet.new())
    slots = Map.get(assigns, :bulk_action_slots, [])

    assigns =
      assigns
      |> assign(:selected_ids, selected_ids)
      |> assign(:selected_count, MapSet.size(selected_ids))
      |> assign(:slots, slots)

    ~H"""
    <div class={@theme.bulk_actions_container_class} data-key="bulk_actions_container_class">
      <%= for {slot, index} <- Enum.with_index(@slots) do %>
        <span
          phx-click={action_click(slot, index, @myself)}
          data-confirm={confirmation_message(slot, @selected_count)}
          class="contents"
        >
          <%= if has_label?(slot) do %>
            <.themed_button
              theme={@theme}
              label={slot[:label]}
              variant={slot[:variant] || :primary}
              selected_count={@selected_count}
            />
          <% else %>
            {render_slot([slot], %{selected_ids: @selected_ids, selected_count: @selected_count})}
          <% end %>
        </span>
      <% end %>
    </div>
    <%= if confirmation_slot_open?(assigns) do %>
      {render_slot(@bulk_action_confirmation_slot, confirmation_context(assigns))}
    <% end %>
    """
  end

  defp themed_button(assigns) do
    disabled = assigns.selected_count == 0
    label = interpolate_text(assigns.label, assigns.selected_count)

    button_class =
      [
        assigns.theme.button_class,
        variant_class(assigns.theme, assigns.variant),
        disabled && assigns.theme.button_disabled_class
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:disabled, disabled)
      |> assign(:label, label)
      |> assign(:button_class, button_class)

    ~H"""
    <button type="button" class={@button_class} disabled={@disabled}>
      {@label}
    </button>
    """
  end

  defp has_label?(slot), do: Map.has_key?(slot, :label) and slot[:label] != nil

  defp action_click(%{confirmation: :slot}, index, target) do
    JS.push("bulk_action_prepare", value: %{index: index}, target: target)
  end

  defp action_click(_slot, index, target) do
    JS.push("bulk_action_execute", value: %{index: index}, target: target)
  end

  defp confirmation_message(%{confirm: confirm}, count) when is_binary(confirm) do
    interpolate_text(confirm, count)
  end

  defp confirmation_message(_slot, _count), do: nil

  defp confirmation_slot_open?(assigns) do
    is_integer(Map.get(assigns, :pending_bulk_action)) and
      Map.get(assigns, :bulk_action_confirmation_slot, []) != []
  end

  defp confirmation_context(assigns) do
    index = assigns.pending_bulk_action
    slot = Enum.at(assigns.slots, index)

    %{
      selected_ids: assigns.selected_ids,
      selected_count: assigns.selected_count,
      action: slot[:action],
      data: Map.get(assigns, :bulk_action_confirmation_data),
      error: Map.get(assigns, :bulk_action_confirmation_error),
      confirm: JS.push("bulk_action_execute", value: %{index: index}, target: assigns.myself),
      cancel: JS.push("bulk_action_cancel", target: assigns.myself)
    }
  end

  defp variant_class(theme, :primary), do: theme.button_primary_class
  defp variant_class(theme, :secondary), do: theme.button_secondary_class
  defp variant_class(theme, :danger), do: theme.button_danger_class
  defp variant_class(_theme, _), do: nil

  defp interpolate_text(message, count) do
    String.replace(message, "{count}", to_string(count))
  end
end
