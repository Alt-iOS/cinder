defmodule Cinder.Renderers.TableItemCellsTest do
  @moduledoc """
  Tests for a table layout whose `<:item>` slot renders each row's cells.
  """

  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Cinder.Renderers.Table, as: TableRenderer

  @data [%{id: "1", name: "First"}, %{id: "2", name: "Second"}]

  defp assigns(overrides) do
    col_slot = %{__slot__: :col, field: :name, inner_block: fn _, _item -> "column cell" end}

    Map.merge(
      %{
        id: "test-table",
        theme: Cinder.Theme.default() |> Map.put(:row_class, "theme-row"),
        data: @data,
        columns: [%{field: :name, label: "Name", sortable: false, class: nil, slot: col_slot}],
        col_slot: [col_slot],
        filters: %{},
        sort_by: [],
        sort_label: "Sort",
        loading: false,
        show_loading_state: false,
        error: false,
        loading_message: "Loading...",
        empty_message: "No results",
        error_message: "An error occurred",
        show_filters: false,
        show_sort: false,
        show_pagination: false,
        page: nil,
        page_size_config: %{},
        pagination_mode: :offset,
        myself: nil,
        filters_label: "Filters",
        search_term: "",
        search_enabled: false,
        search_label: "Search",
        search_placeholder: "Search...",
        row_click: nil,
        selectable: false,
        selected_ids: MapSet.new(),
        id_field: :id,
        bulk_action_slots: []
      },
      overrides
    )
  end

  defp item_slot do
    [
      %{
        __slot__: :item,
        inner_block: fn _, item ->
          Phoenix.HTML.raw(~s(<td class="own-cell">#{item.name}</td>))
        end
      }
    ]
  end

  test "the item slot renders each row's cells, and the columns only head the table" do
    html = render_component(&TableRenderer.render/1, assigns(%{item_slot: item_slot()}))

    assert html =~ ~s(<td class="own-cell">First</td>)
    assert html =~ ~s(<td class="own-cell">Second</td>)
    refute html =~ "column cell"
    assert html =~ "Name"
    assert html =~ ~s(data-item-id="1")
    assert html =~ "theme-row"
  end

  test "a selectable table keeps its selection cell before the item's cells" do
    html =
      render_component(
        &TableRenderer.render/1,
        assigns(%{item_slot: item_slot(), selectable: true})
      )

    [_head, first_row | _rest] = String.split(html, ~s(data-item-id="1"))
    assert first_row =~ ~r/type="checkbox".*own-cell/s
  end

  test "without an item slot, each column renders its cell" do
    html = render_component(&TableRenderer.render/1, assigns(%{}))

    assert html =~ "column cell"
    refute html =~ "own-cell"
  end
end
