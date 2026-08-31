defmodule Cinder.PackageTest do
  use ExUnit.Case, async: true

  test "ships JavaScript hooks with the package priv directory" do
    package_files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    assert "priv" in package_files
    assert File.regular?("priv/static/cinder_hooks.js")
  end

  test "infinite stream hook mirrors the root selection lock into retained checkboxes" do
    hooks = File.read!("priv/static/cinder_hooks.js")

    assert hooks =~ ~s|hasAttribute("data-selection-locked")|
    assert hooks =~ "checkbox.disabled"
    assert hooks =~ ~s|hasAttribute("data-cinder-selection-disabled")|
  end
end
