defmodule Cinder.Renderers.Items do
  @moduledoc false
  use Phoenix.Component
  require Logger
  import Cinder.Renderers.Helpers
  alias Cinder.Renderers.{Shared, InfiniteStream}
  alias Cinder.Selection

  # List and grid differ only in the classes supplied by their renderer.
  def render(assigns) do
    has_item_slot = Map.get(assigns, :item_slot, []) != []

    unless has_item_slot do
      Logger.warning(
        "Cinder.#{assigns.layout |> to_string() |> String.capitalize()}: No <:item> slot provided. Items will not be rendered."
      )
    end

    assigns = assign(assigns, :has_item_slot, has_item_slot)

    ~H"""
    <div
      class={[@theme.container_class, "relative"]}
      data-key="container_class"
      data-cinder-infinite-root={@pagination_mode == :infinite}
      data-selection-locked={if @pagination_mode == :infinite, do: @selection_locked}
      data-selected-ids={if @pagination_mode == :infinite, do: InfiniteStream.encode_selected_ids(@render_selected_ids, Map.get(assigns, :infinite_item_ids))}
      data-selected-classes={if @pagination_mode == :infinite, do: InfiniteStream.encode_selected_classes(InfiniteStream.selected_classes(@selected_class))}
      id={if @pagination_mode == :infinite, do: "#{@id}-infinite-stream"}
      phx-hook={if @pagination_mode == :infinite, do: "CinderInfiniteStream"}
    >
      <Shared.controls {assigns} />
      <div :if={Selection.enabled?(@selectable) and Map.get(assigns, :select_all, :query) != false} class="mb-3">
        <Shared.select_all {assigns} />
      </div>
      <Shared.top_sentinel {assigns} />
      <!-- Items Container -->
      <div
        id={"#{@id}-items"}
        class={@items_container_class}
        data-key={@items_container_key}
        phx-update={if @pagination_mode == :infinite, do: "stream"}
      >
        <%= if @has_item_slot do %>
          <div
            :for={{dom_id, payload} <- @stream_items} :if={@pagination_mode == :infinite}
            id={dom_id}
            class={selection_classes(@items_item_class, Map.get(assigns, :item_class), @item_click, if(@selection_locked, do: false, else: Map.get(assigns, :selectable, false)), @render_selected_ids, payload.record, Map.get(assigns, :id_field, :id), Map.get(@theme, :selected_item_class))}
            data-item-id={payload.id}
            data-item-number={payload.number}
            data-key={@items_item_data_key}
            phx-click={selection_click_action(@item_click, if(@selection_locked, do: false, else: Map.get(assigns, :selectable, false)), @render_selected_ids, payload.record, Map.get(assigns, :id_field, :id), @myself)}
          >
            <span :if={@show_item_numbers} class={@theme.pagination_count_class} data-item-number>
              {payload.number}.
            </span>
            <div
              :if={Selection.enabled?(Map.get(assigns, :selectable, false))}
              class={@items_selection_class}
              data-key={@items_selection_key}
            >
              <Shared.checkbox {assigns} item={payload.record} />
            </div>
            {render_slot(@item_slot, payload.record)}
          </div>
          <div
            :for={{item, index} <- Enum.with_index(@data)} :if={@pagination_mode != :infinite and not @error}
            class={selection_classes(@items_item_class, Map.get(assigns, :item_class), @item_click, if(@selection_locked, do: false, else: Map.get(assigns, :selectable, false)), @render_selected_ids, item, Map.get(assigns, :id_field, :id), Map.get(@theme, :selected_item_class))}
            data-item-id={to_string(Map.get(item, @id_field))}
            data-item-number={item_number(index, @pagination_mode, @current_page, @page)}
            data-key={@items_item_data_key}
            phx-click={selection_click_action(@item_click, if(@selection_locked, do: false, else: Map.get(assigns, :selectable, false)), @render_selected_ids, item, Map.get(assigns, :id_field, :id), @myself)}
          >
            <span
              :if={@show_item_numbers}
              class={@theme.pagination_count_class}
              data-item-number
            >
              {item_number(index, @pagination_mode, @current_page, @page)}.
            </span>
            <div
              :if={Selection.enabled?(Map.get(assigns, :selectable, false))}
              class={@items_selection_class}
              data-key={@items_selection_key}
            >
              <Shared.checkbox {assigns} item={item} />
            </div>
            {render_slot(@item_slot, item)}
          </div>
        <% else %>
          <!-- No item slot provided - render message -->
          <div :if={not @loading} class={@theme.empty_class} data-key="empty_class">
            No item template provided. Add an &lt;:item&gt; slot to render items.
          </div>
        <% end %>

        <div id={"#{@id}-error"} :if={@pagination_mode != :infinite and @error and not @loading} class={@items_state_class} data-key="error_class">
          <Shared.error_content {assigns} />
        </div>

        <div id={"#{@id}-empty"} :if={@pagination_mode != :infinite and @data == [] and not @loading and not @error and @has_item_slot} class={@items_state_class} data-key="empty_class">
          <Shared.empty_content {assigns} />
        </div>
      </div>

      <Shared.footer {assigns} />
    </div>
    """
  end
end
