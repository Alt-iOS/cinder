defmodule Cinder.LiveComponent do
  @moduledoc """
  Shared LiveComponent for all Cinder data layouts (Table, List, etc.).

  This component handles all data management logic:
  - State management (filters, sorting, pagination)
  - Event handling (filter_change, toggle_sort, goto_page, etc.)
  - Async data loading, with an optional synchronous first load
  - URL state synchronization

  The actual HTML rendering is delegated to a renderer module passed via
  the `renderer` assign. Each renderer implements a `render/1` function
  that receives the assigns and returns HEEx.
  """

  use Phoenix.LiveComponent
  require Logger

  use Cinder.Messages

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(%{loading: true} = assigns, socket) do
    # Keep existing data visible while loading
    {:ok, assign(socket, Map.take(assigns, [:loading]))}
  end

  def update(%{refresh: true} = assigns, socket) do
    # Force refresh of data
    silent_refresh? =
      Map.get(assigns, :silent_refresh, false) and refreshable_data_present?(socket)

    socket =
      socket
      |> assign(Map.drop(assigns, [:refresh, :silent_refresh]))
      |> assign_defaults()
      |> assign(:silent_refresh, silent_refresh?)
      |> prepare_refresh()
      |> ensure_infinite_stream()
      |> assign_column_definitions()
      |> load_data()

    {:ok, socket}
  end

  def update(%{__infinite_prefetch__: true}, socket) do
    {:ok, maybe_start_infinite_prefetch(socket)}
  end

  def update(%{__update_item__: {id, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id

    updated_data =
      Enum.map(socket.assigns.data || [], fn item ->
        if Map.get(item, id_field) == id, do: update_fn.(item), else: item
      end)

    {:ok, assign(socket, :data, updated_data)}
  end

  def update(%{__update_items__: {ids, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id
    id_set = MapSet.new(ids)

    updated_data =
      Enum.map(socket.assigns.data || [], fn item ->
        if Map.get(item, id_field) in id_set, do: update_fn.(item), else: item
      end)

    {:ok, assign(socket, :data, updated_data)}
  end

  def update(%{__remove_items__: ids}, socket) when is_list(ids) do
    id_field = socket.assigns[:id_field] || :id
    id_set = MapSet.new(ids, &to_string/1)

    socket =
      if infinite_mode?(socket) do
        remove_infinite_items(socket, id_set)
      else
        updated_data =
          Enum.reject(socket.assigns.data || [], fn item ->
            MapSet.member?(id_set, to_string(Map.get(item, id_field)))
          end)

        assign(socket, :data, updated_data)
      end

    selected_ids = socket.assigns[:selected_ids] || MapSet.new()
    updated_selected_ids = MapSet.difference(selected_ids, id_set)

    updated_selection_scope_ids =
      case socket.assigns[:selection_scope_ids] do
        %MapSet{} = scope_ids -> MapSet.difference(scope_ids, id_set)
        scope_ids -> scope_ids
      end

    socket =
      socket
      |> assign(:selected_ids, updated_selected_ids)
      |> assign(:selection_scope_ids, updated_selection_scope_ids)

    socket =
      if MapSet.equal?(selected_ids, updated_selected_ids) do
        socket
      else
        notify_selection_change(socket, :remove)
      end

    {:ok, socket}
  end

  def update(%{__deselect_items__: ids}, socket) when is_list(ids) do
    id_set = MapSet.new(ids, &to_string/1)
    selected_ids = socket.assigns[:selected_ids] || MapSet.new()
    updated_selected_ids = MapSet.difference(selected_ids, id_set)
    socket = assign(socket, :selected_ids, updated_selected_ids)

    socket =
      if MapSet.equal?(selected_ids, updated_selected_ids) do
        socket
      else
        notify_selection_change(socket, :deselect)
      end

    {:ok, socket}
  end

  # Single item update - raw item passed (has id field)
  def update(%{__update_item_if_visible__: {%{} = raw_item, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id
    id = Map.get(raw_item, id_field)
    do_update_item_if_visible(socket, id, raw_item, update_fn, id_field)
  end

  # Single item update - just ID passed
  def update(%{__update_item_if_visible__: {id, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id
    do_update_item_if_visible(socket, id, nil, update_fn, id_field)
  end

  # Single raw item passed (not in a list)
  def update(%{__update_items_if_visible__: {%{} = item, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id
    items_by_id = %{Map.get(item, id_field) => item}
    do_update_items_if_visible(socket, items_by_id, update_fn, id_field)
  end

  # List of raw items passed
  def update(%{__update_items_if_visible__: {[%{} | _] = items, update_fn}}, socket) do
    id_field = socket.assigns[:id_field] || :id
    items_by_id = Map.new(items, &{Map.get(&1, id_field), &1})
    do_update_items_if_visible(socket, items_by_id, update_fn, id_field)
  end

  # List of IDs passed (use old table data)
  def update(%{__update_items_if_visible__: {ids, update_fn}}, socket) when is_list(ids) do
    id_field = socket.assigns[:id_field] || :id
    do_update_items_if_visible(socket, nil, ids, update_fn, id_field)
  end

  def update(assigns, socket) do
    prev_state = data_state(socket.assigns)
    prev_selection_scope = selection_scope_state(socket.assigns)

    socket =
      socket
      |> assign(assigns)
      |> assign_defaults()
      |> ensure_infinite_stream()
      |> assign_column_definitions()
      |> decode_url_state(assigns)
      |> maybe_invalidate_selection_scope(prev_selection_scope)
      |> load_data_if_needed(prev_state)

    {:ok, socket}
  end

  defp do_update_item_if_visible(socket, id, raw_item, update_fn, id_field) do
    if infinite_mode?(socket) do
      do_update_infinite_item_if_visible(socket, id, raw_item, update_fn, id_field)
    else
      data = socket.assigns.data || []

      case Enum.find(data, &(Map.get(&1, id_field) == id)) do
        nil ->
          {:ok, socket}

        old_item ->
          input = raw_item || old_item
          updated = update_fn.(input)
          updated_data = Enum.map(data, &if(Map.get(&1, id_field) == id, do: updated, else: &1))
          {:ok, assign(socket, :data, updated_data)}
      end
    end
  end

  # When raw items provided as map
  defp do_update_items_if_visible(socket, items_by_id, update_fn, id_field) do
    do_update_items_if_visible(socket, items_by_id, Map.keys(items_by_id), update_fn, id_field)
  end

  defp do_update_items_if_visible(socket, items_by_id, ids, update_fn, id_field) do
    if infinite_mode?(socket) do
      do_update_infinite_items_if_visible(socket, items_by_id, ids, update_fn, id_field)
    else
      data = socket.assigns.data || []
      id_set = MapSet.new(ids)
      visible_ids = data |> Enum.map(&Map.get(&1, id_field)) |> MapSet.new()
      ids_to_update = MapSet.intersection(id_set, visible_ids)

      if MapSet.size(ids_to_update) == 0 do
        {:ok, socket}
      else
        input_items = get_input_items(data, items_by_id, ids_to_update, id_field)
        updated_by_id = update_fn.(input_items) |> to_map_by_id(id_field)

        updated_data =
          Enum.map(data, fn item ->
            id = Map.get(item, id_field)
            Map.get(updated_by_id, id, item)
          end)

        {:ok, assign(socket, :data, updated_data)}
      end
    end
  end

  # Infinite collections intentionally retain only IDs, cursors, numbering and
  # selection metadata on the server. A full incoming record is therefore
  # required for a targeted update; ID-only updates remain a safe no-op.
  defp do_update_infinite_item_if_visible(socket, id, %{} = raw_item, update_fn, id_field) do
    normalized_id = to_string(id)

    if MapSet.member?(socket.assigns.infinite_item_ids, normalized_id) do
      updated = update_fn.(raw_item)
      {:ok, update_infinite_entries(socket, %{normalized_id => updated}, id_field)}
    else
      {:ok, socket}
    end
  end

  defp do_update_infinite_item_if_visible(socket, _id, nil, _update_fn, _id_field),
    do: {:ok, socket}

  defp do_update_infinite_items_if_visible(socket, items_by_id, _ids, update_fn, id_field)
       when is_map(items_by_id) do
    raw_by_id = Map.new(items_by_id, fn {id, item} -> {to_string(id), item} end)

    visible_items =
      socket.assigns.infinite_pages
      |> Enum.flat_map(& &1.items)
      |> Enum.filter(&Map.has_key?(raw_by_id, &1.id))
      |> Enum.map(&Map.fetch!(raw_by_id, &1.id))

    if visible_items == [] do
      {:ok, socket}
    else
      updated_by_id =
        visible_items
        |> update_fn.()
        |> to_map_by_normalized_id(id_field)

      {:ok, update_infinite_entries(socket, updated_by_id, id_field)}
    end
  end

  defp do_update_infinite_items_if_visible(socket, nil, _ids, _update_fn, _id_field),
    do: {:ok, socket}

  defp update_infinite_entries(socket, updated_by_id, id_field) do
    selectable = socket.assigns.selectable

    {pages, entries} =
      Enum.map_reduce(socket.assigns.infinite_pages, [], fn page, entries ->
        {items, entries} =
          Enum.map_reduce(page.items, entries, fn item_meta, entries ->
            case Map.fetch(updated_by_id, item_meta.id) do
              {:ok, updated} ->
                ensure_same_infinite_id!(updated, item_meta.id, id_field)
                selectable? = Cinder.Selection.item_selectable?(selectable, updated)
                item_meta = %{item_meta | selectable?: selectable?}

                entry = %{
                  record: updated,
                  id: item_meta.id,
                  number: item_meta.number,
                  keyset: item_meta.keyset,
                  selectable?: selectable?
                }

                {item_meta, [entry | entries]}

              :error ->
                {item_meta, entries}
            end
          end)

        {refresh_infinite_page_meta(page, items), entries}
      end)

    selectable_ids =
      pages
      |> Enum.flat_map(& &1.selectable_ids)
      |> MapSet.new()

    socket
    |> maybe_stream_items(Enum.reverse(entries), [])
    |> assign(:infinite_pages, pages)
    |> assign(:infinite_selectable_ids, selectable_ids)
  end

  defp remove_infinite_items(socket, id_set) do
    removed_visible_ids = MapSet.intersection(socket.assigns.infinite_item_ids, id_set)

    pages =
      socket.assigns.infinite_pages
      |> Enum.map(fn page ->
        items = Enum.reject(page.items, &MapSet.member?(id_set, &1.id))
        refresh_infinite_page_meta(page, items)
      end)
      |> Enum.reject(&(&1.items == []))

    item_ids = pages |> Enum.flat_map(& &1.ids) |> MapSet.new()

    selectable_ids =
      pages
      |> Enum.flat_map(& &1.selectable_ids)
      |> MapSet.new()

    first_page = List.first(pages)
    last_page = List.last(pages)
    {range_start, range_end} = infinite_range(pages, socket.assigns.page_size)

    socket
    |> maybe_stream_delete_items(removed_visible_ids)
    |> assign(:infinite_pages, pages)
    |> assign(:infinite_item_ids, item_ids)
    |> assign(:infinite_selectable_ids, selectable_ids)
    |> assign(:infinite_loaded_count, MapSet.size(item_ids))
    |> assign(:infinite_range_start, range_start)
    |> assign(:infinite_range_end, range_end)
    |> assign(:first_keyset, first_page && first_page.first_keyset)
    |> assign(:last_keyset, last_page && last_page.last_keyset)
    |> prune_silent_refresh_removed_items(id_set)
  end

  defp prune_silent_refresh_removed_items(
         %{assigns: %{silent_refresh_state: state}} = socket,
         id_set
       )
       when is_map(state) do
    pages =
      state
      |> Map.get(:infinite_pages, [])
      |> Enum.map(fn page ->
        items = Enum.reject(page.items, &MapSet.member?(id_set, &1.id))
        refresh_infinite_page_meta(page, items)
      end)
      |> Enum.reject(&(&1.items == []))

    item_ids = pages |> Enum.flat_map(& &1.ids) |> MapSet.new()
    selectable_ids = pages |> Enum.flat_map(& &1.selectable_ids) |> MapSet.new()
    first_page = List.first(pages)
    last_page = List.last(pages)
    {range_start, range_end} = infinite_range(pages, socket.assigns.page_size)

    state =
      Map.merge(state, %{
        infinite_pages: pages,
        infinite_item_ids: item_ids,
        infinite_selectable_ids: selectable_ids,
        infinite_loaded_count: MapSet.size(item_ids),
        infinite_range_start: range_start,
        infinite_range_end: range_end,
        first_keyset: first_page && first_page.first_keyset,
        last_keyset: last_page && last_page.last_keyset
      })

    assign(socket, :silent_refresh_state, state)
  end

  defp prune_silent_refresh_removed_items(socket, _id_set), do: socket

  defp maybe_stream_delete_items(
         %{private: %{lifecycle: _}, assigns: %{streams: %{items: _}}} = socket,
         ids
       ) do
    Enum.reduce(ids, socket, fn id, socket ->
      stream_delete_by_dom_id(socket, :items, "#{socket.assigns.id}-item-#{id}")
    end)
  end

  defp maybe_stream_delete_items(socket, _ids), do: socket

  defp ensure_same_infinite_id!(item, expected_id, id_field) do
    if to_string(Map.get(item, id_field)) != expected_id do
      raise ArgumentError,
            "an infinite stream update must preserve the #{inspect(id_field)} field"
    end
  end

  # Get input items from raw data if provided, otherwise from table data
  defp get_input_items(_data, items_by_id, ids_to_update, _id_field) when is_map(items_by_id) do
    ids_to_update |> Enum.map(&items_by_id[&1]) |> Enum.filter(& &1)
  end

  defp get_input_items(data, nil, ids_to_update, id_field) do
    Enum.filter(data, &(Map.get(&1, id_field) in ids_to_update))
  end

  # Normalize function return to map
  defp to_map_by_id(items, id_field) when is_list(items) do
    Map.new(items, &{Map.get(&1, id_field), &1})
  end

  defp to_map_by_id(items, _id_field) when is_map(items), do: items

  defp to_map_by_normalized_id(items, id_field) when is_list(items) do
    Map.new(items, &{to_string(Map.get(&1, id_field)), &1})
  end

  defp to_map_by_normalized_id(items, _id_field) when is_map(items) do
    Map.new(items, fn {id, item} -> {to_string(id), item} end)
  end

  @impl true
  def render(assigns) do
    # Delegate rendering to the renderer module
    assigns.renderer.render(assigns)
  end

  # ============================================================================
  # EVENT HANDLERS
  # ============================================================================

  @impl true
  def handle_event("goto_page", %{"page" => page}, socket) do
    with :offset <- socket.assigns.pagination_mode,
         {parsed, ""} when parsed > 0 <- Integer.parse(to_string(page)) do
      socket =
        socket
        |> assign(:current_page, parsed)
        |> notify_state_change()
        |> load_data()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  # Keyset pagination: Navigate to next page
  @impl true
  def handle_event("next_page", _params, socket) do
    if socket.assigns.pagination_mode == :keyset do
      socket =
        socket
        |> assign(:current_page, socket.assigns.current_page + 1)
        |> assign(:after_keyset, socket.assigns.last_keyset)
        |> assign(:before_keyset, nil)
        |> notify_state_change()
        |> load_data()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Keyset pagination: Navigate to previous page
  @impl true
  def handle_event("prev_page", _params, socket) do
    if socket.assigns.pagination_mode == :keyset do
      socket =
        socket
        |> assign(:current_page, max(socket.assigns.current_page - 1, 1))
        |> assign(:before_keyset, socket.assigns.first_keyset)
        |> assign(:after_keyset, nil)
        |> notify_state_change()
        |> load_data()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, maybe_load_infinite(socket, :append)}
  end

  @impl true
  def handle_event("load_previous", _params, socket) do
    {:noreply, maybe_load_infinite(socket, :prepend)}
  end

  @impl true
  def handle_event("retry_load_more", _params, socket) do
    if socket.assigns.pagination_mode == :infinite and socket.assigns.error and
         not socket.assigns.loading do
      {:noreply, socket |> assign(:error, false) |> load_data()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_page_size", %{"page_size" => page_size}, socket) do
    with {parsed, ""} <- Integer.parse(to_string(page_size)),
         validated when validated == parsed <-
           Cinder.PageSize.validate(parsed, socket.assigns.page_size_config) do
      updated_config = %{socket.assigns.page_size_config | selected_page_size: validated}

      socket =
        socket
        |> assign(:page_size, validated)
        |> assign(:page_size_config, updated_config)
        |> assign(:current_page, 1)
        # Clear keyset cursors to restart from beginning when page size changes
        |> assign(:after_keyset, nil)
        |> assign(:before_keyset, nil)
        |> assign(:infinite_append?, false)
        |> mark_infinite_reset()
        |> notify_state_change()
        |> load_data()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_filter", %{"key" => "search"}, socket) do
    socket =
      socket
      |> assign(:search_term, "")
      |> assign(:current_page, 1)
      |> assign(:after_keyset, nil)
      |> assign(:before_keyset, nil)
      |> assign(:infinite_append?, false)
      |> mark_infinite_reset()
      |> load_data()
      |> notify_state_change()

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_filter", %{"key" => key}, socket) do
    new_filters = Cinder.FilterManager.clear_filter(socket.assigns.filters, key)

    # Also clear the autocomplete search term for this field
    raw_filter_params = Map.get(socket.assigns, :raw_filter_params, %{})
    autocomplete_search_key = "#{key}_autocomplete_search"
    raw_filter_params = Map.delete(raw_filter_params, autocomplete_search_key)

    socket =
      socket
      |> assign(:filters, new_filters)
      |> assign(:raw_filter_params, raw_filter_params)
      |> assign(:current_page, 1)
      |> assign(:after_keyset, nil)
      |> assign(:before_keyset, nil)
      |> assign(:infinite_append?, false)
      |> mark_infinite_reset()
      |> load_data()

    socket = notify_state_change(socket, new_filters)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_sort", %{"key" => key}, socket) do
    current_sort = socket.assigns.sort_by

    # Find the column to get its sort cycle configuration
    column = Enum.find(socket.assigns.col, &(&1.field == key))
    sort_cycle = if column, do: column.sort_cycle, else: nil

    new_sort =
      Cinder.QueryBuilder.toggle_sort_with_cycle(
        current_sort,
        key,
        sort_cycle,
        socket.assigns.sort_mode
      )

    # Check if URL sync is enabled
    url_sync_enabled = !!socket.assigns[:on_state_change]

    socket =
      socket
      |> assign(:sort_by, new_sort)
      |> assign(:current_page, 1)
      |> assign(:after_keyset, nil)
      |> assign(:before_keyset, nil)
      |> assign(:infinite_append?, false)
      |> mark_infinite_reset()
      |> assign(:user_has_interacted, true)

    socket =
      if url_sync_enabled do
        assign(socket, :__reload_requested__, true)
      else
        load_data(socket)
      end

    socket = notify_state_change(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      if socket.assigns.pagination_mode == :infinite do
        reset_infinite_pagination(socket)
      else
        socket
      end

    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("clear_all_filters", _params, socket) do
    new_filters = Cinder.FilterManager.clear_all_filters(socket.assigns.filters)

    socket =
      socket
      |> assign(:filters, new_filters)
      |> assign(:current_page, 1)
      |> assign(:after_keyset, nil)
      |> assign(:before_keyset, nil)
      |> assign(:infinite_append?, false)
      |> mark_infinite_reset()
      |> load_data()
      |> notify_state_change()

    {:noreply, socket}
  end

  # ============================================================================
  # SELECTION EVENT HANDLERS
  # ============================================================================

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected_ids = socket.assigns.selected_ids

    new_selected =
      cond do
        MapSet.member?(selected_ids, id) -> MapSet.delete(selected_ids, id)
        id_selectable?(socket, id) -> MapSet.put(selected_ids, id)
        true -> selected_ids
      end

    if MapSet.equal?(new_selected, selected_ids) do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:selected_ids, new_selected)
        |> notify_selection_change(:toggle)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_select_all_page", _params, %{assigns: %{loading: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_select_all_page", _params, socket) do
    id_field = socket.assigns[:id_field] || :id
    selectable = socket.assigns[:selectable] || false

    page_ids =
      if Map.get(socket.assigns, :pagination_mode, :offset) == :infinite do
        Map.get(socket.assigns, :infinite_selectable_ids, MapSet.new())
      else
        Cinder.Selection.page_ids(socket.assigns.data, id_field, selectable)
      end

    all_selected? =
      not Enum.empty?(page_ids) and MapSet.subset?(page_ids, socket.assigns.selected_ids)

    new_selected =
      if all_selected? do
        MapSet.difference(socket.assigns.selected_ids, page_ids)
      else
        MapSet.union(socket.assigns.selected_ids, page_ids)
      end

    socket =
      socket
      |> assign(:selected_ids, new_selected)
      |> notify_selection_change(:select_all)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_select_all", _params, socket)
      when socket.assigns.loading or socket.assigns.selection_loading do
    {:noreply, socket}
  end

  def handle_event("toggle_select_all", _params, socket) do
    scope_ids = socket.assigns.selection_scope_ids

    if is_struct(scope_ids, MapSet) and MapSet.subset?(scope_ids, socket.assigns.selected_ids) do
      socket =
        socket
        |> assign(:selected_ids, MapSet.difference(socket.assigns.selected_ids, scope_ids))
        |> notify_selection_change(:select_all)

      {:noreply, socket}
    else
      attempt = make_ref()
      socket = assign(socket, selection_attempt: attempt, selection_loading: true)
      options = selection_query_options(socket)
      resource = socket.assigns.query
      id_field = socket.assigns.id_field
      selectable = socket.assigns.selectable

      if Application.get_env(:ash, :disable_async?) do
        result = Cinder.Selection.filtered_ids(resource, options, id_field, selectable)
        {:noreply, apply_select_all_result(socket, attempt, result)}
      else
        {:noreply,
         start_async(socket, {:select_all, attempt}, fn ->
           Cinder.Selection.filtered_ids(resource, options, id_field, selectable)
         end)}
      end
    end
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:selection_scope_ids, nil)
      |> assign(:selection_attempt, nil)
      |> assign(:selection_loading, false)
      |> notify_selection_change(:clear)

    {:noreply, socket}
  end

  # ============================================================================
  # BULK ACTION EVENT HANDLERS
  # ============================================================================

  @impl true
  def handle_event("bulk_action_execute", %{"index" => index}, socket) do
    slots = socket.assigns[:bulk_action_slots] || []
    slot = Enum.at(slots, index)

    cond do
      is_nil(slot) ->
        Logger.warning("Cinder: Bulk action slot not found at index #{index}")
        {:noreply, socket}

      slot[:confirmation] == :slot ->
        {:noreply, socket}

      true ->
        selected_ids =
          case socket.assigns[:bulk_action_confirmation] do
            %{index: ^index, selected_ids: selected_ids} -> selected_ids
            _ -> socket.assigns.selected_ids
          end

        execute_bulk_action(slot, selected_ids, socket)
    end
  end

  @impl true
  def handle_event("bulk_action_confirm", _params, socket) do
    slots = socket.assigns[:bulk_action_slots] || []

    case socket.assigns[:bulk_action_confirmation] do
      %{index: index, selected_ids: selected_ids, data: _data} ->
        case Enum.at(slots, index) do
          nil ->
            Logger.warning("Cinder: Bulk action slot not found at index #{index}")
            {:noreply, socket}

          slot ->
            execute_bulk_action(slot, selected_ids, socket)
        end

      _not_ready ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bulk_action_prepare", %{"index" => index}, socket) do
    slots = socket.assigns[:bulk_action_slots] || []

    with slot when not is_nil(slot) <- Enum.at(slots, index),
         false <- preparation_running?(socket.assigns[:bulk_action_confirmation], index),
         selected_ids <- socket.assigns.selected_ids,
         true <- MapSet.size(selected_ids) > 0 do
      attempt = make_ref()

      context = %{
        selected_ids: selected_ids,
        selected_count: MapSet.size(selected_ids),
        action: slot[:action]
      }

      confirmation = %{
        index: index,
        attempt: attempt,
        selected_ids: selected_ids
      }

      socket = assign(socket, :bulk_action_confirmation, confirmation)

      case slot[:prepare_confirmation] do
        nil ->
          {:noreply, put_confirmation_result(socket, index, attempt, {:ok, nil})}

        callback ->
          {:noreply,
           start_async(socket, {:bulk_action_confirmation, index, attempt}, fn ->
             Cinder.BulkActionConfirmation.prepare(callback, context)
           end)}
      end
    else
      nil ->
        Logger.warning("Cinder: Bulk action slot not found at index #{index}")
        {:noreply, socket}

      _ignored ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bulk_action_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk_action_confirmation, nil)}
  end

  @impl true
  def handle_event("filter_change", params, socket) do
    query_columns = Map.get(socket.assigns, :query_columns, socket.assigns.columns)

    raw_filter_params = Map.get(params, "filters", %{})

    new_filters =
      raw_filter_params
      |> Cinder.FilterManager.params_to_filters(query_columns)

    search_term =
      case Map.get(params, "search") do
        nil -> socket.assigns.search_term
        term -> term
      end

    url_sync_enabled = !!socket.assigns[:on_state_change]

    # Only reset pagination when filters or search actually change
    filters_changed = new_filters != socket.assigns.filters
    search_changed = search_term != socket.assigns.search_term

    socket =
      socket
      |> assign(:filters, new_filters)
      |> assign(:raw_filter_params, raw_filter_params)
      |> assign(:search_term, search_term)

    socket =
      if filters_changed or search_changed do
        socket
        |> assign(:current_page, 1)
        |> assign(:after_keyset, nil)
        |> assign(:before_keyset, nil)
        |> assign(:infinite_append?, false)
        |> mark_infinite_reset()
        |> invalidate_selection_scope()
      else
        socket
      end

    socket =
      if url_sync_enabled do
        assign(socket, :__reload_requested__, true)
      else
        load_data(socket)
      end

    socket = notify_state_change(socket, new_filters)

    {:noreply, socket}
  end

  # ============================================================================
  # BULK ACTION HELPERS
  # ============================================================================

  defp execute_bulk_action(slot, selected_ids, socket) do
    action = slot[:action]
    selected_id_list = MapSet.to_list(selected_ids)

    if selected_id_list == [] do
      {:noreply, socket}
    else
      resource = extract_resource(socket.assigns)

      if resource do
        result =
          Cinder.BulkActionExecutor.execute(action,
            resource: resource,
            ids: selected_id_list,
            id_field: socket.assigns[:id_field] || :id,
            actor: socket.assigns[:actor],
            tenant: socket.assigns[:tenant],
            scope: socket.assigns[:scope],
            action_opts: slot[:action_opts] || []
          )

        handle_bulk_action_result(result, slot, selected_ids, socket)
      else
        Logger.error("Cinder: No resource configured for bulk action")
        {:noreply, socket}
      end
    end
  end

  defp handle_bulk_action_result(result, slot, selected_ids, socket) do
    case result do
      {:ok, bulk_result} ->
        handle_bulk_action_success(slot, selected_ids, socket, bulk_result)

      {:error, reason} ->
        handle_bulk_action_error(slot, socket, reason)
    end
  end

  defp handle_bulk_action_success(slot, selected_ids, socket, result) do
    selected_count = MapSet.size(selected_ids)
    remaining_ids = MapSet.difference(socket.assigns.selected_ids, selected_ids)

    socket =
      socket
      |> assign(:bulk_action_confirmation, nil)
      |> assign(:selected_ids, remaining_ids)
      |> invalidate_selection_scope()
      |> notify_selection_change(:clear)
      |> load_data()

    if event_name = slot[:on_success] do
      send(
        self(),
        {event_name,
         %{
           component_id: socket.assigns.id,
           action: slot[:action],
           count: selected_count,
           result: result
         }}
      )
    end

    {:noreply, socket}
  end

  defp handle_bulk_action_error(slot, socket, reason) do
    Logger.error("Cinder: Bulk action failed: #{inspect(reason)}")

    socket = put_confirmation_error(socket, reason)

    if event_name = slot[:on_error] do
      send(
        self(),
        {event_name,
         %{
           component_id: socket.assigns.id,
           action: slot[:action],
           reason: reason
         }}
      )
    end

    {:noreply, socket}
  end

  defp preparation_running?(%{index: index} = confirmation, index) do
    not Map.has_key?(confirmation, :data) and not Map.has_key?(confirmation, :error)
  end

  defp preparation_running?(_confirmation, _index), do: false

  defp put_confirmation_result(socket, index, attempt, result) do
    case socket.assigns[:bulk_action_confirmation] do
      %{index: ^index, attempt: ^attempt} = confirmation ->
        confirmation =
          case result do
            {:ok, data} -> Map.put(confirmation, :data, data)
            {:error, reason} -> Map.put(confirmation, :error, reason)
          end

        assign(socket, :bulk_action_confirmation, confirmation)

      _other ->
        socket
    end
  end

  defp put_confirmation_error(socket, reason) do
    case socket.assigns[:bulk_action_confirmation] do
      %{index: _index} = confirmation ->
        assign(socket, :bulk_action_confirmation, Map.put(confirmation, :error, reason))

      _other ->
        socket
    end
  end

  defp extract_resource(assigns) do
    case assigns[:query] do
      %Ash.Query{resource: resource} -> resource
      resource when is_atom(resource) and not is_nil(resource) -> resource
      _ -> nil
    end
  end

  defp maybe_notify_query_change(socket, nil), do: socket

  defp maybe_notify_query_change(socket, query) do
    if event_name = socket.assigns[:on_query_change] do
      payload = %{query: query, count: page_count(socket.assigns[:page]), id: socket.assigns.id}
      send(self(), {event_name, payload})
    end

    socket
  end

  # The count Ash already returned for the page that was just loaded, so parents
  # can render a total without counting the same filter a second time. nil when
  # the read did not produce one.
  defp page_count(%Ash.Page.Offset{count: count}), do: count
  defp page_count(%Ash.Page.Keyset{count: count}), do: count
  defp page_count(%{results: results}) when is_list(results), do: length(results)
  defp page_count(_page), do: nil

  # The checkbox is only disabled client-side for non-selectable rows, and the
  # client can send arbitrary ids — re-check against the served page data.
  defp id_selectable?(socket, id) do
    selectable = socket.assigns[:selectable] || false
    id_field = socket.assigns[:id_field] || :id

    if Map.get(socket.assigns, :pagination_mode, :offset) == :infinite do
      MapSet.member?(Map.get(socket.assigns, :infinite_selectable_ids, MapSet.new()), id)
    else
      case Enum.find(socket.assigns.data, &(to_string(Map.get(&1, id_field)) == id)) do
        nil -> false
        item -> Cinder.Selection.item_selectable?(selectable, item)
      end
    end
  end

  defp notify_selection_change(socket, action) do
    if event_name = socket.assigns[:on_selection_change] do
      payload = %{
        component_id: socket.assigns.id,
        selected_ids: socket.assigns.selected_ids,
        selected_count: MapSet.size(socket.assigns.selected_ids),
        action: action
      }

      send(self(), {event_name, payload})
    end

    socket
  end

  # ============================================================================
  # ASYNC HANDLERS
  # ============================================================================

  @impl true
  def handle_async(
        {:bulk_action_confirmation, index, attempt},
        {:ok, result},
        socket
      ) do
    {:noreply, put_confirmation_result(socket, index, attempt, result)}
  end

  @impl true
  def handle_async(
        {:bulk_action_confirmation, index, attempt},
        {:exit, reason},
        socket
      ) do
    {:noreply, put_confirmation_result(socket, index, attempt, {:error, reason})}
  end

  def handle_async(:load_data, {:ok, {{:ok, page}, query}}, socket) do
    socket =
      {:ok, page}
      |> handle_result(socket)
      |> maybe_notify_query_change(query)
      |> maybe_start_async_count(query)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:load_data, {:ok, {{:error, error}, _query}}, socket) do
    {:noreply, handle_result({:error, error}, socket)}
  end

  @impl true
  def handle_async(:load_data, {:exit, reason}, socket) do
    {:noreply, handle_result({:exit, reason}, socket)}
  end

  @impl true
  def handle_async({:select_all, attempt}, {:ok, result}, socket) do
    {:noreply, apply_select_all_result(socket, attempt, result)}
  end

  @impl true
  def handle_async({:select_all, attempt}, {:exit, reason}, socket) do
    {:noreply, apply_select_all_result(socket, attempt, {:error, reason})}
  end

  @impl true
  def handle_async({:load_count, attempt}, {:ok, result}, socket) do
    {:noreply, apply_async_count_result(socket, attempt, result)}
  end

  @impl true
  def handle_async({:load_count, attempt}, {:exit, reason}, socket) do
    {:noreply, apply_async_count_result(socket, attempt, {:error, reason})}
  end

  defp handle_result({:ok, page}, socket) do
    socket = maybe_store_sync_count(socket, page)

    socket =
      if socket.assigns.pagination_mode == :infinite do
        put_infinite_page(socket, page)
      else
        socket
        |> assign(:loading, false)
        |> assign(:error, false)
        |> assign(:data, page.results)
        |> assign(:page, page)
        |> assign(:infinite_append?, false)
        |> maybe_update_keyset_cursors(page)
      end

    socket
    |> assign(:silent_refresh, false)
    |> assign(:silent_refresh_state, nil)
  end

  defp handle_result({:error, error}, socket) do
    Logger.error(
      "Cinder query failed for #{inspect(socket.assigns.query)}: #{inspect(error)}",
      %{
        resource: socket.assigns.query,
        filters: socket.assigns.filters,
        sort_by: socket.assigns.sort_by,
        current_page: socket.assigns.current_page,
        error: inspect(error)
      }
    )

    handle_load_error(socket)
  end

  defp handle_result({:exit, reason}, socket) do
    Logger.error(
      "Cinder query crashed for #{inspect(socket.assigns.query)}: #{inspect(reason)}",
      %{
        resource: socket.assigns.query,
        filters: socket.assigns.filters,
        sort_by: socket.assigns.sort_by,
        current_page: socket.assigns.current_page,
        reason: inspect(reason)
      }
    )

    handle_load_error(socket)
  end

  defp handle_load_error(socket) do
    cond do
      socket.assigns.silent_refresh ->
        socket
        |> maybe_restore_silent_refresh_state()
        |> assign(:loading, false)
        |> assign(:silent_refresh, false)
        |> assign(:silent_refresh_state, nil)
        |> assign(:error, false)

      socket.assigns.pagination_mode == :infinite and socket.assigns.infinite_append? and
          socket.assigns.infinite_loaded_count > 0 ->
        socket
        |> assign(:loading, false)
        |> assign(:error, true)

      true ->
        socket
        |> assign(:loading, false)
        |> assign(:error, true)
        |> assign(:data, [])
        |> assign(:page, nil)
        |> assign(:infinite_append?, false)
    end
  end

  defp maybe_restore_silent_refresh_state(%{assigns: %{silent_refresh_state: state}} = socket)
       when is_map(state),
       do: assign(socket, state)

  defp maybe_restore_silent_refresh_state(socket), do: socket

  defp refreshable_data_present?(socket) do
    socket.assigns[:data] not in [nil, []] or
      (socket.assigns[:infinite_loaded_count] || 0) > 0
  end

  defp maybe_update_keyset_cursors(socket, page) do
    if socket.assigns.pagination_mode in [:keyset, :infinite] do
      results = page.results

      socket
      |> assign(:first_keyset, get_keyset_from_result(List.first(results)))
      |> assign(:last_keyset, get_keyset_from_result(List.last(results)))
    else
      socket
    end
  end

  defp get_keyset_from_result(nil), do: nil

  defp get_keyset_from_result(result) do
    case result do
      %{__metadata__: %{keyset: keyset}} -> keyset
      _ -> nil
    end
  end

  defp put_infinite_page(socket, page) do
    direction = socket.assigns.infinite_direction
    page_number = socket.assigns.current_page
    id_field = socket.assigns.id_field
    selectable = socket.assigns.selectable

    existing_ids =
      if direction == :reset, do: MapSet.new(), else: socket.assigns.infinite_item_ids

    number_start = infinite_number_start(socket, direction, length(page.results))

    entries =
      page.results
      |> Enum.with_index(number_start)
      |> Enum.map(fn {item, number} ->
        id = to_string(Map.get(item, id_field))

        %{
          record: item,
          id: id,
          number: number,
          keyset: get_keyset_from_result(item),
          selectable?: Cinder.Selection.item_selectable?(selectable, item)
        }
      end)
      |> Enum.reject(&MapSet.member?(existing_ids, &1.id))

    page_meta = build_infinite_page_meta(page_number, entries)

    stream_entries = if direction == :prepend, do: Enum.reverse(entries), else: entries

    stream_limit =
      if direction == :prepend, do: socket.assigns.window_size, else: -socket.assigns.window_size

    stream_opts =
      [at: if(direction == :prepend, do: 0, else: -1), limit: stream_limit]
      |> Keyword.put(:reset, direction == :reset)

    {pages, window_pruned?} =
      update_infinite_pages(socket.assigns.infinite_pages, page_meta, direction, socket)

    item_ids = pages |> Enum.flat_map(& &1.ids) |> MapSet.new()

    selectable_ids =
      pages
      |> Enum.flat_map(& &1.selectable_ids)
      |> MapSet.new()

    first_page = List.first(pages)
    last_page = List.last(pages)
    {range_start, range_end} = infinite_range(pages, socket.assigns.page_size)

    socket
    |> maybe_stream_items(stream_entries, stream_opts)
    |> assign(:loading, false)
    |> assign(:error, false)
    |> assign(:data, [])
    |> assign(:page, strip_page_results(page))
    |> assign(:infinite_pages, pages)
    |> assign(:infinite_item_ids, item_ids)
    |> assign(:infinite_selectable_ids, selectable_ids)
    |> assign(:infinite_loaded_count, MapSet.size(item_ids))
    |> assign(:infinite_range_start, range_start)
    |> assign(:infinite_range_end, range_end)
    |> assign(:first_keyset, first_page && first_page.first_keyset)
    |> assign(:last_keyset, last_page && last_page.last_keyset)
    |> update_infinite_boundaries(page, direction, window_pruned?)
    |> assign(:infinite_append?, false)
    |> assign(:infinite_direction, :append)
    |> maybe_schedule_infinite_prefetch()
  end

  defp strip_page_results(%Ash.Page.Keyset{} = page), do: %{page | results: []}
  defp strip_page_results(%Ash.Page.Offset{} = page), do: %{page | results: []}
  defp strip_page_results(page), do: page

  defp maybe_stream_items(%{private: %{lifecycle: _}} = socket, entries, opts) do
    stream(socket, :items, entries, opts)
  end

  defp maybe_stream_items(socket, _entries, _opts), do: socket

  defp infinite_number_start(_socket, :reset, _result_count), do: 1

  defp infinite_number_start(socket, :prepend, result_count) do
    max(socket.assigns.infinite_range_start - result_count, 1)
  end

  defp infinite_number_start(socket, _direction, _result_count) do
    max(socket.assigns.infinite_range_end + 1, 1)
  end

  defp build_infinite_page_meta(page_number, entries) do
    items = Enum.map(entries, &Map.take(&1, [:id, :keyset, :number, :selectable?]))
    refresh_infinite_page_meta(%{page: page_number}, items)
  end

  defp refresh_infinite_page_meta(page, items) do
    page
    |> Map.put(:items, items)
    |> Map.put(:ids, Enum.map(items, & &1.id))
    |> Map.put(:selectable_ids, items |> Enum.filter(& &1.selectable?) |> Enum.map(& &1.id))
    |> Map.put(:first_keyset, items |> List.first() |> then(&(&1 && &1.keyset)))
    |> Map.put(:last_keyset, items |> List.last() |> then(&(&1 && &1.keyset)))
  end

  defp update_infinite_pages(_pages, %{items: []}, :reset, _socket), do: {[], false}

  defp update_infinite_pages(pages, %{items: []}, _direction, _socket), do: {pages, false}

  defp update_infinite_pages(_pages, page_meta, :reset, _socket), do: {[page_meta], false}

  defp update_infinite_pages(pages, page_meta, :prepend, socket) do
    trim_infinite_pages([page_meta | pages], socket.assigns.window_size, :end)
  end

  defp update_infinite_pages(pages, page_meta, _direction, socket) do
    trim_infinite_pages(pages ++ [page_meta], socket.assigns.window_size, :start)
  end

  defp trim_infinite_pages(pages, limit, edge) do
    overflow = max(Enum.sum(Enum.map(pages, &length(&1.items))) - limit, 0)

    trimmed =
      case edge do
        :start -> trim_infinite_page_edge(pages, overflow)
        :end -> trim_infinite_page_end(pages, overflow)
      end

    {trimmed, overflow > 0}
  end

  defp trim_infinite_page_edge(pages, 0), do: pages
  defp trim_infinite_page_edge([], _drop), do: []

  defp trim_infinite_page_edge([page | rest], drop) do
    item_count = length(page.items)

    if drop >= item_count do
      trim_infinite_page_edge(rest, drop - item_count)
    else
      [refresh_infinite_page_meta(page, Enum.drop(page.items, drop)) | rest]
    end
  end

  defp trim_infinite_page_end(pages, 0), do: pages
  defp trim_infinite_page_end([], _drop), do: []

  defp trim_infinite_page_end(pages, drop) do
    page = List.last(pages)
    item_count = length(page.items)

    if drop >= item_count do
      pages |> Enum.drop(-1) |> trim_infinite_page_end(drop - item_count)
    else
      kept_items = Enum.take(page.items, item_count - drop)
      List.replace_at(pages, -1, refresh_infinite_page_meta(page, kept_items))
    end
  end

  defp update_infinite_boundaries(socket, page, :reset, _window_pruned?) do
    socket
    |> assign(:infinite_has_previous, false)
    |> assign(:infinite_has_next, has_more_results?(page))
  end

  defp update_infinite_boundaries(socket, page, :prepend, window_pruned?) do
    socket
    |> assign(:infinite_has_previous, has_more_results?(page))
    |> assign(:infinite_has_next, socket.assigns.infinite_has_next or window_pruned?)
  end

  defp update_infinite_boundaries(socket, page, _direction, window_pruned?) do
    socket
    |> assign(:infinite_has_previous, socket.assigns.infinite_has_previous or window_pruned?)
    |> assign(:infinite_has_next, has_more_results?(page))
  end

  defp infinite_range([], _page_size), do: {0, 0}

  defp infinite_range(pages, _page_size) do
    first_item = pages |> List.first() |> Map.fetch!(:items) |> List.first()
    last_item = pages |> List.last() |> Map.fetch!(:items) |> List.last()
    {first_item.number, last_item.number}
  end

  defp infinite_window_batches(socket),
    do: div(socket.assigns.window_size, socket.assigns.page_size)

  defp maybe_schedule_infinite_prefetch(socket) do
    target_batches = min(1 + socket.assigns.overscan, infinite_window_batches(socket))

    if connected?(socket) and not socket.assigns.infinite_prefetch_scheduled? and
         length(socket.assigns.infinite_pages) < target_batches and
         socket.assigns.infinite_has_next do
      send_update(__MODULE__, id: socket.assigns.id, __infinite_prefetch__: true)
      assign(socket, :infinite_prefetch_scheduled?, true)
    else
      socket
    end
  end

  defp maybe_start_infinite_prefetch(socket) do
    socket
    |> assign(:infinite_prefetch_scheduled?, false)
    |> maybe_load_infinite(:append)
  end

  defp maybe_load_infinite(socket, direction) do
    can_load? =
      socket.assigns.pagination_mode == :infinite and not socket.assigns.loading and
        not socket.assigns.error

    case {can_load?, direction, socket.assigns.infinite_pages} do
      {true, :append, pages} when pages != [] ->
        last = List.last(pages)

        if socket.assigns.infinite_has_next and not is_nil(last.last_keyset) do
          socket
          |> assign(:current_page, last.page + 1)
          |> assign(:after_keyset, last.last_keyset)
          |> assign(:before_keyset, nil)
          |> assign(:infinite_append?, true)
          |> assign(:infinite_direction, :append)
          |> load_data()
        else
          socket
        end

      {true, :prepend, [first | _]} ->
        if socket.assigns.infinite_has_previous and not is_nil(first.first_keyset) do
          socket
          |> assign(:current_page, max(first.page - 1, 1))
          |> assign(:before_keyset, first.first_keyset)
          |> assign(:after_keyset, nil)
          |> assign(:infinite_append?, true)
          |> assign(:infinite_direction, :prepend)
          |> load_data()
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp has_more_results?(%{more?: more?}), do: more?
  defp has_more_results?(_page), do: false

  defp mark_infinite_reset(socket) do
    socket
    |> assign(:infinite_direction, :reset)
    |> assign(:infinite_pages, [])
    |> assign(:infinite_item_ids, MapSet.new())
    |> assign(:infinite_selectable_ids, MapSet.new())
    |> assign(:infinite_loaded_count, 0)
    |> assign(:infinite_range_start, 0)
    |> assign(:infinite_range_end, 0)
    |> assign(:infinite_has_previous, false)
    |> assign(:infinite_has_next, false)
  end

  defp reset_infinite_pagination(socket) do
    socket
    |> assign(:current_page, 1)
    |> assign(:after_keyset, nil)
    |> assign(:before_keyset, nil)
    |> assign(:first_keyset, nil)
    |> assign(:last_keyset, nil)
    |> assign(:infinite_append?, false)
    |> mark_infinite_reset()
  end

  defp maybe_reset_infinite_pagination(socket) do
    if infinite_mode?(socket), do: reset_infinite_pagination(socket), else: socket
  end

  @silent_infinite_state_keys ~w(
    current_page after_keyset before_keyset first_keyset last_keyset
    infinite_append? infinite_direction infinite_pages infinite_item_ids
    infinite_selectable_ids infinite_loaded_count infinite_range_start
    infinite_range_end infinite_has_previous infinite_has_next
  )a

  defp prepare_refresh(%{assigns: %{silent_refresh: true}} = socket) do
    if infinite_mode?(socket) do
      state = Map.take(socket.assigns, @silent_infinite_state_keys)

      socket
      |> assign(:silent_refresh_state, state)
      |> assign(:current_page, 1)
      |> assign(:after_keyset, nil)
      |> assign(:before_keyset, nil)
      |> assign(:first_keyset, nil)
      |> assign(:last_keyset, nil)
      |> assign(:infinite_append?, false)
      |> assign(:infinite_direction, :reset)
    else
      socket
    end
  end

  defp prepare_refresh(socket), do: maybe_reset_infinite_pagination(socket)

  defp infinite_mode?(socket),
    do: Map.get(socket.assigns, :pagination_mode, :offset) == :infinite

  defp maybe_put_cursor(state, _key, nil), do: state
  defp maybe_put_cursor(state, key, cursor), do: Map.put(state, key, cursor)

  # ============================================================================
  # PRIVATE FUNCTIONS - State Notification
  # ============================================================================

  defp notify_state_change(socket, filters \\ nil) do
    filters = filters || socket.assigns.filters
    pagination_mode = socket.assigns.pagination_mode
    current_page = if pagination_mode == :infinite, do: 1, else: socket.assigns.current_page
    sort_by = socket.assigns.sort_by
    page_size_config = socket.assigns.page_size_config
    search_term = socket.assigns.search_term
    filter_field_names = socket.assigns.filter_field_names

    state = %{
      filters: filters,
      current_page: current_page,
      sort_by: sort_by,
      page_size: page_size_config.selected_page_size,
      default_page_size: page_size_config.default_page_size,
      search_term: search_term,
      filter_field_names: filter_field_names
    }

    # For keyset pagination, include after/before cursors for URL persistence
    state =
      if pagination_mode == :keyset do
        state
        |> maybe_put_cursor(:after, socket.assigns.after_keyset)
        |> maybe_put_cursor(:before, socket.assigns.before_keyset)
      else
        state
      end

    Cinder.UrlManager.notify_state_change(socket, state)
  end

  # ============================================================================
  # PRIVATE FUNCTIONS - URL State Decoding
  # ============================================================================

  defp decode_url_state(socket, assigns) do
    if Map.has_key?(assigns, :url_raw_params) do
      raw_params = assigns.url_raw_params

      decoded_filters =
        Cinder.UrlManager.decode_filters(raw_params, socket.assigns.query_columns)

      decoded_sorts =
        Cinder.UrlManager.decode_sort(Map.get(raw_params, "sort"), socket.assigns.columns)

      decoded_state = %{
        filters: decoded_filters,
        current_page: Cinder.UrlManager.decode_page(Map.get(raw_params, "page")),
        sort_by: decoded_sorts,
        page_size: Cinder.UrlManager.decode_page_size(Map.get(raw_params, "page_size")),
        search_term: Map.get(raw_params, "search", ""),
        after: Cinder.UrlManager.decode_cursor(Map.get(raw_params, "after")),
        before: Cinder.UrlManager.decode_cursor(Map.get(raw_params, "before"))
      }

      final_sort_by =
        cond do
          decoded_state.sort_by != [] ->
            decoded_state.sort_by

          Map.get(socket.assigns, :user_has_interacted, false) ->
            []

          true ->
            socket.assigns.sort_by
        end

      updated_socket =
        if Map.has_key?(raw_params, "page_size") do
          validated_page_size =
            Cinder.PageSize.validate(decoded_state.page_size, socket.assigns.page_size_config)

          updated_page_size_config = %{
            socket.assigns.page_size_config
            | selected_page_size: validated_page_size
          }

          socket
          |> assign(:page_size, validated_page_size)
          |> assign(:page_size_config, updated_page_size_config)
        else
          socket
        end

      # Handle keyset cursors from URL (after/before params)
      updated_socket =
        if socket.assigns.pagination_mode == :keyset do
          updated_socket
          |> maybe_assign_cursor(:after_keyset, decoded_state.after)
          |> maybe_assign_cursor(:before_keyset, decoded_state.before)
        else
          updated_socket
        end

      updated_socket
      |> assign(:filters, decoded_state.filters)
      |> assign(
        :current_page,
        if(socket.assigns.pagination_mode == :infinite, do: 1, else: decoded_state.current_page)
      )
      |> assign(:sort_by, final_sort_by)
      |> assign(:search_term, decoded_state.search_term)
    else
      socket
    end
  end

  defp maybe_assign_cursor(socket, _key, nil), do: socket
  defp maybe_assign_cursor(socket, key, cursor), do: assign(socket, key, cursor)

  # ============================================================================
  # PRIVATE FUNCTIONS - Initialization
  # ============================================================================

  defp assign_defaults(socket) do
    assigns = socket.assigns

    # Use existing page_size_config if already parsed by Collection,
    # otherwise parse the global default
    page_size_config =
      assigns[:page_size_config] || Cinder.PageSize.parse(nil)

    selected_page_size =
      Map.get(socket.assigns, :page_size) || page_size_config.selected_page_size

    updated_page_size_config = %{page_size_config | selected_page_size: selected_page_size}

    # Determine pagination mode (default to :offset for backwards compatibility)
    pagination_mode = assigns[:pagination_mode] || :offset
    overscan = normalize_overscan(assigns[:overscan])
    window_size = normalize_window_size(assigns[:window_size], selected_page_size, overscan)

    socket
    |> assign(:page_size, selected_page_size)
    |> assign(:page_size_config, updated_page_size_config)
    |> assign(:current_page, assigns[:current_page] || 1)
    |> assign(:loading, false)
    |> assign(:silent_refresh, assigns[:silent_refresh] || false)
    |> assign(:silent_refresh_state, assigns[:silent_refresh_state])
    |> assign(:error, assigns[:error] || false)
    |> assign(:data, assigns[:data] || [])
    |> assign(:sort_by, assigns[:sort_by] || extract_initial_sorts(assigns))
    |> assign(:filters, assigns[:filters] || %{})
    |> assign(:search_term, assigns[:search_term] || "")
    |> assign(:theme, assigns[:theme] || Cinder.Theme.default())
    |> assign(:query_opts, assigns[:query_opts] || [])
    |> assign(:initial_load, Map.get(assigns, :initial_load, :async))
    |> assign_new(:action, fn -> nil end)
    |> assign_new(:page, fn -> nil end)
    |> assign_new(:__initial_load__, fn -> is_nil(assigns[:page]) end)
    |> assign(:user_has_interacted, Map.get(socket.assigns, :user_has_interacted, false))
    # Keyset pagination state
    |> assign(:pagination_mode, pagination_mode)
    |> assign(:count_mode, Map.get(assigns, :count_mode, :sync))
    |> assign_new(:total_count, fn -> nil end)
    |> assign_new(:count_query_state, fn -> nil end)
    |> assign_new(:count_attempt, fn -> nil end)
    |> assign(:window_size, window_size)
    |> assign(:overscan, overscan)
    |> assign(:show_item_numbers, assigns[:show_item_numbers] || false)
    |> assign(:after_keyset, assigns[:after_keyset])
    |> assign(:before_keyset, assigns[:before_keyset])
    |> assign(:first_keyset, assigns[:first_keyset])
    |> assign(:last_keyset, assigns[:last_keyset])
    |> assign(:infinite_append?, assigns[:infinite_append?] || false)
    |> assign(:infinite_direction, assigns[:infinite_direction] || :reset)
    |> assign(:infinite_pages, assigns[:infinite_pages] || [])
    |> assign(:infinite_item_ids, assigns[:infinite_item_ids] || MapSet.new())
    |> assign(:infinite_selectable_ids, assigns[:infinite_selectable_ids] || MapSet.new())
    |> assign(:infinite_loaded_count, assigns[:infinite_loaded_count] || 0)
    |> assign(:infinite_range_start, assigns[:infinite_range_start] || 0)
    |> assign(:infinite_range_end, assigns[:infinite_range_end] || 0)
    |> assign(:infinite_has_previous, assigns[:infinite_has_previous] || false)
    |> assign(:infinite_has_next, assigns[:infinite_has_next] || false)
    |> assign(:infinite_prefetch_scheduled?, assigns[:infinite_prefetch_scheduled?] || false)
    |> assign_new(:infinite_stream_configured?, fn -> false end)
    # Selection state
    |> assign(:selectable, assigns[:selectable] || false)
    |> assign_new(:selected_ids, fn -> MapSet.new() end)
    |> assign_new(:selection_scope_ids, fn -> nil end)
    |> assign_new(:selection_attempt, fn -> nil end)
    |> assign_new(:selection_loading, fn -> false end)
    |> assign(:on_selection_change, assigns[:on_selection_change])
    |> assign(:on_query_change, assigns[:on_query_change])
    |> assign(:id_field, assigns[:id_field] || :id)
    |> assign(:sort_mode, assigns[:sort_mode] || :additive)
    # Bulk actions
    |> assign_new(:bulk_action_slots, fn -> [] end)
    |> assign_new(:bulk_action_confirmation_slot, fn -> [] end)
    |> assign_new(:bulk_action_confirmation, fn -> nil end)
  end

  defp normalize_overscan(value) when is_integer(value) and value >= 0, do: value
  defp normalize_overscan(_value), do: 1

  defp normalize_window_size(value, page_size, overscan) do
    requested =
      if is_integer(value) and value >= page_size do
        value
      else
        page_size * (1 + 2 * overscan)
      end

    ceil(requested / page_size) * page_size
  end

  defp ensure_infinite_stream(socket) do
    if socket.assigns.infinite_stream_configured? do
      socket
    else
      component_id = socket.assigns.id

      socket
      |> stream_configure(:items, dom_id: &"#{component_id}-item-#{&1.id}")
      |> assign(:infinite_stream_configured?, true)
    end
  end

  defp assign_column_definitions(socket) do
    # Display columns - already processed by Collection, use directly
    columns = socket.assigns.col

    # Query columns - columns used for filtering and searching
    # Includes filterable columns, searchable columns, and filter-only slots
    query_columns =
      case Map.get(socket.assigns, :query_columns) do
        nil -> columns
        qc -> qc
      end

    # Field names of filterable columns (for URL state management)
    filter_field_names =
      query_columns
      |> Enum.filter(& &1.filterable)
      |> Enum.map(& &1.field)

    socket
    |> assign(:columns, columns)
    |> assign(:query_columns, query_columns)
    |> assign(:filter_field_names, filter_field_names)
  end

  defp extract_initial_sorts(assigns) do
    query = assigns[:query]
    columns = assigns[:col] || []

    simple_columns =
      Enum.map(columns, fn col ->
        field_name =
          case col.field do
            field when is_atom(field) -> Atom.to_string(field)
            field when is_binary(field) -> field
            field -> inspect(field)
          end

        %{field: field_name}
      end)

    query_sorts =
      case query do
        nil -> []
        query -> Cinder.QueryBuilder.extract_query_sorts(query, simple_columns)
      end

    Cinder.QueryBuilder.default_sorts_from_cycles(columns, query_sorts)
  end

  # ============================================================================
  # PRIVATE FUNCTIONS - Data Loading
  # ============================================================================

  # Keys that affect data queries - changes to these trigger a reload.
  # Note: actor, tenant, and scope are normalized separately to avoid
  # false positives from Ecto struct metadata differences.
  @data_keys ~w(filters sort_by current_page page_size search_term query query_opts after_keyset before_keyset)a
  @count_keys ~w(filters search_term query query_opts action)a

  defp data_state(assigns) do
    base_state = Map.take(assigns, @data_keys)

    Map.merge(base_state, %{
      count_mode: Map.get(assigns, :count_mode, :sync),
      actor_id: normalize_auth(assigns[:actor]),
      tenant_id: normalize_auth(assigns[:tenant]),
      scope_id: normalize_scope(assigns[:scope])
    })
  end

  defp count_query_state(assigns) do
    base_state = Map.take(assigns, @count_keys)

    Map.merge(base_state, %{
      count_mode: Map.get(assigns, :count_mode, :sync),
      actor_id: normalize_auth(assigns[:actor]),
      tenant_id: normalize_auth(assigns[:tenant]),
      scope_id: normalize_scope(assigns[:scope])
    })
  end

  @selection_scope_keys ~w(filters search_term query query_opts action selectable id_field search_fn)a

  defp selection_scope_state(assigns) do
    Map.merge(Map.take(assigns, @selection_scope_keys), %{
      actor_id: normalize_auth(assigns[:actor]),
      tenant_id: normalize_auth(assigns[:tenant]),
      scope_id: normalize_scope(assigns[:scope])
    })
  end

  defp normalize_auth(nil), do: nil
  defp normalize_auth(value) when is_binary(value) or is_atom(value), do: value
  defp normalize_auth(%{id: id}), do: id
  defp normalize_auth(value), do: value

  # Normalize scope by extracting IDs from nested structs
  defp normalize_scope(nil), do: nil

  defp normalize_scope(%_{} = scope) do
    scope
    |> Map.from_struct()
    |> normalize_scope()
  end

  defp normalize_scope(scope) when is_map(scope) do
    scope
    |> Enum.map(fn
      {key, %{id: id}} -> {key, id}
      {key, value} when is_map(value) -> {key, normalize_scope(value)}
      {key, value} -> {key, value}
    end)
    |> Enum.sort()
  end

  defp normalize_scope(value), do: value

  defp load_data_if_needed(socket, prev) do
    first_load = socket.assigns[:__initial_load__] == true
    curr = data_state(socket.assigns)
    state_changed = curr != prev
    reload_requested = socket.assigns[:__reload_requested__] == true
    socket = assign(socket, :__reload_requested__, false)

    if first_load or state_changed or reload_requested do
      load_data(socket)
    else
      socket
    end
  end

  defp load_data(socket) do
    # A `:sync` collection spends exactly one blocking query, on its first load,
    # so the data is in the server-rendered HTML. Everything after that — including
    # a retry, if that first query failed — goes back to the async path.
    sync_initial_load? =
      socket.assigns[:initial_load] == :sync and
        socket.assigns[:__initial_sync_done__] != true

    %{
      query: resource,
      query_opts: query_opts,
      actor: actor,
      tenant: tenant,
      page_size: page_size,
      current_page: current_page,
      sort_by: sort_by,
      filters: filters,
      columns: columns,
      search_term: search_term,
      pagination_mode: pagination_mode,
      after_keyset: after_keyset,
      before_keyset: before_keyset
    } = socket.assigns

    scope = Map.get(socket.assigns, :scope)
    count_mode = Map.get(socket.assigns, :count_mode, :sync)

    resource_var = resource

    # Use query_columns for filtering and searching (includes filter-only slots)
    query_columns = Map.get(socket.assigns, :query_columns, columns)

    action = Map.get(socket.assigns, :action)

    options = [
      actor: actor,
      tenant: tenant,
      scope: scope,
      action: action,
      query_opts: query_opts,
      filters: filters,
      sort_by: sort_by,
      page_size: page_size,
      current_page: current_page,
      columns: query_columns,
      search_term: search_term,
      search_fn: Map.get(socket.assigns, :search_fn),
      pagination_configured: socket.assigns.page_size_config.configurable || page_size != 25,
      # Keyset pagination options
      pagination_mode: pagination_mode,
      count_mode: count_mode,
      after_keyset: after_keyset,
      before_keyset: before_keyset
    ]

    socket
    |> assign(:__initial_load__, false)
    |> prepare_count_for_load()
    |> assign(:loading, true)
    |> assign(:error, false)
    |> then(fn socket ->
      # Build the query once so we can both execute it and hand it to the
      # on_query_change callback (if one is configured). maybe_notify_query_change/2
      # decides whether to actually notify.
      if sync_initial_load? or Application.get_env(:ash, :disable_async?) do
        socket = assign(socket, :__initial_sync_done__, true)

        try do
          case Cinder.QueryBuilder.build_query(resource_var, options) do
            {:ok, prepared_query} ->
              prepared_query
              |> Cinder.QueryBuilder.execute(options)
              |> handle_result(socket)
              |> maybe_notify_query_change(prepared_query)
              |> maybe_start_async_count(prepared_query)

            {:error, _} = error ->
              handle_result(error, socket)
          end
        rescue
          e -> handle_result({:exit, e}, socket)
        end
      else
        start_async(socket, :load_data, fn ->
          case Cinder.QueryBuilder.build_query(resource_var, options) do
            {:ok, prepared_query} ->
              {Cinder.QueryBuilder.execute(prepared_query, options), prepared_query}

            {:error, _} = error ->
              {error, nil}
          end
        end)
      end
    end)
  end

  defp selection_query_options(socket) do
    assigns = socket.assigns

    [
      actor: assigns.actor,
      tenant: assigns.tenant,
      scope: Map.get(assigns, :scope),
      action: Map.get(assigns, :action),
      query_opts: assigns.query_opts,
      filters: assigns.filters,
      sort_by: assigns.sort_by,
      page_size: assigns.page_size,
      current_page: assigns.current_page,
      columns: Map.get(assigns, :query_columns, assigns.columns),
      search_term: assigns.search_term,
      search_fn: assigns.search_fn,
      pagination_configured: assigns.page_size_config.configurable || assigns.page_size != 25,
      pagination_mode: assigns.pagination_mode,
      after_keyset: assigns.after_keyset,
      before_keyset: assigns.before_keyset
    ]
  end

  defp apply_select_all_result(socket, attempt, result) do
    if socket.assigns.selection_attempt == attempt do
      case result do
        {:ok, scope_ids} ->
          socket
          |> assign(
            selected_ids: MapSet.union(socket.assigns.selected_ids, scope_ids),
            selection_scope_ids: scope_ids,
            selection_attempt: nil,
            selection_loading: false
          )
          |> notify_selection_change(:select_all)

        {:error, reason} ->
          Logger.error("Cinder: failed to select all filtered records: #{inspect(reason)}")
          assign(socket, selection_attempt: nil, selection_loading: false)
      end
    else
      socket
    end
  end

  defp invalidate_selection_scope(socket) do
    assign(socket, selection_scope_ids: nil, selection_attempt: nil, selection_loading: false)
  end

  defp maybe_invalidate_selection_scope(socket, previous) do
    if selection_scope_state(socket.assigns) == previous do
      socket
    else
      invalidate_selection_scope(socket)
    end
  end

  defp prepare_count_for_load(socket) do
    state = count_query_state(socket.assigns)

    if Map.get(socket.assigns, :count_query_state) == state do
      socket
    else
      assign(socket, total_count: nil, count_query_state: state, count_attempt: nil)
    end
  end

  defp maybe_store_sync_count(%{assigns: %{count_mode: :sync}} = socket, page) do
    assign(socket, :total_count, Map.get(page, :count))
  end

  defp maybe_store_sync_count(socket, _page), do: socket

  defp maybe_start_async_count(%{assigns: %{count_mode: :async}} = socket, %Ash.Query{} = query) do
    if is_integer(socket.assigns.total_count) or socket.assigns.count_attempt do
      socket
    else
      attempt = make_ref()
      socket = assign(socket, :count_attempt, attempt)
      options = count_query_options(socket)

      if Application.get_env(:ash, :disable_async?) do
        apply_async_count_result(
          socket,
          attempt,
          Cinder.QueryBuilder.count(query, options)
        )
      else
        start_async(socket, {:load_count, attempt}, fn ->
          Cinder.QueryBuilder.count(query, options)
        end)
      end
    end
  end

  defp maybe_start_async_count(socket, _query), do: socket

  defp apply_async_count_result(socket, attempt, {:ok, count})
       when socket.assigns.count_attempt == attempt do
    assign(socket, total_count: count, count_attempt: nil)
  end

  defp apply_async_count_result(socket, attempt, {:error, reason})
       when socket.assigns.count_attempt == attempt do
    Logger.warning("Cinder count query failed: #{inspect(reason)}")
    assign(socket, :count_attempt, nil)
  end

  defp apply_async_count_result(socket, _attempt, _result), do: socket

  defp count_query_options(socket) do
    [
      actor: socket.assigns.actor,
      tenant: socket.assigns.tenant,
      scope: Map.get(socket.assigns, :scope),
      query_opts: socket.assigns.query_opts
    ]
  end
end
