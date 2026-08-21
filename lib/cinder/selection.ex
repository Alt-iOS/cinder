defmodule Cinder.Selection do
  @moduledoc """
  Predicates that decide selection behaviour for a collection.

  Selection has two distinct concerns:

    * whether selection is enabled for the collection at all (`enabled?/1`),
      which governs the checkbox column, the "select all" control and the
      bulk-action bar; and
    * whether an individual item may be selected (`item_selectable?/2`), which
      governs the per-item checkbox and click-to-toggle.

  These functions are shared by the renderers and `Cinder.LiveComponent`. They
  treat the `selectable` value uniformly as `true | false | (item -> boolean)`.
  """

  @doc """
  Returns whether selection is enabled for the collection.

  `false` and `nil` disable selection entirely; any other value (`true` or a
  predicate function) enables it.
  """
  def enabled?(false), do: false
  def enabled?(nil), do: false
  def enabled?(_), do: true

  @doc """
  Returns whether the given `item` may be selected.

  A predicate function is called with the item and its result is coerced to a
  boolean.
  """
  def item_selectable?(false, _item), do: false
  def item_selectable?(true, _item), do: true
  def item_selectable?(fun, item) when is_function(fun, 1), do: !!fun.(item)
  def item_selectable?(_, _item), do: false

  @doc """
  Returns whether the given `item` is currently selected.
  """
  def item_selected?(selected_ids, item, id_field) do
    MapSet.member?(selected_ids, to_string(Map.get(item, id_field)))
  end

  @doc """
  Returns whether the given `item`'s checkbox should be interactive.

  An item is toggleable when it is selectable, or when it is already selected so
  that an item that became non-selectable can still be removed.
  """
  def item_toggleable?(selectable, selected_ids, item, id_field) do
    item_selectable?(selectable, item) or item_selected?(selected_ids, item, id_field)
  end

  @doc """
  Returns the unique IDs of selectable items in the currently rendered batch.

  The returned set intentionally describes only visible data. Selections from
  other pages remain in `selected_ids`, but do not affect the visible
  select-all control's checked or indeterminate state.
  """
  def page_ids(data, id_field, selectable) when is_list(data) do
    data
    |> Enum.filter(&item_selectable?(selectable, &1))
    |> Enum.map(&to_string(Map.get(&1, id_field)))
    |> MapSet.new()
  end

  def page_ids(_data, _id_field, _selectable), do: MapSet.new()

  @doc false
  def filtered_ids(resource_or_query, options, id_field, selectable) do
    with {:ok, query} <- Cinder.QueryBuilder.build_query(resource_or_query, options),
         {:ok, records} <- Cinder.QueryBuilder.read_all(query, options) do
      {:ok, page_ids(records, id_field, selectable)}
    end
  end

  @doc """
  Returns `:none`, `:some`, or `:all` for the selectable visible items.
  """
  def page_state(selected_ids, data, id_field, selectable) do
    page_ids = page_ids(data, id_field, selectable)
    selected_page_ids = MapSet.intersection(page_ids, selected_ids)

    cond do
      MapSet.size(selected_page_ids) == 0 -> :none
      MapSet.equal?(selected_page_ids, page_ids) -> :all
      true -> :some
    end
  end
end
