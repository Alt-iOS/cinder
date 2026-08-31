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
    selection_mode = Map.get(assigns, :selection_mode, :explicit)
    slots = Map.get(assigns, :bulk_action_slots, [])

    selected_count =
      case {selection_mode, Map.get(assigns, :total_count)} do
        {:all_matching, count} when is_integer(count) -> max(count - MapSet.size(selected_ids), 0)
        {:all_matching, _unknown} -> nil
        _explicit -> MapSet.size(selected_ids)
      end

    assigns =
      assigns
      |> assign(:selected_ids, selected_ids)
      |> assign(:selection_mode, selection_mode)
      |> assign(
        :selection_active,
        selection_mode == :all_matching or MapSet.size(selected_ids) > 0
      )
      |> assign(:selected_count, selected_count)
      |> assign(:slots, slots)

    ~H"""
    <div class={@theme.bulk_actions_container_class} data-key="bulk_actions_container_class">
      <%= for {slot, index} <- Enum.with_index(@slots) do %>
        <span
          phx-click={wrapper_click(slot, index, @myself)}
          data-confirm={confirmation_message(slot, @selected_count)}
          class="contents"
        >
          <%= if has_label?(slot) do %>
            <.themed_button
              theme={@theme}
              label={slot[:label]}
              variant={slot[:variant] || :primary}
              selected_count={@selected_count}
              selection_active={@selection_active}
            />
          <% else %>
            {render_slot([slot], action_context(assigns, slot, index))}
          <% end %>
        </span>
      <% end %>
    </div>
    <%= if Map.get(assigns, :bulk_action_confirmation_slot, []) != [] do %>
      {render_slot(@bulk_action_confirmation_slot, confirmation_context(assigns))}
    <% end %>
    """
  end

  defp themed_button(assigns) do
    disabled = not assigns.selection_active
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

  defp wrapper_click(%{confirmation: :slot} = slot, index, target) do
    if has_label?(slot), do: action_click(slot, index, target)
  end

  defp wrapper_click(slot, index, target), do: action_click(slot, index, target)

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

  defp action_context(assigns, slot, index) do
    %{
      selected_ids: assigns.selected_ids,
      selected_count: assigns.selected_count,
      selection_mode: assigns.selection_mode,
      prepare:
        if(slot[:confirmation] == :slot,
          do: action_click(slot, index, assigns.myself)
        )
    }
  end

  defp confirmation_context(assigns) do
    confirmation = Map.get(assigns, :bulk_action_confirmation)

    index = confirmation && confirmation.index
    selected_ids = Map.get(confirmation || %{}, :selected_ids, assigns.selected_ids)
    selection_mode = Map.get(confirmation || %{}, :selection_mode, assigns.selection_mode)

    selected_count =
      Map.get_lazy(confirmation || %{}, :selected_count, fn ->
        if selection_mode == :explicit,
          do: MapSet.size(selected_ids),
          else: assigns.selected_count
      end)

    slot = index && Enum.at(assigns.slots, index)
    prepared? = confirmation && Map.has_key?(confirmation, :data)

    %{
      active?: not is_nil(confirmation),
      ready?: !!prepared?,
      selected_ids: selected_ids,
      selected_count: selected_count,
      selection_mode: selection_mode,
      action: slot && slot[:action],
      data: confirmation && Map.get(confirmation, :data),
      error: confirmation && Map.get(confirmation, :error),
      confirm: JS.push("bulk_action_confirm", target: assigns.myself),
      cancel: JS.push("bulk_action_cancel", target: assigns.myself)
    }
  end

  defp variant_class(theme, :primary), do: theme.button_primary_class
  defp variant_class(theme, :secondary), do: theme.button_secondary_class
  defp variant_class(theme, :danger), do: theme.button_danger_class
  defp variant_class(_theme, _), do: nil

  defp interpolate_text(message, count) do
    String.replace(message, "{count}", if(is_integer(count), do: to_string(count), else: "all"))
  end
end
