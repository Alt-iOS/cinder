defmodule Cinder.Renderers.Shared do
  @moduledoc false
  use Phoenix.Component
  import Cinder.Renderers.Helpers

  alias Cinder.Renderers.{BulkActions, InfiniteStream, Pagination, SelectAll, SortControls}
  alias Cinder.Selection

  # Receives the same prepared assigns as the layout renderer.
  def controls(assigns) do
    ~H"""
      <!-- Controls Area (filters + sort) -->
      <div :if={@show_filters || (@layout != :table && @show_sort && SortControls.has_sortable_columns?(@columns))} class={[@theme.controls_class, @layout != :table && "!flex !flex-col"]} data-key="controls_class">
        <!-- Filter Controls (including search) -->
        <Cinder.FilterManager.render_filter_controls
          :if={@show_filters}
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

        <!-- Sort Controls (button group since no table headers) -->
        <SortControls.render
          :if={@layout != :table and @show_sort}
          columns={@columns}
          sort_by={@sort_by}
          sort_label={@sort_label}
          theme={@theme}
          myself={@myself}
          loading={@show_loading_state}
        />
      </div>

      <!-- Bulk Actions -->
      <BulkActions.render
        selectable={@selectable}
        selected_ids={@selected_ids}
        selection_mode={Map.get(assigns, :selection_mode, :explicit)}
        total_count={Map.get(assigns, :total_count) || (@page && Map.get(@page, :count))}
        bulk_action_slots={@bulk_action_slots}
        bulk_action_confirmation_slot={Map.get(assigns, :bulk_action_confirmation_slot, [])}
        bulk_action_confirmation={Map.get(assigns, :bulk_action_confirmation)}
        theme={@theme}
        myself={@myself}
      />

    """
  end

  def footer(assigns) do
    ~H"""
      <div :if={@pagination_mode == :infinite and @error and @infinite_loaded_count == 0 and not @loading} class={@theme.empty_class} data-key="error_class">
        <.error_content {assigns} />
      </div>

      <div :if={@pagination_mode == :infinite and @infinite_loaded_count == 0 and not @loading and not @error and @has_item_slot} class={@theme.empty_class} data-key="empty_class">
        <.empty_content {assigns} />
      </div>

      <!-- Loading indicator -->
      <div :if={@show_loading_state and (@pagination_mode != :infinite or @infinite_loaded_count == 0)} class={@theme.loading_overlay_class} data-key="loading_overlay_class">
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
        page={@page}
        page_size_config={@page_size_config}
        theme={@theme}
        myself={@myself}
        show_pagination={@show_pagination}
        pagination_mode={@pagination_mode}
        total_count={@total_count}
        count_mode={@count_mode}
        current_page={@current_page}
        loaded_count={if(@pagination_mode == :infinite, do: @infinite_loaded_count, else: length(@data))}
        range_start={@infinite_range_start}
        range_end={@infinite_range_end}
        has_previous={@infinite_has_previous}
        has_next={@infinite_has_next}
        loading={@loading}
        error={@error}
        infinite_load={Map.get(assigns, :infinite_load, :automatic)}
        overscan={Map.get(assigns, :overscan, 1)}
        load_more_label={Map.get(assigns, :load_more_label)}
        id={@id}
      />
    """
  end

  def select_all(assigns) do
    assigns = assign_new(assigns, :show_label, fn -> true end)

    ~H"""
    <SelectAll.render
      :if={Map.get(assigns, :select_all, :query) != false}
      data={@data}
      id_field={@id_field}
      loading={@loading or (Map.get(assigns, :select_all, :query) == :query and Map.get(assigns, :selection_loading, false))}
      label={Map.get(assigns, :select_all_label)}
      mode={Map.get(assigns, :select_all, :query)}
      myself={@myself}
      page_ids={if @pagination_mode == :infinite, do: @infinite_selectable_ids}
      pending={Map.get(assigns, :select_all, :query) == :query and Map.get(assigns, :selection_loading, false)}
      scope_ids={if Map.get(assigns, :select_all, :query) == :query, do: Map.get(assigns, :selection_scope_ids)}
      selectable={@selectable}
      selected_ids={@selected_ids}
      selection_mode={Map.get(assigns, :selection_mode, :explicit)}
      show_label={@show_label}
      theme={@theme}
    />
    """
  end

  def top_sentinel(assigns) do
    ~H"""
      <InfiniteStream.top_sentinel
        id={@id}
        myself={@myself}
        theme={@theme}
        show={@pagination_mode == :infinite and @infinite_has_previous and not @loading and not @error}
      />
    """
  end

  def checkbox(assigns) do
    toggleable? =
      Selection.item_toggleable?(
        assigns.selectable,
        assigns.render_selected_ids,
        assigns.item,
        assigns.id_field
      )

    assigns = assign(assigns, :toggleable?, toggleable?)

    ~H"""
    <input
      type="checkbox"
      disabled={@selection_locked or not @toggleable?}
      checked={Selection.item_selected?(@render_selected_ids, @item, @id_field)}
      phx-click="toggle_select"
      phx-value-id={to_string(Map.get(@item, @id_field))}
      phx-target={@myself}
      class={@theme.selection_checkbox_class}
      data-cinder-selection-checkbox={@pagination_mode == :infinite}
      data-cinder-selection-disabled={@pagination_mode == :infinite and not @toggleable?}
      data-key="selection_checkbox_class"
    />
    """
  end

  def error_content(assigns) do
    ~H"""
    <%= if has_slot?(assigns, :error_slot) do %>
      {render_slot(@error_slot)}
    <% else %>
      <div class={@theme.error_container_class} data-key="error_container_class">
        <span class={@theme.error_message_class} data-key="error_message_class">{@error_message}</span>
      </div>
    <% end %>
    """
  end

  def empty_content(assigns) do
    ~H"""
    <%= if has_slot?(assigns, :empty_slot) do %>
      {render_slot(@empty_slot, empty_context(assigns))}
    <% else %>
      {@empty_message}
    <% end %>
    """
  end
end
