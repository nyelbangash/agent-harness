defmodule HarnessWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HarnessWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_path, :string, default: "/"
  attr :mode, :atom, default: :plan_only
  attr :usage_mode, :atom, default: :plan_only
  attr :usage_health, :atom, default: :ok

  slot :inner_block, required: true

  @nav [
    {"Overview", "/"},
    {"Issues", "/issues"},
    {"Runs", "/runs"}
  ]
  @nav_later ~w(Ideation Budget Policy)

  def app(assigns) do
    assigns = assign(assigns, nav: @nav, nav_later: @nav_later)

    ~H"""
    <div class="min-h-screen md:flex">
      <aside class="md:w-44 md:min-h-screen shrink-0 border-b md:border-b-0 md:border-r border-surface-2 bg-bg px-4 py-4 md:py-6 flex md:flex-col items-center md:items-stretch gap-4 md:gap-6">
        <a href="/" class="font-display font-bold tracking-[0.2em] text-ink text-sm uppercase">
          Harness
        </a>

        <nav class="flex md:flex-col gap-1 flex-1">
          <.link
            :for={{label, path} <- @nav}
            navigate={path}
            class={[
              "font-display uppercase tracking-[0.14em] text-[12px] px-2 py-1.5 rounded-sm",
              "focus-visible:outline-2 focus-visible:outline-accent",
              if(@current_path == path,
                do: "text-bg bg-accent",
                else: "text-ink-dim hover:text-ink"
              )
            ]}
          >
            {label}
          </.link>
          <span
            :for={label <- @nav_later}
            class="hidden md:block font-display uppercase tracking-[0.14em] text-[12px] px-2 py-1.5 text-ink-dim/40 cursor-default"
            title="Later phase"
          >
            {label}
          </span>
        </nav>

        <div class="flex md:flex-col items-center md:items-stretch gap-3">
          <.mode_indicator mode={@mode} usage_mode={@usage_mode} usage_health={@usage_health} />

          <button
            phx-click="master_kill"
            data-confirm="Kill every running agent session?"
            class="font-display uppercase tracking-[0.14em] text-[11px] px-3 py-2 rounded-sm border border-alert text-alert hover:bg-alert hover:text-ink focus-visible:outline-2 focus-visible:outline-alert"
          >
            Kill all
          </button>
        </div>
      </aside>

      <main class="flex-1 px-4 sm:px-6 lg:px-8 py-6 max-w-[1400px]">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :mode, :atom, required: true
  attr :usage_mode, :atom, required: true
  attr :usage_health, :atom, required: true

  defp mode_indicator(assigns) do
    ~H"""
    <div class="flex flex-col items-center md:items-stretch gap-1" data-testid="mode-indicator">
      <span class={[
        "font-display uppercase tracking-[0.14em] text-[11px] px-3 py-1.5 rounded-sm border text-center",
        mode_classes(@mode)
      ]}>
        {mode_label(@mode)}
      </span>
      <span
        :if={@usage_health == :stale}
        class="font-mono text-[10px] text-alert text-center"
        title="usage telemetry stale — failing closed"
      >
        USAGE STALE
      </span>
      <span
        :if={@usage_health == :ok and @mode != :paused}
        class="font-mono text-[10px] text-ink-dim text-center tabular-nums"
      >
        usage: {@usage_mode |> to_string() |> String.replace("_", " ")}
      </span>
    </div>
    """
  end

  defp mode_label(:plan_only), do: "Plan-Only"
  defp mode_label(:full_auto), do: "Full Auto"
  defp mode_label(:paused), do: "Paused"

  defp mode_classes(:paused), do: "border-alert text-alert"
  defp mode_classes(_), do: "border-accent text-accent"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
