defmodule Cinder.Core.SearchMinLengthTest do
  # Changes the application environment the search reads, so it can't run beside other tests.
  use ExUnit.Case, async: false

  alias Cinder.QueryBuilder
  alias Cinder.Support.SearchTestResource

  setup do
    Application.put_env(:cinder, :search_min_length, 3)
    on_exit(fn -> Application.delete_env(:cinder, :search_min_length) end)

    %{
      query: Ash.Query.for_read(SearchTestResource, :read),
      columns: [%{field: "title", searchable: true}]
    }
  end

  test "a term shorter than the minimum leaves the query as it is", %{
    query: query,
    columns: columns
  } do
    searched = fn _query, _columns, _term -> flunk("searched a short term") end

    assert QueryBuilder.apply_search(query, "ab", columns, nil) == query
    assert QueryBuilder.apply_search(query, "  ab  ", columns, searched) == query
  end

  test "a term of the minimum length is searched", %{query: query, columns: columns} do
    assert QueryBuilder.apply_search(query, "abc", columns, nil).filter != nil

    assert QueryBuilder.apply_search(query, "abc", columns, fn query, _columns, _term ->
             {:searched, query}
           end) ==
             {:searched, query}
  end
end
