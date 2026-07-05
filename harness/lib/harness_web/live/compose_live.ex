defmodule HarnessWeb.ComposeLive do
  @moduledoc """
  Issue Composer: type a rough idea, let the harness explore the target repo
  and produce a spec-quality draft, then approve (files via GitHub) or discard.
  Human approval gate — nothing reaches GitHub automatically.
  """

  use HarnessWeb, :live_view

  alias Harness.Compose
  alias Harness.Compose.ExploreWorker
  alias Harness.{Policy, Runs}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Compose.subscribe()

    policy = Policy.get()

    {:ok,
     socket
     |> assign(:page_title, "Compose")
     |> assign(:drafts, Compose.list_drafts())
     |> assign(:draft, nil)
     |> assign(:policy, policy)
     |> assign(:repos, policy.github.repos)
     |> assign(:exploring, false)
     |> assign(:run_error, nil)
     |> assign(:form, to_form(%{"prompt" => "", "repo" => ""}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply,
         socket
         |> assign(:draft, nil)
         |> assign(:exploring, false)
         |> assign(:run_error, nil)}

      id ->
        draft = Compose.get_draft!(String.to_integer(id)) |> load_run()

        socket =
          if connected?(socket) && !!draft.run_id && exploring?(draft) do
            Runs.subscribe(draft.run_id)
            assign(socket, :exploring, true)
          else
            assign(socket, :exploring, false)
          end

        run_error =
          if draft.run && draft.run.status in ~w(failed killed) && is_nil(draft.body) do
            draft.run.error || "Explore run failed."
          end

        {:noreply,
         socket
         |> assign(:draft, draft)
         |> assign(:run_error, run_error)
         |> assign(:edit_title, draft.title)
         |> assign(:edit_body, draft.body)}
    end
  end

  @impl true
  def handle_event("submit", %{"prompt" => prompt, "repo" => repo}, socket) do
    prompt = String.trim(prompt)
    repo = String.trim(repo)

    cond do
      prompt == "" ->
        {:noreply, put_flash(socket, :error, "Describe your idea first.")}

      repo == "" or not Enum.any?(socket.assigns.repos, &(&1.name == repo)) ->
        {:noreply, put_flash(socket, :error, "Select a policy repo.")}

      true ->
        draft = Compose.create_draft!(%{prompt: prompt, repo: repo})

        ExploreWorker.new(%{draft_id: draft.id})
        |> Oban.insert!()

        {:noreply,
         socket
         |> assign(:form, to_form(%{"prompt" => "", "repo" => ""}))
         |> push_patch(to: ~p"/compose/#{draft.id}")}
    end
  end

  def handle_event("approve", %{"title" => title, "body" => body}, socket) do
    draft = socket.assigns.draft
    updated = Compose.update_draft!(draft, %{title: String.trim(title), body: String.trim(body)})

    case Compose.approve_draft!(updated) do
      {:ok, approved} ->
        {:noreply,
         socket
         |> assign(:draft, approved)
         |> assign(:drafts, Compose.list_drafts())
         |> put_flash(:info, "Issue filed on #{approved.repo}.")}

      {:error, :forbidden_check_pat_scope} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your PAT needs Issues: Write permission — regenerate at github.com/settings/tokens."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "GitHub error: #{inspect(reason)}")}
    end
  end

  def handle_event("discard", _params, socket) do
    Compose.discard_draft!(socket.assigns.draft)

    {:noreply,
     socket
     |> assign(:drafts, Compose.list_drafts())
     |> push_patch(to: ~p"/compose")}
  end

  @impl true
  def handle_info({:draft_created, _draft}, socket) do
    {:noreply, assign(socket, :drafts, Compose.list_drafts())}
  end

  def handle_info({:draft_updated, draft}, socket) do
    socket =
      if socket.assigns[:draft] && socket.assigns.draft.id == draft.id do
        draft = load_run(draft)

        run_error =
          if draft.run && draft.run.status in ~w(failed killed) && is_nil(draft.body) do
            draft.run.error || "Explore run failed."
          end

        socket
        |> assign(:draft, draft)
        |> assign(:run_error, run_error)
        |> assign(:edit_title, draft.title)
        |> assign(:edit_body, draft.body)
        |> assign(:exploring, false)
      else
        socket
      end

    {:noreply, assign(socket, :drafts, Compose.list_drafts())}
  end

  def handle_info({:run_updated, run}, socket) do
    if run.status in ~w(succeeded failed killed) do
      {:noreply, assign(socket, :exploring, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- helpers ----------------------------------------------------------------

  defp load_run(%{run_id: nil} = draft), do: Map.put(draft, :run, nil)

  defp load_run(draft) do
    run =
      try do
        Harness.Repo.get(Harness.Runs.Run, draft.run_id)
      rescue
        _ -> nil
      end

    Map.put(draft, :run, run)
  end

  defp exploring?(draft) do
    draft.run && draft.run.status in ~w(queued running)
  end

  defp open_questions(%{open_questions: nil}), do: []

  defp open_questions(%{open_questions: json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path="/compose"
      mode={@mode}
      usage_mode={@usage_mode}
      usage_health={@usage_health}
    >
      <div class="grid lg:grid-cols-3 gap-6">
        <aside class="space-y-4">
          <form phx-submit="submit" class="space-y-2">
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim">
              New draft
            </h2>
            <textarea
              name="prompt"
              rows="5"
              placeholder="Rough idea — what problem needs solving?"
              class="w-full bg-surface border border-surface-2 rounded-sm px-2 py-1.5 font-body text-sm text-ink focus:outline-2 focus:outline-accent"
            >{@form[:prompt].value}</textarea>
            <select
              name="repo"
              class="w-full bg-bg border border-surface-2 rounded-sm px-2 py-1.5 font-mono text-[11px] text-ink focus:outline-2 focus:outline-accent"
            >
              <option value="">— target repo —</option>
              <option :for={r <- @repos} value={r.name}>{r.name}</option>
            </select>
            <div class="flex justify-end">
              <button class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-accent text-bg rounded-sm">
                Explore
              </button>
            </div>
          </form>

          <div>
            <h2 class="font-display uppercase tracking-[0.14em] text-[11px] text-ink-dim mb-2">
              Drafts
            </h2>
            <p :if={@drafts == []} class="font-body text-sm text-ink-dim">
              No drafts yet.
            </p>
            <.link
              :for={d <- @drafts}
              patch={~p"/compose/#{d.id}"}
              class={[
                "block rounded-sm border px-3 py-2 mb-1.5",
                @draft && @draft.id == d.id && "border-accent bg-surface",
                !(@draft && @draft.id == d.id) && "border-surface-2 hover:bg-surface"
              ]}
            >
              <div class="flex items-center gap-2">
                <span class="font-mono text-[10px] text-ink-dim tabular-nums">#{d.id}</span>
                <span class={draft_status_class(d.status)}>{d.status}</span>
                <span :if={d.repo} class="font-mono text-[9px] text-ink-dim/60 ml-auto truncate max-w-[8rem]">
                  {d.repo}
                </span>
              </div>
              <p class="font-body text-[12px] text-ink mt-1 line-clamp-2">{d.prompt}</p>
            </.link>
          </div>
        </aside>

        <section class="lg:col-span-2">
          <div :if={!@draft} class="py-8 text-center">
            <p class="font-body text-ink-dim">
              Type a rough idea and pick a repo — the harness will explore and draft a spec-quality issue for your review.
            </p>
          </div>

          <div :if={@draft} class="space-y-4">
            <div class="flex items-center gap-3">
              <h1 class="font-display uppercase tracking-[0.16em] text-sm text-ink-dim">
                Draft #{@draft.id}
              </h1>
              <span class={draft_status_class(@draft.status)}>{@draft.status}</span>
              <span :if={@draft.scope_hint} class="font-mono text-[10px] border border-surface-2 rounded px-1.5 py-0.5 text-ink-dim">
                scope: {@draft.scope_hint}
              </span>
            </div>

            <div :if={@exploring} class="rounded-sm border border-surface-2 bg-surface px-4 py-3 flex items-center gap-3">
              <span class="font-mono text-[10px] text-accent animate-pulse">exploring…</span>
              <span class="font-body text-sm text-ink-dim">Investigating {@draft.repo} — this takes a few minutes.</span>
            </div>

            <div :if={@run_error} class="rounded-sm border border-alert bg-alert/10 px-4 py-3">
              <span class="font-mono text-[10px] text-alert uppercase">explore failed</span>
              <p class="font-body text-sm text-ink mt-1">{@run_error}</p>
            </div>

            <div :if={!@exploring && !@run_error && @draft.body} class="space-y-4">
              <div class="rounded-sm border border-surface-2 bg-surface p-4 space-y-3">
                <div>
                  <label class="font-mono text-[10px] text-ink-dim block mb-1">Title</label>
                  <input
                    id="draft-title"
                    type="text"
                    value={@edit_title}
                    name="title"
                    class="w-full bg-bg border border-surface-2 rounded-sm px-2 py-1.5 font-body text-sm text-ink focus:outline-2 focus:outline-accent"
                  />
                </div>
                <div>
                  <label class="font-mono text-[10px] text-ink-dim block mb-1">Body</label>
                  <textarea
                    id="draft-body"
                    name="body"
                    rows="16"
                    class="w-full bg-bg border border-surface-2 rounded-sm px-2 py-1.5 font-mono text-[11px] text-ink focus:outline-2 focus:outline-accent"
                  >{@edit_body}</textarea>
                </div>

                <div
                  :if={open_questions(@draft) != []}
                  class="border-t border-surface-2 pt-3"
                >
                  <h3 class="font-mono text-[10px] text-ink-dim uppercase tracking-wider mb-2">
                    Open questions
                  </h3>
                  <ul class="space-y-1">
                    <li
                      :for={q <- open_questions(@draft)}
                      class="font-body text-sm text-ink-dim"
                    >
                      · {q}
                    </li>
                  </ul>
                </div>
              </div>

              <div :if={@draft.status == "draft"} class="flex gap-3 justify-end">
                <button
                  phx-click="discard"
                  data-confirm="Discard this draft? It will not reach GitHub."
                  class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 border border-alert text-alert rounded-sm hover:bg-alert/10"
                >
                  Discard
                </button>
                <button
                  phx-click="approve"
                  phx-value-title={@edit_title}
                  phx-value-body={@edit_body}
                  data-confirm={"File this issue on #{@draft.repo}?"}
                  class="font-display uppercase text-[10px] tracking-widest px-3 py-1.5 bg-ok text-bg rounded-sm hover:opacity-90"
                >
                  Approve &amp; File
                </button>
              </div>

              <div :if={@draft.status == "approved"} class="rounded-sm border border-ok/30 bg-ok/10 px-4 py-3">
                <span class="font-mono text-[10px] text-ok uppercase">filed</span>
                <p class="font-body text-sm text-ink-dim mt-1">
                  This issue has been filed on GitHub and entered the pipeline.
                </p>
              </div>
            </div>

            <div :if={!@exploring && !@run_error && !@draft.body && @draft.status == "draft"} class="rounded-sm border border-surface-2 bg-surface px-4 py-8 text-center">
              <p class="font-body text-sm text-ink-dim">Waiting for explore run to start…</p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp draft_status_class("approved"), do: "font-mono text-[10px] uppercase text-ok"
  defp draft_status_class("discarded"), do: "font-mono text-[10px] uppercase text-alert/60"
  defp draft_status_class(_), do: "font-mono text-[10px] uppercase text-ink-dim"
end
