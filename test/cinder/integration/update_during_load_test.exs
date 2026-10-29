defmodule Cinder.Integration.UpdateDuringLoadTest do
  use Cinder.ConnCase, async: false
  use Mimic

  import Phoenix.ConnTest, only: [get: 2]

  import Phoenix.LiveViewTest,
    only: [live: 2, render: 1, render_async: 1, render_click: 1, element: 2]

  setup {Cinder.TestHelpers, :enable_async_loading}

  setup do
    artist = generate(artist(name: "Concurrent updates"))
    album = generate(album(title: "Target", artist_id: artist.id))
    retained = generate(album(title: "Retained", artist_id: artist.id))

    for title <- ["Alpha", "Bravo", "Charlie"] do
      generate(album(title: title, artist_id: artist.id))
    end

    on_exit(fn ->
      Ash.bulk_destroy!(Music.Album, :destroy, %{})
      Ash.bulk_destroy!(Music.Artist, :destroy, %{})
    end)

    %{album: album, retained: retained}
  end

  defp mount_collection(conn, pagination, count \\ true) do
    path =
      Cinder.TestLive.Fixture.register(
        fn assigns ->
          assigns = assign(assigns, :pagination, mode: pagination, count: count)

          ~H"""
          <Cinder.collection
            id="albums"
            query={Ash.Query.sort(Music.Album, :title)}
            action={:paginated}
            page_size={3}
            pagination={@pagination}
            on_query_change={:query_changed}
          >
            <:col :let={album} field="title">
              {album.title}:{if album.is_remastered, do: "started", else: "required"}
            </:col>
          </Cinder.collection>
          """
        end,
        forward_to: self()
      )

    {:ok, view, _} = live(conn, path)
    render_async(view)

    view |> element(~s(button[title="Next page"])) |> render_click()

    render_async(view)
    view
  end

  defp pause_reads(view, silent) do
    test_pid = self()
    allow(Ash, test_pid, view.pid)

    stub(Ash, :read, fn query, opts ->
      # Capture the page before accepting any concurrent change, then hold its reply.
      result = call_original(Ash, :read, [query, opts])
      send(test_pid, {:read_finished, self()})

      receive do
        :deliver -> result
      after
        5_000 -> raise "test did not release the read"
      end
    end)

    Cinder.TestLive.Fixture.run(view, &Cinder.refresh_table(&1, "albums", silent: silent))
    assert_receive {:read_finished, pid}, 1_000
    pid
  end

  for pagination <- [:offset, :keyset] do
    @recovery_pagination pagination

    test "#{pagination}: removing every incoming row during navigation recovers a reachable page",
         %{
           conn: conn,
           album: album,
           retained: retained
         } do
      Music.Album |> Ash.read!() |> Enum.find(&(&1.title == "Charlie")) |> Ash.destroy!()

      path =
        Cinder.TestLive.Fixture.register(
          fn assigns ->
            assigns = assign(assigns, :pagination, @recovery_pagination)

            ~H"""
            <Cinder.collection id="albums" query={Ash.Query.sort(Music.Album, :title)}
              action={:paginated} page_size={2} pagination={[mode: @pagination, count: true]}
              on_state_change={:recovery_state_changed}>
              <:col :let={row} field="title">{row.title}</:col>
            </Cinder.collection>
            """
          end,
          forward_to: self()
        )

      {:ok, view, _} = live(conn, path)
      assert render_async(view) =~ "Alpha"
      test_pid = self()
      allow(Ash, test_pid, view.pid)

      stub(Ash, :read, fn query, opts ->
        result = call_original(Ash, :read, [query, opts])

        case result do
          {:ok, %{results: [%{id: id} | _]}} when id == retained.id ->
            send(test_pid, {:read_finished, self()})

            receive do
              :deliver -> result
            after
              5_000 -> raise "test did not release the navigation read"
            end

          _ ->
            result
        end
      end)

      view |> element(~s(button[title="Next page"])) |> render_click()
      assert_receive {:read_finished, read}, 1_000
      assert_receive {:recovery_state_changed, "albums", navigation_state}

      if @recovery_pagination == :keyset do
        assert Map.has_key?(navigation_state, :after)
      else
        assert navigation_state.page == "2"
      end

      for item <- [retained, album] do
        Ash.destroy!(item)
        Cinder.TestLive.Fixture.run(view, &Cinder.remove_item(&1, "albums", item.id))
      end

      assert render(view) =~ "Alpha"
      send(read, :deliver)
      render_async(view)
      html = render_async(view)
      assert html =~ "Alpha"
      assert html =~ "Bravo"
      refute html =~ ~s(data-key="loading_overlay_class")
      refute html =~ "Target"
      refute html =~ "Retained"
      assert_receive {:recovery_state_changed, "albums", state}
      refute Map.has_key?(state, :page)
      refute Map.has_key?(state, :after)
      refute Map.has_key?(state, :before)

      generate(album(title: "Zulu", artist_id: album.artist_id))
      Cinder.TestLive.Fixture.run(view, &Cinder.refresh_table(&1, "albums"))
      render_async(view)
      view |> element(~s(button[title="Next page"])) |> render_click()
      assert render_async(view) =~ "Zulu"
      view |> element(~s(button[title="Previous page"])) |> render_click()
      html = render_async(view)
      assert html =~ "Alpha"
      assert html =~ "Bravo"
    end
  end

  for pagination <- [:offset, :keyset], silent <- [false, true] do
    @pagination pagination
    @silent silent

    for variant <- [:single, :multiple, :visible_id, :visible_item, :visible_ids, :visible_items] do
      @variant variant
      test "#{pagination}, silent=#{silent}: #{variant} update supersedes the older page", %{
        conn: conn,
        album: album,
        retained: retained
      } do
        view = mount_collection(conn, @pagination)
        old_read = pause_reads(view, @silent)
        updated = album |> Ash.Changeset.for_update(:remaster, %{}) |> Ash.update!()
        test_pid = self()

        callback = fn _item ->
          send(test_pid, :callback_called)
          updated
        end

        updated_retained = retained |> Ash.Changeset.for_update(:remaster, %{}) |> Ash.update!()
        replacements = %{album.id => updated, retained.id => updated_retained}

        batch = fn items ->
          send(test_pid, :batch_called)
          Enum.map(items, &Map.fetch!(replacements, &1.id))
        end

        multiple = fn item ->
          send(test_pid, :callback_called)
          Map.fetch!(replacements, item.id)
        end

        Cinder.TestLive.Fixture.run(view, fn socket ->
          case @variant do
            :single ->
              Cinder.update_item(socket, "albums", album.id, callback)

            :multiple ->
              Cinder.update_items(socket, "albums", [album.id, retained.id], multiple)

            :visible_id ->
              Cinder.update_if_visible(socket, "albums", album.id, callback)

            :visible_item ->
              Cinder.update_if_visible(socket, "albums", updated, callback)

            :visible_ids ->
              Cinder.update_items_if_visible(socket, "albums", [album.id, retained.id], batch)

            :visible_items ->
              Cinder.update_items_if_visible(socket, "albums", [updated, updated_retained], batch)
          end
        end)

        assert render(view) =~ "Target:started"

        if @variant in [:visible_ids, :visible_items] do
          assert_received :batch_called
        else
          assert_received :callback_called
          if @variant == :multiple, do: assert_received(:callback_called)
        end

        send(old_read, :deliver)
        assert render_async(view) =~ "Target:started"

        if @variant in [:multiple, :visible_ids, :visible_items] do
          assert render(view) =~ "Retained:started"
        end

        refute_received :batch_called
        refute_received :callback_called
        refute_received {:read_finished, _}
      end
    end

    test "#{pagination}, silent=#{silent}: updates across consecutive reads still allow progress",
         %{
           conn: conn,
           album: album
         } do
      view = mount_collection(conn, @pagination, :async)
      test_pid = self()

      Enum.reduce(1..3, nil, fn round, previous ->
        if previous, do: Ash.destroy!(previous)
        inserted = generate(album(title: "Zulu #{round}", artist_id: album.artist_id))
        read = pause_reads(view, @silent)
        refute render(view) =~ "Zulu #{round}:"

        for step <- 1..3 do
          Cinder.TestLive.Fixture.run(view, fn socket ->
            Cinder.update_item(socket, "albums", album.id, fn item ->
              send(test_pid, {:updated, round, step})
              %{item | title: "Target #{round}.#{step}"}
            end)
          end)

          assert render(view) =~ "Target #{round}.#{step}:"
          assert_receive {:updated, ^round, ^step}
        end

        send(read, :deliver)
        html = render_async(view)
        assert html =~ "Zulu #{round}:required"
        assert html =~ "Target #{round}.3:required"
        refute html =~ ~s(data-key="loading_overlay_class")
        assert_receive {:query_changed, %{count: 6}}, 1_000
        refute_received {:updated, _, _}
        refute_received {:read_finished, _}
        inserted
      end)
    end

    test "#{pagination}, silent=#{silent}: a replacement read has its own changes", %{
      conn: conn,
      album: album
    } do
      view = mount_collection(conn, @pagination)
      superseded = pause_reads(view, @silent)

      Cinder.TestLive.Fixture.run(view, fn socket ->
        Cinder.update_item(socket, "albums", album.id, &%{&1 | title: "Superseded"})
      end)

      assert render(view) =~ "Superseded:"
      replacement = pause_reads(view, @silent)
      send(replacement, :deliver)
      html = render_async(view)
      assert html =~ "Target:required"
      refute html =~ "Superseded:"
      send(superseded, :deliver)
      assert render(view) =~ "Target:required"
      refute_received {:read_finished, _}
    end

    test "#{pagination}, silent=#{silent}: an updated row absent from the returned page stays absent",
         %{
           conn: conn,
           album: album
         } do
      view = mount_collection(conn, @pagination)
      # Move Target to the first page before the read, while its old row is visible.
      album
      |> Ash.Changeset.for_update(:remaster, %{})
      |> Ash.Changeset.force_change_attribute(:title, "Aardvark")
      |> Ash.update!()

      read = pause_reads(view, @silent)

      Cinder.TestLive.Fixture.run(view, fn socket ->
        Cinder.update_item(socket, "albums", album.id, &%{&1 | title: "Local replacement"})
      end)

      assert render(view) =~ "Local replacement:"
      send(read, :deliver)
      html = render_async(view)
      refute html =~ "Local replacement:"
      refute html =~ "Aardvark:"
      assert html =~ "Retained:required"
    end

    test "#{pagination}, silent=#{silent}: removal supersedes the older page", %{
      conn: conn,
      album: album
    } do
      view = mount_collection(conn, @pagination)
      old_read = pause_reads(view, @silent)
      Ash.destroy!(album)
      Cinder.TestLive.Fixture.run(view, &Cinder.remove_item(&1, "albums", album.id))
      refute render(view) =~ "Target:"

      send(old_read, :deliver)
      html = render_async(view)
      refute html =~ "Target:"
      assert html =~ "Retained:required"
      refute_received {:read_finished, _}
    end

    test "#{pagination}, silent=#{silent}: a read without a concurrent change runs once", %{
      conn: conn,
      album: album
    } do
      view = mount_collection(conn, @pagination)
      album |> Ash.Changeset.for_update(:remaster, %{}) |> Ash.update!()
      read = pause_reads(view, @silent)
      assert render(view) =~ "Target:required"
      send(read, :deliver)
      assert render_async(view) =~ "Target:started"
      refute_received {:read_finished, _}
    end
  end
end
