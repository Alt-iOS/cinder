# SPDX-FileCopyrightText: 2025 Cinder contributors <https://github.com/sevenseacat/cinder/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Cinder.Renderers.Table do
  @moduledoc """
  Renderer for table layout.

  This module contains the render function and helper components for
  displaying data in a traditional HTML table format.
  """

  use Phoenix.Component
  use Cinder.Messages

  import Cinder.Renderers.Helpers

  alias Cinder.Renderers.BulkActions
  alias Cinder.Renderers.Pagination
  alias Cinder.Renderers.SortIcon
  alias Cinder.Selection

  @doc """
  Renders the table layout.
  """
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:show_item_numbers, fn -> false end)
      |> assign_new(:current_page, fn -> 1 end)

    ~H"""
    <div class={[@theme.container_class, "relative"]} data-key="container_class" data-loading={@show_loading_state}>
      <!-- Filter Controls (including search) -->
      <div :if={@show_filters} class={@theme.controls_class} data-key="controls_class">
        <Cinder.FilterManager.render_filter_controls
          table_id={@id}
          columns={Map.get(assigns, :query_columns, @columns)}
          filters={@filters}
          theme={@theme}
          target={@myself}
          filters_label={@filters_label}
          filter_mode={@show_filters}
          search_term={@search_term}
          show_search={@search_enabled}
          search_label={@search_label}
          search_placeholder={@search_placeholder}
          raw_filter_params={Map.get(assigns, :raw_filter_params, %{})}
          controls_slot={Map.get(assigns, :controls_slot, [])}
        />
      </div>

      <!-- Bulk Actions -->
      <BulkActions.render
        selectable={@selectable}
        selected_ids={@selected_ids}
        bulk_action_slots={@bulk_action_slots}
        theme={@theme}
        myself={@myself}
      />

      <!-- Main table -->
      <div class={@theme.table_wrapper_class} data-key="table_wrapper_class">
        <table class={@theme.table_class} data-key="table_class">
          <thead class={@theme.thead_class} data-key="thead_class">
            <tr class={@theme.header_row_class} data-key="header_row_class">
              <th :if={@show_item_numbers} class={[@theme.th_class, "w-10"]} data-item-number-heading>#</th>
              <th :if={Selection.enabled?(@selectable)} class={[@theme.th_class, "w-10"]} data-key="th_class">
    <Cinder.Renderers.SelectAll.render :if={Map.get(assigns, :select_all, :page) == :page} show_label={false} data={@data} id_field={@id_field} loading={@show_loading_state} label={Map.get(assigns, :select_all_label)} myself={@myself} selectable={@selectable} selected_ids={@selected_ids} theme={@theme} />
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
          <tbody id={"#{@id}-items"} class={[@theme.tbody_class, (@show_loading_state && "opacity-75" || "")]} data-key="tbody_class">
            <tr :for={{item, index} <- Enum.with_index(@data)} :if={not @error}
                class={selection_classes(@theme.row_class, Map.get(assigns, :item_class), @row_click, @selectable, @selected_ids, item, @id_field, Map.get(@theme, :selected_row_class))}
                data-item-id={to_string(Map.get(item, @id_field))}
                data-key="row_class"
                phx-click={selection_click_action(@row_click, @selectable, @selected_ids, item, @id_field, @myself)}>
              <td :if={@show_item_numbers} class={[@theme.td_class, "tabular-nums"]} data-item-number>{row_number(index, @current_page, @page)}</td>
              <td :if={Selection.enabled?(@selectable)} class={[@theme.td_class, "w-10"]} data-key="td_class">
                <input
                  type="checkbox"
                  disabled={not Selection.item_toggleable?(@selectable, @selected_ids, item, @id_field)}
                  checked={Selection.item_selected?(@selected_ids, item, @id_field)}
                  phx-click="toggle_select"
                  phx-value-id={to_string(Map.get(item, @id_field))}
                  phx-target={@myself}
                  class={@theme.selection_checkbox_class}
                  data-key="selection_checkbox_class"
                />
              </td>
              <%!-- An <:item> slot renders the row's cells itself; the columns then only head the table. --%>
              {if item_cells?(assigns), do: render_slot(@item_slot, item)}
              <td
                :for={column <- @columns}
                :if={not item_cells?(assigns)}
                class={[@theme.td_class, column.class]}
                data-key="td_class"
              >
                <%= if column.slot[:inner_block] do %>
                  {render_slot(column.slot, item)}
                <% else %>
                  {column.inner_block.(item)}
                <% end %>
              </td>
            </tr>
            <!-- Error State -->
            <tr :if={@error and not @loading}>
              <td colspan={column_count(@columns, @selectable) + if(@show_item_numbers, do: 1, else: 0)} class={@theme.empty_class} data-key="error_class">
                <%= if has_slot?(assigns, :error_slot) do %>
                  {render_slot(@error_slot)}
                <% else %>
                  <div class={@theme.error_container_class} data-key="error_container_class">
                    <span class={@theme.error_message_class} data-key="error_message_class">{@error_message}</span>
                  </div>
                <% end %>
              </td>
            </tr>
            <!-- Empty State (only when not loading and not error) -->
            <tr :if={@data == [] and not @loading and not @error}>
              <td colspan={column_count(@columns, @selectable)} class={@theme.empty_class} data-key="empty_class">
                <%= if has_slot?(assigns, :empty_slot) do %>
                  {render_slot(@empty_slot, empty_context(assigns))}
                <% else %>
                  {@empty_message}
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Loading indicator -->
      <div :if={@show_loading_state} class={@theme.loading_overlay_class} data-key="loading_overlay_class">
        <%= if has_slot?(assigns, :loading_slot) do %>
          {render_slot(@loading_slot)}
        <% else %>
          <div class={@theme.loading_container_class} data-key="loading_container_class">
            <svg class={@theme.loading_spinner_class} data-key="loading_spinner_class" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle class={@theme.loading_spinner_circle_class} data-key="loading_spinner_circle_class" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class={@theme.loading_spinner_path_class} data-key="loading_spinner_path_class" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            {@loading_message}
          </div>
        <% end %>
      </div>

      <!-- Pagination -->
      <Pagination.render
        loading={@show_loading_state}
        page={@page}
        page_size_config={@page_size_config}
        theme={@theme}
        myself={@myself}
        show_pagination={@show_pagination}
        pagination_mode={@pagination_mode}
        total_count={Map.get(assigns, :total_count)}
        id={@id}
      />
    </div>
    """
  end

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  defp row_number(index, _current, %Ash.Page.Offset{offset: offset}), do: offset + index + 1
  defp row_number(index, current, %{limit: limit}), do: (current - 1) * limit + index + 1
  defp row_number(index, _current, _page), do: index + 1

  defp column_count(columns, selectable) do
    base_count = length(columns)
    if Selection.enabled?(selectable), do: base_count + 1, else: base_count
  end

  # Whether an <:item> slot renders each row's cells in place of one cell per column.
  defp item_cells?(assigns), do: Map.get(assigns, :item_slot, []) != []
end
