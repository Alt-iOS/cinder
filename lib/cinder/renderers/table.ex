defmodule Cinder.Renderers.Table do
  @moduledoc "Renderer for the table layout, including column headers and cells."
  use Phoenix.Component
  import Cinder.Renderers.Helpers
  alias Cinder.Renderers.{Shared, SortIcon, InfiniteStream}
  alias Cinder.Selection

  def render(assigns) do
    assigns = prepare_renderer(assigns, :table)

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
      <Shared.top_sentinel {assigns} />
      <!-- Main table -->
      <div class={@theme.table_wrapper_class} data-key="table_wrapper_class">
        <table class={@theme.table_class} data-key="table_class">
          <thead class={@theme.thead_class} data-key="thead_class">
            <tr class={@theme.header_row_class} data-key="header_row_class">
              <th :if={@show_item_numbers} class={[@theme.th_class, "w-10"]} data-item-number-heading>
                #
              </th>
              <th :if={Selection.enabled?(@selectable)} class={[@theme.th_class, "w-10"]} data-key="th_class">
                <Shared.select_all {assigns} show_label={false} />
              </th>
              <th :for={column <- @columns} class={[@theme.th_class, column.class]} data-key="th_class">
                <div :if={column.sortable}
                     class={["cursor-pointer select-none", (@show_loading_state && "opacity-75" || "")]}
                     phx-click="toggle_sort"
                     phx-value-key={column.field}
                     phx-target={@myself}>
                     {column.label}
                     <span class={@theme.sort_indicator_class} data-key="sort_indicator_class">
                       <SortIcon.sort_icon sort_direction={Cinder.QueryBuilder.get_sort_direction(@sort_by, column.field)} theme={@theme} loading={@show_loading_state} />
                     </span>
                </div>
                <div :if={not column.sortable}>
                  {column.label}
                </div>
              </th>
            </tr>
          </thead>
          <tbody
            id={"#{@id}-items"}
            class={[@theme.tbody_class, (@show_loading_state && "opacity-75" || "")]}
            data-key="tbody_class"
            phx-update={if @pagination_mode == :infinite, do: "stream"}
          >
            <tr
                :for={{dom_id, payload} <- @stream_items} :if={@pagination_mode == :infinite}
                id={dom_id}
                class={selection_classes(@theme.row_class, Map.get(assigns, :item_class), @row_click, if(@selection_locked, do: false, else: @selectable), @render_selected_ids, payload.record, @id_field, Map.get(@theme, :selected_row_class))}
                data-item-id={payload.id}
                data-item-number={payload.number}
                data-key="row_class"
                phx-click={selection_click_action(@row_click, if(@selection_locked, do: false, else: @selectable), @render_selected_ids, payload.record, @id_field, @myself)}>
              <td :if={@show_item_numbers} class={[@theme.td_class, "w-10"]} data-item-number>
                {payload.number}
              </td>
              <td :if={Selection.enabled?(@selectable)} class={[@theme.td_class, "w-10"]} data-key="td_class">
                <Shared.checkbox {assigns} item={payload.record} />
              </td>
              <td :for={column <- @columns} class={[@theme.td_class, column.class]} data-key="td_class">
                {render_slot(column.slot, payload.record)}
              </td>
            </tr>
            <tr :for={{item, index} <- Enum.with_index(@data)} :if={@pagination_mode != :infinite and not @error}
                class={selection_classes(@theme.row_class, Map.get(assigns, :item_class), @row_click, if(@selection_locked, do: false, else: @selectable), @render_selected_ids, item, @id_field, Map.get(@theme, :selected_row_class))}
                data-item-id={to_string(Map.get(item, @id_field))}
                data-item-number={item_number(index, @pagination_mode, @current_page, @page)}
                data-key="row_class"
                phx-click={selection_click_action(@row_click, if(@selection_locked, do: false, else: @selectable), @render_selected_ids, item, @id_field, @myself)}>
              <td :if={@show_item_numbers} class={[@theme.td_class, "w-10"]} data-item-number>
                {item_number(index, @pagination_mode, @current_page, @page)}
              </td>
              <td :if={Selection.enabled?(@selectable)} class={[@theme.td_class, "w-10"]} data-key="td_class">
                <Shared.checkbox {assigns} item={item} />
              </td>
              <td :for={column <- @columns} class={[@theme.td_class, column.class]} data-key="td_class">
                {render_slot(column.slot, item)}
              </td>
            </tr>
            <tr id={"#{@id}-error"} :if={@pagination_mode != :infinite and @error and not @loading}>
              <td colspan={column_count(@columns, @selectable, @show_item_numbers)} class={@theme.empty_class} data-key="error_class">
                <Shared.error_content {assigns} />
              </td>
            </tr>
            <tr id={"#{@id}-empty"} :if={@pagination_mode != :infinite and @data == [] and not @loading and not @error}>
              <td colspan={column_count(@columns, @selectable, @show_item_numbers)} class={@theme.empty_class} data-key="empty_class">
                <Shared.empty_content {assigns} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <Shared.footer {assigns} />
    </div>
    """
  end

  defp column_count(columns, selectable, show_item_numbers) do
    base_count = length(columns)
    selection_count = if Selection.enabled?(selectable), do: 1, else: 0
    number_count = if show_item_numbers, do: 1, else: 0
    base_count + selection_count + number_count
  end
end
