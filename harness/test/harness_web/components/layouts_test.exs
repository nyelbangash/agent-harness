defmodule HarnessWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias HarnessWeb.Layouts

  defp wrapper(assigns) do
    ~H"""
    <Layouts.app flash={%{}}>
      content
    </Layouts.app>
    """
  end

  test "renders a theme toggle with its colocated hook" do
    html = render_component(&wrapper/1, %{})

    assert html =~ ~s|id="theme-toggle"|
    assert html =~ ~s|phx-hook="HarnessWeb.Layouts.ThemeToggle"|
    assert html =~ ~s|data-storage-key="harness:theme"|
  end
end
