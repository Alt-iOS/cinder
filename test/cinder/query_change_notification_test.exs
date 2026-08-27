defmodule Cinder.QueryChangeNotificationTest do
  use ExUnit.Case, async: true

  alias Cinder.LiveComponent

  defp make_socket(assigns) do
    defaults = %{
      __changed__: %{},
      id: "test-table",
      on_query_change: :query_changed,
      query: TestUserResource,
      filters: %{},
      sort_by: [],
      current_page: 1,
      data: [],
      page: nil,
      loading: false,
      error: false
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      root_pid: self()
    }
  end

  defp load(socket, page) do
    query = Ash.Query.new(TestUserResource)
    LiveComponent.handle_async(:load_data, {:ok, {{:ok, page}, query}}, socket)
  end

  describe "on_query_change payload" do
    test "carries the total count from an offset page" do
      page = %Ash.Page.Offset{results: [%{id: 1}], count: 42, limit: 25, offset: 0}

      {:noreply, socket} = load(make_socket(%{}), page)

      assert_received {:query_changed, %{count: 42, id: "test-table"}}
      assert socket.assigns.total_count == 42
    end

    test "carries the total count from a keyset page" do
      page = %Ash.Page.Keyset{results: [%{id: 1}], count: 7, limit: 25}

      {:noreply, _socket} = load(make_socket(%{}), page)

      assert_received {:query_changed, %{count: 7}}
    end

    test "reports nil when the read returned no count" do
      page = %Ash.Page.Offset{results: [%{id: 1}], count: nil, limit: 25, offset: 0}

      {:noreply, _socket} = load(make_socket(%{}), page)

      assert_received {:query_changed, %{count: nil}}
    end

    test "uses total_count as the callback API when counting is disabled" do
      page = %Ash.Page.Offset{results: [%{id: 1}], count: 42, limit: 25, offset: 0}

      {:noreply, socket} =
        load(make_socket(%{count_mode: false, total_count: nil}), page)

      assert socket.assigns.total_count == nil
      assert_received {:query_changed, %{count: nil}}
    end

    test "sends the completed asynchronous count as a second query notification" do
      query = Ash.Query.new(TestUserResource)
      attempt = make_ref()

      socket =
        make_socket(%{
          count_mode: :async,
          total_count: nil,
          count_attempt: attempt,
          count_query: query
        })

      {:noreply, socket} =
        LiveComponent.handle_async({:load_count, attempt}, {:ok, {:ok, 40}}, socket)

      assert socket.assigns.total_count == 40
      assert socket.assigns.count_query == nil
      assert_received {:query_changed, %{query: ^query, count: 40}}
    end

    test "reports the number of loaded records for an unpaginated read" do
      {:noreply, socket} = load(make_socket(%{}), %{results: [%{id: 1}, %{id: 2}]})

      assert_received {:query_changed, %{count: 2}}
      assert socket.assigns.total_count == 2
    end

    test "still carries the query alongside the count" do
      page = %Ash.Page.Offset{results: [], count: 0, limit: 25, offset: 0}

      {:noreply, _socket} = load(make_socket(%{}), page)

      assert_received {:query_changed, %{query: %Ash.Query{}, count: 0}}
    end

    test "sends nothing when on_query_change is not set" do
      page = %Ash.Page.Offset{results: [], count: 3, limit: 25, offset: 0}

      {:noreply, _socket} = load(make_socket(%{on_query_change: nil}), page)

      refute_received {:query_changed, _payload}
    end
  end
end
